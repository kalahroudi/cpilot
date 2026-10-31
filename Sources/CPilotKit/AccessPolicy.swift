// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-project rules that sit under the session's access level.
public struct AccessRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    /// Folder the rule covers (prefix match).
    public var path: String
    /// Overrides the default level for sessions in this folder.
    public var level: AccessLevel?
    /// Command prefixes that never ask, for example `npm test` or `git status`.
    public var allowCommands: [String] = []
    public init(path: String, level: AccessLevel? = nil, allowCommands: [String] = []) {
        self.path = path; self.level = level; self.allowCommands = allowCommands
    }
}

public enum AccessDecision: Equatable, Sendable {
    case allow(reason: String)
    case deny(reason: String)
    case ask
}

public struct AccessPolicy: Codable, Equatable, Sendable {
    public var defaultLevel: AccessLevel = .askFirst
    public var rules: [AccessRule] = []
    /// Anything outside the project folder asks, whatever the level (except Full access).
    public var askOutsideProject = true
    public var requireTouchIDForFullAccess = true
    /// Repositories where the user turned off Full access for the sessions their specs start (it is on everywhere else). Optional so older policy files still load.
    public var specAskRepos: [String]?
    public init() {}

    public func specSessionsHaveFullAccess(_ repo: String) -> Bool { !(specAskRepos?.contains(repo) ?? false) }

    public mutating func setSpecFullAccess(_ on: Bool, repo: String) {
        var l = specAskRepos ?? []
        l.removeAll { $0 == repo }
        if !on { l.append(repo) }
        specAskRepos = l.isEmpty ? nil : l
    }

    static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "ToolSearch"]
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public func rule(for cwd: String) -> AccessRule? {
        rules.filter { cwd == $0.path || cwd.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    public func level(for session: SessionMeta) -> AccessLevel { rule(for: session.cwd)?.level ?? session.access }

    public static func isInside(_ path: String, folder: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardized.path, f = URL(fileURLWithPath: folder).standardized.path
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// Decide one tool request without bothering the user when the rules already answer it.
    public func decide(_ req: PermissionRequest, session: SessionMeta, sessionGrants: Set<String> = []) -> AccessDecision {
        let level = level(for: session)
        if level == .fullAccess { return .allow(reason: "Full access") }
        if level == .readOnly, !Self.readTools.contains(req.tool) { return .deny(reason: "This session is read only.") }

        let root = session.workingDirectory
        let inside = req.path.map { Self.isInside($0, folder: root) } ?? true
        if !inside, askOutsideProject { return .ask }

        if Self.readTools.contains(req.tool) { return .allow(reason: "Reading is free") }
        if level == .editFiles, Self.editTools.contains(req.tool) { return .allow(reason: "Edit files") }
        if sessionGrants.contains(Self.grantKey(req)) { return .allow(reason: "Allowed for this session") }
        if req.tool == "Bash", let rule = rule(for: session.cwd),
           rule.allowCommands.contains(where: { Self.commandMatches(req.summary, prefix: $0) }) { return .allow(reason: "Project rule") }
        return .ask
    }

    /// `git status` matches the prefix `git status`; `git statusx` and `git status; rm x` do not.
    public static func commandMatches(_ command: String, prefix: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespaces), p = prefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, c.hasPrefix(p) else { return false }
        let rest = c.dropFirst(p.count)
        if let f = rest.first, !f.isWhitespace { return false }
        return !rest.contains { ";&|`$<>\n".contains($0) }
    }

    /// What "allow for this session" remembers.
    public static func grantKey(_ req: PermissionRequest) -> String {
        if req.tool == "Bash" { return "Bash:" + req.summary.split(separator: " ").prefix(2).joined(separator: " ") }
        return req.tool
    }

    // MARK: Storage

    public static func load(from url: URL = AppPaths().policyFile) -> AccessPolicy {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AccessPolicy.self, from: $0) } ?? AccessPolicy()
    }

    public func save(to url: URL = AppPaths().policyFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: url, options: .atomic) }
    }
}

public struct AuditEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var ts = Date()
    public var session: String
    public var tool: String
    public var summary: String
    /// allowed once, allowed for session, allowed by rule, denied, denied by rule
    public var outcome: String
    public init(session: String, tool: String, summary: String, outcome: String) {
        self.session = session; self.tool = tool; self.summary = summary; self.outcome = outcome
    }

    /// A short, readable name for what was approved: "Ran git status", "Edited Package.swift". The full text stays in `summary`.
    public var headline: String {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        func file() -> String { (s as NSString).lastPathComponent.isEmpty ? s : (s as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            var words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            // Skip a leading `cd dir &&` and VAR=value prefixes to find the command itself.
            while let f = words.first {
                if f == "cd", words.count > 2, words[2] == "&&" { words.removeFirst(3) }
                else if f.contains("="), !f.hasPrefix("-"), !f.hasPrefix("/"), !f.hasPrefix("\"") { words.removeFirst() }
                else { break }
            }
            let name = words.first.map { ($0 as NSString).lastPathComponent } ?? "a command"
            let sub = words.dropFirst().first.flatMap { w -> String? in w.hasPrefix("-") || w.count > 20 || w.contains("/") || w.contains("\"") ? nil : w }
            return "Ran " + [name, sub].compactMap { $0 }.joined(separator: " ")
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited " + file()
        case "Write": return "Wrote " + file()
        case "Read": return "Read " + file()
        default: return tool + (s.isEmpty || s.count > 40 ? "" : ": " + s)
        }
    }
}

/// Every approval, kept as one line of JSON so it is easy to read, grep and revoke.
public final class AuditLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    public init(url: URL = AppPaths().auditFile) { self.url = url }

    public func record(_ e: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard var d = try? enc.encode(e) else { return }
        d.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: d) }
        else { try? d.write(to: url) }
    }

    public func recent(_ n: Int = 50) -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return s.split(separator: "\n").suffix(n).compactMap { $0.data(using: .utf8).flatMap { try? dec.decode(AuditEntry.self, from: $0) } }.reversed()
    }

    public func clear() { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: url) }
}

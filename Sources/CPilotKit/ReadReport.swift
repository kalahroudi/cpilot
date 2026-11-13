// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which file a tool call read, found from the call's own arguments. Only what is plainly a read is recognized; anything else is not guessed at.
public enum ReadTarget {
    public static func extract(tool: String, input: [String: Any]) -> (path: String, range: String?)? {
        if tool == "Read", let p = input["file_path"] as? String, !p.isEmpty {
            let off = input["offset"] as? Int, lim = input["limit"] as? Int
            return (p, off == nil && lim == nil ? nil : "\(off ?? 1)+\(lim ?? 0)")
        }
        guard tool == "Bash", var cmd = input["command"] as? String else { return nil }
        // The whole output of the command is what was sent, so it only counts as a read of that file when the read is all the command does: nothing chained
        // with &&, ;, || or a newline after an optional `cd dir &&`, and nothing but a filter (head, tail, wc, grep) piped on.
        if let re = try? NSRegularExpression(pattern: #"^\s*cd\s+("[^"]+"|'[^']+'|[^\s;&|]+)\s*&&\s*"#), let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)), let r = Range(m.range, in: cmd) { cmd = String(cmd[r.upperBound...]) }
        let stages = cmd.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cmd.contains("&&"), !cmd.contains(";"), !cmd.contains("\n"), !cmd.contains("||"), !cmd.contains(">"), !cmd.contains("<"),
              stages.dropFirst().allSatisfy({ ["head", "tail", "wc", "grep", "nl", "cut", "sort", "uniq"].contains($0.split(separator: " ").first.map(String.init) ?? "") }) else { return nil }
        cmd = stages[0]
        // The first plain read of a file: sed -n 'A,Bp' f, cat f, head/tail -n N f, nl f (after any leading `cd dir &&`).
        let patterns: [(String, Bool)] = [(#"^sed\s+-n\s+'?(\d+),(\d+)p'?\s+("[^"]+"|'[^']+'|[^\s;&|<>]+)"#, true),
                                          (#"^(?:cat|nl)\s+(?:-[a-zA-Z]+\s+)*("[^"]+"|'[^']+'|[^\s;&|<>-][^\s;&|<>]*)"#, false),
                                          (#"^(?:head|tail)\s+(?:-n\s*)?-?(\d+)\s+("[^"]+"|'[^']+'|[^\s;&|<>]+)"#, false)]
        for (i, (pattern, ranged)) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) else { continue }
            func g(_ n: Int) -> String? { Range(m.range(at: n), in: cmd).map { String(cmd[$0]) } }
            let raw = ranged ? g(3) : (i == 1 ? g(1) : g(2))
            guard var path = raw else { continue }
            if (path.hasPrefix("\"") && path.hasSuffix("\"")) || (path.hasPrefix("'") && path.hasSuffix("'")), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            guard !path.isEmpty, !path.hasPrefix("-"), !path.hasPrefix("$") else { continue }
            return (path, ranged ? "\(g(1) ?? "")-\(g(2) ?? "")" : nil)
        }
        return nil
    }
}

/// Files whose contents should not go to a model provider by accident: keys, tokens, environment files. Examples, public keys and ordinary source files are not.
public enum SensitivePaths {
    public static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let lower = path.lowercased()
        if name == ".env" || (name.hasPrefix(".env.") && !["example", "sample", "template", "dist", "defaults"].contains(where: { name.hasSuffix("." + $0) })) { return true }
        if ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".npmrc", ".netrc", ".pgpass", ".git-credentials", "credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml", "service-account.json"].contains(name) { return true }
        if [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks"].contains(where: { name.hasSuffix($0) }) { return true }
        if lower.contains("/.aws/") && name != "config" { return true }
        if lower.contains("/.ssh/") && !name.hasSuffix(".pub") && !["config", "known_hosts", "authorized_keys"].contains(name) { return true }
        return false
    }
}

/// What one session pulled into the conversation as file content, which then travels with every later call.
public struct ReadReport: Equatable, Sendable {
    public struct File: Equatable, Sendable { public var path: String; public var reads: Int; public var chars: Int; public var repeatedChars: Int }
    public var files: [File]
    public var totalReads: Int
    public var totalChars: Int
    /// Reads of a file and range already read in the same session, and their size.
    public var repeatReads: Int
    public var repeatChars: Int
    public var sensitive: [String]

    public init(_ tools: [ToolEvent]) {
        var by: [String: File] = [:], seen: Set<String> = []
        var reads = 0, chars = 0, repeats = 0, repeatSize = 0
        for t in tools {
            guard let path = t.target, let c = t.resultChars else { continue }
            reads += 1; chars += c
            var f = by[path] ?? File(path: path, reads: 0, chars: 0, repeatedChars: 0)
            f.reads += 1; f.chars += c
            if !seen.insert(path + "\u{0}" + (t.range ?? "")).inserted { repeats += 1; repeatSize += c; f.repeatedChars += c }
            by[path] = f
        }
        files = by.values.sorted { $0.chars > $1.chars }
        totalReads = reads; totalChars = chars; repeatReads = repeats; repeatChars = repeatSize
        sensitive = by.keys.filter(SensitivePaths.isSensitive).sorted()
    }
}

/// Refuses a read of a file that holds secrets, before its content is sent to a model provider.
public enum SensitiveGuard {
    public static func decide(tool: String, input: [String: Any]) -> String? {
        guard let t = ReadTarget.extract(tool: tool, input: input), SensitivePaths.isSensitive(t.path) else { return nil }
        let name = (t.path as NSString).lastPathComponent
        return "CPilot did not read \(name): files like it hold keys or secrets, and what is read is sent to the model provider and kept in the conversation. Work without its contents (ask the user for the specific non-secret value you need, or use the `.example` file for the variable names). The user can allow this in CPilot Settings, Saving usage."
    }
}

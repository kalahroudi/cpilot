// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A command in an assistant message the user could run to try the work: "run `.build/debug/Moose --demo` and click the top row".
public struct RunnableCommand: Identifiable, Equatable, Sendable {
    public var command: String
    /// The folder to run it in, when the message named one (`cd <worktree> && <command>`). Nil means the session's own folder.
    public var directory: String?
    public var id: String { (directory ?? "") + "|" + command }
    public init(command: String, directory: String? = nil) { self.command = command; self.directory = directory }
}

public enum RunnableCommands {
    /// Programs that, as the first word of a code span, make it a command rather than a name or a value.
    static let tools: Set<String> = [
        "swift", "xcodebuild", "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "cargo", "go", "make", "just",
        "python", "python3", "pytest", "pip", "uv", "ruby", "bundle", "rake", "gradle", "mvn", "dotnet", "open", "docker", "cpilot",
    ]
    /// Words after which a code span is something to run, so `git status` in "check `git status`" is not offered but "run `git status`" is.
    static let verbs = ["run", "launch", "start", "try", "open", "execute", "build and run"]

    /// The most commands read from one fenced block that names a folder.
    static let maxScopedLines = 8

    /// `cd <folder> && <command>` (or `;`): the folder (absolute, `~/` expanded, quotes removed) and what to run there. Nil for anything else.
    public static func scoped(_ s: String) -> (directory: String, command: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("cd "), let (dir, rest) = takeFolder(String(t.dropFirst(3))) else { return nil }
        let r = rest.trimmingCharacters(in: .whitespaces)
        let command: String
        if r.hasPrefix("&&") { command = String(r.dropFirst(2)) } else if r.hasPrefix(";") { command = String(r.dropFirst(1)) } else { return nil }
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, c.count <= 300, !c.contains("\n") else { return nil }
        return (dir, shellLine(c))
    }

    /// A line that is only `cd <folder>`: later lines of the block run there.
    static func folderOnly(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("cd "), let (dir, rest) = takeFolder(String(t.dropFirst(3))), rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return dir
    }

    /// The folder at the start of `text` and what follows it. Only an absolute path or one under `~/` counts.
    private static func takeFolder(_ text: String) -> (String, String)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        var dir: String, rest: Substring
        if let q = s.first, q == "'" || q == "\"" {
            let body = s.dropFirst()
            guard let end = body.firstIndex(of: q) else { return nil }
            dir = String(body[..<end]); rest = body[body.index(after: end)...]
        } else {
            let end = s.firstIndex(where: { $0 == " " || $0 == ";" }) ?? s.endIndex
            dir = String(s[..<end]); rest = s[end...]
        }
        if dir.hasPrefix("~/") { dir = NSHomeDirectory() + String(dir.dropFirst(1)) }
        guard dir.hasPrefix("/"), !dir.contains("\n"), dir.count < 500 else { return nil }
        return (dir, String(rest))
    }

    /// Whether `dir` is one of the allowed folders or inside one.
    static func isAllowed(_ dir: String, _ allowed: Set<String>) -> Bool {
        let d = (dir as NSString).standardizingPath
        return allowed.contains { a in let b = (a as NSString).standardizingPath; return d == b || d.hasPrefix(b + "/") }
    }

    /// Commands the message tells the user to run, in order, without repeats. A command that names a folder (`cd <worktree> && …`, or a fenced block that starts with `cd <worktree>`)
    /// runs there; it is offered only when that folder is in `allowedDirectories` (never when none are given), so a message cannot aim a button at any folder it likes. Without a folder, fenced blocks are only considered when they are one line.
    public static func find(in markdown: String, allowedDirectories: Set<String>? = nil) -> [RunnableCommand] {
        var out: [RunnableCommand] = []
        func add(_ s: String, in dir: String? = nil) {
            let c = s.trimmingCharacters(in: .whitespaces)
            // A command that names a folder is offered only when the caller said which folders are fine.
            if let dir { guard let allowed = allowedDirectories, isAllowed(dir, allowed) else { return } }
            if !c.isEmpty, !out.contains(where: { $0.command == c && $0.directory == dir }) { out.append(RunnableCommand(command: c, directory: dir)) }
        }
        var inFence = false
        var fence: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { fenceCommands(fence, add: add) }
                inFence.toggle(); fence = []; continue
            }
            if inFence { if !line.trimmingCharacters(in: .whitespaces).isEmpty { fence.append(line) }; continue }
            for (span, before) in codeSpans(in: line) {
                if let s = scoped(span) { add(s.command, in: s.directory) }
                else if looksLikeCommand(span, afterVerb: endsWithVerb(before)) { add(span) }
            }
        }
        return out
    }

    /// A fenced block: a single command as before, or lines that run in a folder (`cd <folder>` once, or `cd <folder> && …` on each line).
    private static func fenceCommands(_ lines: [String], add: (String, String?) -> Void) {
        var current: String?, found = 0
        var any = false
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let s = scoped(t) { current = s.directory; add(s.command, s.directory); any = true; found += 1 }
            else if let d = folderOnly(t) { current = d; any = true }
            else if let dir = current, !t.hasPrefix("#"), found < maxScopedLines { add(shellLine(t), dir); found += 1 }
        }
        if !any, lines.count == 1, looksLikeCommand(lines[0], afterVerb: true) { add(lines[0], nil) }
    }

    /// Whether a code span reads as something to type in a shell. A path to a program counts; a bare file name or a flag does not.
    static func looksLikeCommand(_ s: String, afterVerb: Bool) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 300, !t.contains("\n"), !t.hasPrefix("-"), !t.hasPrefix("$ ") || t.count > 2 else { return false }
        let words = t.split(separator: " ").map(String.init)
        guard let first = words.first.map({ $0.hasPrefix("$") && words.count > 1 ? words[1] : $0 }) else { return false }
        if first.hasPrefix("./") || first.hasPrefix(".build/") || first.hasPrefix("/") || first.hasPrefix("~/") {
            // A path to a program, not a file the message merely names.
            let ext = URL(fileURLWithPath: first).pathExtension.lowercased()
            return ext.isEmpty || ["sh", "py", "rb", "js", "app"].contains(ext) || afterVerb && words.count > 1
        }
        if tools.contains(first) { return words.count > 1 || first == "make" }
        return afterVerb && first.contains("/") && !first.contains("://") && words.count > 1
    }

    private static func endsWithVerb(_ before: String) -> Bool {
        let b = before.lowercased().trimmingCharacters(in: .whitespaces)
        return verbs.contains { b.hasSuffix($0) }
    }

    /// The inline code spans of a line, each with the text before it.
    static func codeSpans(in line: String) -> [(String, String)] {
        var spans: [(String, String)] = []
        var i = line.startIndex
        while let open = line[i...].firstIndex(of: "`") {
            let after = line.index(after: open)
            guard let close = line[after...].firstIndex(of: "`") else { break }
            spans.append((String(line[after..<close]), String(line[..<open])))
            i = line.index(after: close)
        }
        return spans
    }

    /// What to type so the command runs in the session's folder.
    public static func shellLine(_ command: String) -> String {
        command.hasPrefix("$ ") ? String(command.dropFirst(2)) : command
    }
}

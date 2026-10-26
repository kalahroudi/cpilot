// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A command in an assistant message the user could run to try the work: "run `.build/debug/Moose --demo` and click the top row".
public struct RunnableCommand: Identifiable, Equatable, Sendable {
    public var command: String
    public var id: String { command }
}

public enum RunnableCommands {
    /// Programs that, as the first word of a code span, make it a command rather than a name or a value.
    static let tools: Set<String> = [
        "swift", "xcodebuild", "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "cargo", "go", "make", "just",
        "python", "python3", "pytest", "pip", "uv", "ruby", "bundle", "rake", "gradle", "mvn", "dotnet", "open", "docker", "cpilot",
    ]
    /// Words after which a code span is something to run, so `git status` in "check `git status`" is not offered but "run `git status`" is.
    static let verbs = ["run", "launch", "start", "try", "open", "execute", "build and run"]

    /// Commands the message tells the user to run, in order, without repeats. Fenced blocks are only considered when they are one line.
    public static func find(in markdown: String) -> [RunnableCommand] {
        var out: [RunnableCommand] = []
        func add(_ s: String) {
            let c = s.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, !out.contains(where: { $0.command == c }) { out.append(RunnableCommand(command: c)) }
        }
        var inFence = false
        var fence: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { if fence.count == 1, looksLikeCommand(fence[0], afterVerb: true) { add(fence[0]) }; fence = [] }
                inFence.toggle(); continue
            }
            if inFence { if !line.trimmingCharacters(in: .whitespaces).isEmpty { fence.append(line) }; continue }
            for (span, before) in codeSpans(in: line) where looksLikeCommand(span, afterVerb: endsWithVerb(before)) { add(span) }
        }
        return out
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

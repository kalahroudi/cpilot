// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A short text summary of a conversation, for handing context to a new session: a fork, another agent, or a saved note.
/// It carries what was asked, what was answered, which commands ran and which files changed. It is a summary,
/// not the agent's own state, so it never claims the new session remembers everything.
public enum ContextDigest {
    /// One line of text: whitespace collapsed, cut to `limit` characters with an ellipsis.
    public static func compact(_ s: String, limit: Int = 240) -> String {
        let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit - 3)) + "..." : one
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// The most recent rows that fit in `budget` characters, oldest first.
    public static func build(items: [ChatItem], budget: Int = 6000) -> String {
        var lines: [String] = []
        for item in items {
            switch item.kind {
            case .user: if !item.text.isEmpty { lines.append("User: " + compact(item.text)) }
            case .assistant: if !item.text.isEmpty { lines.append("Assistant: " + compact(item.text)) }
            case .tool:
                guard let name = item.title else { continue }
                if name == "Bash" || name == "Execute" { lines.append("Ran: " + compact(item.detail ?? "", limit: 160)) }
                else if editTools.contains(name) || name == "Edit" { lines.append("Changed: " + compact(item.detail ?? "", limit: 160)) }
            default: continue
            }
        }
        var used = 0, kept: [String] = []
        for l in lines.reversed() {
            if used + l.count + 1 > budget { break }
            kept.append(l); used += l.count + 1
        }
        let omitted = lines.count - kept.count
        return ((omitted > 0 ? ["(\(omitted) earlier lines omitted)"] : []) + kept.reversed()).joined(separator: "\n")
    }

    /// The text placed before the first message of a session that continues earlier work.
    public static func handoff(_ digest: String, from title: String) -> String {
        "Context from an earlier session (\"\(title)\") in this project. It is a summary, not a full transcript, so check the files before relying on details:\n\n\(digest)"
    }
}

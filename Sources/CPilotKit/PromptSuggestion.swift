// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A guess at what the user will say next, written from the agent's last message so Tab can fill it in.
public enum PromptSuggestion {
    public static func prompt(digest: String) -> String {
        "You write the user's next message in a coding session. Read the end of the conversation below. If the assistant last proposed or recommended something, or asked a question, answer it the way the user most likely would, such as agreeing to the recommended option. Otherwise ask for the obvious next step. One short imperative sentence (under 20 words) in the user's voice, no quotes, no preamble. If no sensible next message exists, reply with exactly NONE.\n\n\(digest)"
    }

    /// The first line of the reply without quotes or labels, or nil when Claude had nothing to suggest.
    public static func clean(_ raw: String) -> String? {
        var s = (raw.split(separator: "\n").first.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for q in ["\"", "'", "`", "“", "”"] { if s.hasPrefix(q) { s.removeFirst() }; if s.hasSuffix(q) { s.removeLast() } }
        if s.lowercased().hasPrefix("user:") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty, s.uppercased() != "NONE", s.count <= 240 else { return nil }
        return s
    }
}

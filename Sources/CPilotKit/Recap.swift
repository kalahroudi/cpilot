// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A short "where things stand" for someone coming back to a session: what was asked, what got done, where it stopped,
/// and whether anything waits on them. The plain version is built from the transcript instantly and for free;
/// Claude can then rewrite it in a few friendlier lines.
public enum Recap {
    public struct Parts: Equatable, Sendable {
        public var firstAsk: String?
        public var latestAsk: String?
        public var commands: [String] = []
        public var files: [String] = []
        public var failures = 0
        public var lastReply: String?
        public var waiting: String?
        public var isEmpty: Bool { latestAsk == nil && lastReply == nil }
    }

    public static func parts(_ items: [ChatItem]) -> Parts {
        var p = Parts()
        let users = items.filter { $0.kind == .user && !$0.text.isEmpty }
        p.firstAsk = users.first.map { ContextDigest.compact($0.text, limit: 160) }
        p.latestAsk = users.last.map { ContextDigest.compact($0.text, limit: 160) }
        for t in items where t.kind == .tool {
            guard let name = t.title else { continue }
            if t.status == .failed { p.failures += 1 }
            if name == "Bash" || name == "Execute" { if let d = t.detail, !d.isEmpty, !p.commands.contains(ContextDigest.compact(d, limit: 80)) { p.commands.append(ContextDigest.compact(d, limit: 80)) } }
            else if ContextDigest.editTools.contains(name) || name == "Edit" {
                let file = URL(fileURLWithPath: t.detail ?? "").lastPathComponent
                if !file.isEmpty, !p.files.contains(file) { p.files.append(file) }
            }
        }
        if let last = items.last(where: { $0.kind == .assistant && !$0.text.isEmpty }) {
            let first = last.text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? last.text
            p.lastReply = ContextDigest.compact(first, limit: 200)
        }
        if let pending = items.last(where: { $0.kind == .permission && $0.status == .pending }) {
            p.waiting = "approval to \(pending.title == "Bash" ? "run" : "use \(pending.title ?? "a tool"):") \(ContextDigest.compact(pending.text, limit: 90))"
        }
        return p
    }

    /// The recap as short Markdown lines.
    public static func text(_ p: Parts) -> String {
        guard !p.isEmpty else { return "Nothing has happened in this session yet." }
        var lines: [String] = []
        if let a = p.latestAsk { lines.append("**Latest ask:** \(a)") }
        if let f = p.firstAsk, f != p.latestAsk { lines.append("**Started with:** \(f)") }
        var did: [String] = []
        if !p.files.isEmpty { did.append("changed \(p.files.count) file\(p.files.count == 1 ? "" : "s") (\(p.files.prefix(4).joined(separator: ", "))\(p.files.count > 4 ? ", …" : ""))") }
        if !p.commands.isEmpty { did.append("ran \(p.commands.count) command\(p.commands.count == 1 ? "" : "s") (\(p.commands.suffix(2).joined(separator: "; ")))") }
        if p.failures > 0 { did.append("\(p.failures) step\(p.failures == 1 ? "" : "s") failed") }
        if !did.isEmpty { lines.append("**So far:** " + did.joined(separator: ", ")) }
        if let r = p.lastReply { lines.append("**Last reply:** \(r)") }
        if let w = p.waiting { lines.append("**Waiting on you:** \(w)") }
        return lines.joined(separator: "\n\n")
    }

    /// One line for lists: what needs you, or the last thing said.
    public static func headline(_ p: Parts) -> String {
        if let w = p.waiting { return "Waiting on \(w)" }
        return p.lastReply ?? p.latestAsk ?? "No messages yet"
    }

    public static func prompt(digest: String) -> String {
        "Write a recap of this coding session for someone returning after a break. 3 to 5 short lines in plain language: what they asked for, what has been done, where it stopped, and the obvious next step. Mention anything waiting on them. Reply with only the recap, no preamble.\n\n\(digest)"
    }

    /// Has the conversation moved on since the recap was written, and has the user been away long enough to want one?
    public static func isDue(lastActivity: Date, now: Date = .now, awayAfter: TimeInterval = 20 * 60) -> Bool {
        now.timeIntervalSince(lastActivity) >= awayAfter
    }
}

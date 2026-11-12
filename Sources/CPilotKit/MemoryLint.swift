// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The rules for what may be written to memory without a person looking at it. Memory is added to every session's instructions, so a note an agent or a finished run wrote is untrusted text
/// that future sessions will read: it must not carry a secret, a command that fetches and runs code, an instruction to the agent, or a way around the checks. One list serves every automated
/// writer, so the lessons pass and the MCP server cannot drift apart. A person writing in the Memory pane is not limited by it.
public enum MemoryLint {
    public enum Strictness: Sendable {
        /// Notes that may hold commands and code: secrets, fetch-and-run, destructive commands, instructions to the agent and ways around the checks.
        case note
        /// Also what a one-sentence lesson may not hold: links, secret-related words and code fences.
        case lesson
    }

    /// Key formats that are never kept: also what the recall index strips before it stores text.
    public static let secretPattern = #"(sk-|ghp_|gho_|github_pat_|AKIA|xox[bp]-)[A-Za-z0-9_\-]{12,}"#

    private struct Rule { let reason: String; let terms: [String]; let pattern: String?; let lessonOnly: Bool }

    private static let rules: [Rule] = [
        Rule(reason: "looks like a secret or a key", terms: ["-----begin", "private key"], pattern: secretPattern, lessonOnly: false),
        Rule(reason: "fetches and runs code", terms: ["curl ", "wget ", "| sh", "| bash", "|sh", "|bash", "powershell -enc", "iex("], pattern: nil, lessonOnly: false),
        Rule(reason: "a destructive command", terms: ["sudo ", "rm -rf", "chmod 777", "mkfs", ":(){"], pattern: nil, lessonOnly: false),
        Rule(reason: "reads like an instruction to the agent", terms: ["ignore previous", "ignore all", "ignore the above", "ignore your instructions", "disregard", "system prompt", "you must always", "you must never", "from now on you"], pattern: nil, lessonOnly: false),
        Rule(reason: "tells the agent to skip checks", terms: ["skip the test", "skip tests", "skip the review", "skip review", "without review", "without running the test", "don't run the test", "do not run the test", "--no-verify", "disable the test", "disable the gate", "bypass the gate", "force-push", "force push"], pattern: nil, lessonOnly: false),
        Rule(reason: "has a link", terms: ["http://", "https://", "www."], pattern: nil, lessonOnly: true),
        Rule(reason: "mentions a secret", terms: ["api key", "api_key", "password", "secret", "token"], pattern: nil, lessonOnly: true),
        Rule(reason: "has a code block", terms: ["```"], pattern: nil, lessonOnly: true),
    ]

    /// Why the text may not be written without a person looking at it. Empty when it is fine.
    public static func problems(_ text: String, _ strictness: Strictness = .note) -> [String] {
        let l = text.lowercased()
        var out: [String] = []
        for r in rules where strictness == .lesson || !r.lessonOnly {
            if r.terms.contains(where: { l.contains($0) }) || (r.pattern.map { text.range(of: $0, options: .regularExpression) != nil } ?? false) { out.append(r.reason) }
        }
        return out
    }

    /// Who counts as a person: what they write is not filtered.
    public static func isPerson(_ actor: String) -> Bool { ["you", "restore", "outside edit"].contains(actor) }

    /// A note that is mostly wiped by an automated writer: its new text is under half of a note that had some substance.
    public static func wipes(old: String?, new: String) -> Bool {
        guard let old, old.count >= 400 else { return false }
        return new.count * 2 < old.count
    }
}

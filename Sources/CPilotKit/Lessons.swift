// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What CPilot learns from finished runs: a short list of lessons about one repository, kept as one memory note that every later session in that repository starts with.
/// The text comes from reviewers' reports and failures, so it is treated as untrusted: a lesson must be one short plain sentence and may not carry a link, a command that
/// fetches code or anything that reads like an instruction to the agent.
public enum Lessons {
    public static let noteName = "lessons-from-past-runs"
    public static let maxLessons = 10
    /// Claude is asked for under 200 characters and often writes a little more; this is the most that is kept.
    public static let maxLength = 300
    static let askedLength = 200
    public static let maxNew = 3
    static let header = "Learned automatically from finished runs. CPilot keeps this list up to date; edit or delete any line that is wrong."

    public struct Evidence: Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    /// Evidence is trimmed so one long report cannot crowd out the rest.
    public static let perEvidence = 1500
    public static let totalEvidence = 7000

    public static func prompt(repo: String, evidence: [Evidence], existing: [String]) -> String {
        var blocks: [String] = [], used = 0
        for e in evidence {
            let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let text = t.count > perEvidence ? String(t.prefix(perEvidence)) + " …" : t
            if used + text.count > totalEvidence { break }
            used += text.count
            blocks.append("=== \(e.label) ===\n\(text)")
        }
        let known = existing.isEmpty ? "" : "\nLessons already known (do not repeat or rephrase them):\n" + existing.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return """
        You are helping a coding agent do better work in one repository (\(URL(fileURLWithPath: repo).lastPathComponent)).

        Below is evidence from work that just finished there: reviewers' reports, failures, and the lead's closing summary. Write the lessons a future agent should know before it starts work here, so the same problems do not happen again.

        Rules:
        - At most \(maxNew) lessons. Fewer is better. If nothing is worth keeping, answer exactly NONE.
        - One idea per lesson, in one sentence under \(askedLength) characters, each on its own line starting with "- ".
        - Specific to this repository, its tooling or its conventions, and actionable ("Run X before Y", "Z needs W"). Not generic advice (write tests, handle errors), not about one pull request or one session, no pull request or issue numbers.
        - Say how to avoid the problem next time. Do not report a defect that is still open in a pull request; that is not a lesson.
        - Only what the evidence supports. Do not invent anything.
        - No links, no secrets, and no commands that download or run code from the internet.
        \(known)
        Answer with only the bullet lines, or NONE.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// A line that may be kept: plain, short, and free of anything that reads like a link, a secret or an instruction to the agent (the same rules as every automated memory writer, with the strict ones).
    public static func isAcceptable(_ line: String) -> Bool {
        !line.isEmpty && line.count <= maxLength && line.count >= 12 && MemoryLint.problems(line, .lesson).isEmpty
    }

    /// The lessons in Claude's answer: bullet lines only, at most `maxNew`, none that fail `isAcceptable`.
    public static func parse(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "NONE" { return [] }
        var out: [String] = []
        for raw in trimmed.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            if first == "-" || first == "*" || first == "•" { line.removeFirst() }
            else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty { line = String(line[line.index(after: dot)...]) }
            else { continue }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.uppercased() == "NONE" { continue }
            if isAcceptable(line), !out.contains(line) { out.append(line) }
            if out.count == maxNew { break }
        }
        return out
    }

    private static let stop: Set<String> = ["the", "and", "that", "this", "with", "for", "are", "not", "but", "from", "they", "was", "were", "has", "have", "had", "its", "can", "will",
                                            "should", "must", "need", "needs", "before", "after", "when", "then", "than", "into", "only", "also", "any", "all", "because", "since",
                                            "like", "such", "use", "uses", "used", "run", "runs", "make", "sure", "just", "same", "does", "doing", "done", "your", "you", "our"]

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
    }

    /// Two lessons that say nearly the same thing, even when one is a rewording of the other: most of the content words of the shorter one are in the longer one.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.5
    }

    /// The old lessons plus the new ones that are not repeats, newest last, oldest dropped past the cap.
    public static func merge(existing: [String], new: [String]) -> (lessons: [String], added: [String]) {
        var all = existing, added: [String] = []
        for n in new where !all.contains(where: { similar($0, n) }) { all.append(n); added.append(n) }
        return (Array(all.suffix(maxLessons)), added)
    }

    /// Adds new lessons to a repository's note. The note is read, merged and written under the memory lock, so runs that finish together each add theirs and none is lost.
    /// Returns the lessons that were added; empty when none were new.
    public static func record(_ new: [String], in store: MemoryStore, scope: String, reason: String) -> [String] {
        var added: [String] = []
        let saved = store.update(scope: scope, name: noteName, actor: "lessons", reason: reason) { body in
            let merged = merge(existing: read(body ?? ""), new: new)
            added = merged.added
            return merged.added.isEmpty ? nil : render(merged.lessons)
        }
        return saved == nil ? [] : added
    }

    public static func render(_ lessons: [String]) -> String { header + "\n\n" + lessons.map { "- \($0)" }.joined(separator: "\n") + "\n" }

    /// The bullet lines of a note, so lines the user added or edited by hand are kept.
    public static func read(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") ? String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil
        }.filter { !$0.isEmpty }
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One verification command and what it printed.
public struct GateCheck: Equatable, Sendable {
    public var command: String
    public var ok: Bool
    public var output: String
    public init(command: String, ok: Bool, output: String) { self.command = command; self.ok = ok; self.output = output }
}

/// What the gate has seen of one task so far. Kept per task while its session works.
public struct GateState: Codable, Equatable, Sendable {
    /// How many times the gate has run on this task.
    public var runs = 0
    /// The fingerprints of the last failures, newest last. A pass clears them.
    public var failures: [String] = []
    /// Why the gate gave up, once it has.
    public var escalated: String?
    public init() {}
}

public enum GateDecision: Equatable, Sendable {
    case pass
    /// Send this to the session as its next message.
    case retry(String)
    /// Stop retrying and tell the user.
    case escalate(String)
}

/// The check that runs when a task session says it is done. No model is involved: it runs the task's verification commands and the diff checks,
/// sends what failed back to the session, and stops retrying when the same failure keeps coming back or the task has used its turns.
public enum TaskGate {
    /// The same failure this many times in a row means the agent is not going to get out of it by itself.
    public static let sameFailureLimit = 3
    /// The most times the gate will send a task back before it asks the user.
    public static let runLimit = 15
    /// How much of a failure goes back to the session.
    public static let payloadLimit = 4000

    public static func decide(_ state: inout GateState, checks: [GateCheck], problems: [String]) -> GateDecision {
        state.runs += 1
        let failed = checks.filter { !$0.ok }
        if failed.isEmpty, problems.isEmpty { state.failures = []; return .pass }

        // Problems from the diff are part of the fingerprint, so an agent that keeps deleting the same assertion is caught like a failing build.
        state.failures.append(fingerprint(failed.map(\.output).joined(separator: "\n") + problems.joined(separator: "\n")))
        if state.failures.count >= sameFailureLimit, Set(state.failures.suffix(sameFailureLimit)).count == 1 {
            let why = "The same failure came back \(sameFailureLimit) times in a row."
            state.escalated = why
            return .escalate(why)
        }
        if state.runs >= runLimit {
            let why = "The task was sent back \(runLimit) times and is still not passing."
            state.escalated = why
            return .escalate(why)
        }
        return .retry(payload(failed: failed, problems: problems))
    }

    /// The message that goes back to the session.
    public static func payload(failed: [GateCheck], problems: [String]) -> String {
        var out = "CPilot checked your work before it goes to review, and it is not done yet. Fix this, then stop and say what you changed. Do not delete or weaken tests, and do not skip them, to make this pass."
        for c in failed {
            out += "\n\n`\(c.command)` failed:\n```\n\(tail(c.output, payloadLimit))\n```"
        }
        if !problems.isEmpty { out += "\n\nAlso:\n" + problems.map { "- \($0)" }.joined(separator: "\n") }
        return out
    }

    static func tail(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : "…" + String(t.suffix(n))
    }

    /// A short hash of what went wrong that ignores what changes between runs: numbers, times, hashes, temporary paths. Two runs that fail the same
    /// way give the same fingerprint, even though a line number or a duration moved.
    public static func fingerprint(_ output: String) -> String {
        var lines = output.split(whereSeparator: \.isNewline).map(String.init).filter(looksLikeAnError)
        if lines.isEmpty { lines = Array(output.split(whereSeparator: \.isNewline).map(String.init).suffix(10)) }
        let normal = lines.map(normalize).filter { !$0.isEmpty }
        var h: UInt64 = 0xcbf29ce484222325
        for b in normal.joined(separator: "\n").utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private static func looksLikeAnError(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["error", "failed", "failure", "fatal", "exception", "panic", "assert", "expected", "cannot", "unresolved", "undefined"].contains { l.contains($0) }
    }

    private static func normalize(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for (pattern, with) in [(#"\b[0-9a-f]{7,40}\b"#, "H"), (#"/(?:private/)?(?:var|tmp)/[^\s:]*"#, "T"), (#"\d+(?:\.\d+)?"#, "N")] {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        return s
    }
}

/// Checks on a task's diff that a passing build cannot see: tests that lost their assertions or were switched off, and a task that never touched the
/// files it was written for.
public enum DiffCheck {
    public static func problems(diff: String, touches: [String]) -> [String] {
        let files = parse(diff)
        var out: [String] = []
        for f in files where isTest(f.path) {
            if f.deleted { out.append("`\(f.path)` was deleted. Tests are not removed to make a task pass."); continue }
            let removed = f.removed.filter(isAssertion).count, added = f.added.filter(isAssertion).count
            if removed > added { out.append("`\(f.path)` lost \(removed - added) assertion\(removed - added == 1 ? "" : "s") (\(removed) removed, \(added) added). A test is changed to check the new behavior, not to check less.") }
            if f.added.contains(where: isSkip) { out.append("`\(f.path)` has a test turned off or skipped. Fix the test or the code instead.") }
        }
        let changed = files.map(\.path)
        let named = touches.filter { !$0.isEmpty }
        if !named.isEmpty, !changed.isEmpty, !changed.contains(where: { path in named.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }) {
            out.append("The task names \(named.map { "`\($0)`" }.joined(separator: ", ")) but none of them changed (the change touched \(changed.prefix(3).map { "`\($0)`" }.joined(separator: ", "))\(changed.count > 3 ? " and more" : "")). Check that the change is what the task asks for.")
        }
        return out
    }

    struct FileDiff { var path: String; var added: [String] = []; var removed: [String] = []; var deleted = false }

    static func parse(_ diff: String) -> [FileDiff] {
        var out: [FileDiff] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                // "diff --git a/x b/x": the new path is what follows " b/".
                let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? ""
                out.append(FileDiff(path: path))
            } else if line.hasPrefix("deleted file mode"), !out.isEmpty { out[out.count - 1].deleted = true }
            else if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            else if line.hasPrefix("+"), !out.isEmpty { out[out.count - 1].added.append(String(line.dropFirst())) }
            else if line.hasPrefix("-"), !out.isEmpty { out[out.count - 1].removed.append(String(line.dropFirst())) }
        }
        return out
    }

    static func isTest(_ path: String) -> Bool {
        let p = path.lowercased(), name = (p as NSString).lastPathComponent
        return p.contains("/tests/") || p.hasPrefix("tests/") || p.contains("/test/") || p.hasPrefix("test/") || p.contains("/__tests__/")
            || name.contains("test.") || name.contains("tests.") || name.contains(".spec.") || name.hasPrefix("test_") || name.hasSuffix("_test.go") || name.hasSuffix("_spec.rb")
    }

    static func isAssertion(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("//") || (l.hasPrefix("#") && !l.hasPrefix("#expect") && !l.hasPrefix("#require")) { return false }
        return ["XCTAssert", "XCTFail", "#expect", "#require", "assert", "expect(", ".should", "t.Error", "t.Fatal", "require."].contains { l.contains($0) }
    }

    static func isSkip(_ line: String) -> Bool {
        ["XCTSkip", ".disabled", "@Test(.disabled", ".skip(", "it.skip", "xit(", "xdescribe(", "@pytest.mark.skip", "@unittest.skip", "t.Skip"].contains { line.contains($0) }
    }
}

/// What the gate knows about one task, kept across restarts: its counters, whether it gave up, whether it is waiting for the answer to a message it
/// sent back, and the commit it last passed on (so a task that has not changed since is not checked again).
public struct GateRecord: Codable, Equatable, Sendable {
    public var state = GateState()
    public var held: String?
    public var answering = false
    public var passedHead: String?
    public var updated = Date()
    public init() {}
}

/// The gate's records, one per task, in a file next to the other app data. Thread safe. Records not touched for two months are dropped.
public final class GateStore: @unchecked Sendable {
    public static let keepDays = 60
    private let url: URL?
    private let lock = NSLock()
    private var rows: [String: GateRecord]

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL? = AppPaths().root.appendingPathComponent("gates.json")) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        rows = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? dec.decode([String: GateRecord].self, from: $0) } ?? [:]
    }

    /// The key for one task of one spec in one repository.
    public static func key(repo: String, environment: String?, spec: String, task: String) -> String { "\(environment ?? "")|\(repo)|\(spec)/\(task)" }

    /// The start of every key of one spec's tasks.
    public static func specPrefix(repo: String, environment: String?, spec: String) -> String { "\(environment ?? "")|\(repo)|\(spec)/" }

    /// Forgets every record whose key starts with `prefix` (a spec that was deleted or archived).
    public func removeAll(prefix: String) {
        lock.lock(); defer { lock.unlock() }
        let before = rows.count
        rows = rows.filter { !$0.key.hasPrefix(prefix) }
        if rows.count != before { save() }
    }

    public func record(_ key: String) -> GateRecord? { lock.lock(); defer { lock.unlock() }; return rows[key] }

    public func set(_ r: GateRecord?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if var r { r.updated = .now; rows[key] = r } else { rows[key] = nil }
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        rows = rows.filter { $0.value.updated >= cutoff }
        save()
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? enc.encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

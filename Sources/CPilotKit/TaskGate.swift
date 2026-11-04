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
    /// The commit whose protected-file changes the user was last told about, so a re-check does not say it twice. Optional so older files still load.
    public var flaggedHead: String?
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
    public static func problems(diff: String, touches: [String], protected: [String] = ScopeGuard.defaultProtected) -> [String] {
        let files = parse(diff)
        var out: [String] = []
        for f in files where isTest(f.path) {
            if f.deleted { out.append("`\(f.path)` was deleted. Tests are not removed to make a task pass."); continue }
            let removed = f.removed.filter(isAssertion).count, added = f.added.filter(isAssertion).count
            if removed > added { out.append("`\(f.path)` lost \(removed - added) assertion\(removed - added == 1 ? "" : "s") (\(removed) removed, \(added) added). A test is changed to check the new behavior, not to check less.") }
            if f.added.contains(where: isSkip) { out.append("`\(f.path)` has a test turned off or skipped. Fix the test or the code instead.") }
        }
        out += Secrets.problems(files)
        out += ScopeGuard.problems(files, touches: touches, protected: protected)
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
    /// Times the session was told to carry on after a turn that wrote nothing; cleared by a turn that did. Optional so older files still load.
    public var nudges: Int?
    /// What the task came to when it last passed. Optional so older files still load.
    public var summary: TaskSummary?
    /// What the session had used when the user last stepped in; the task's budget counts from there. Optional so older files still load.
    public var budgetBase: TaskUsage?
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


/// Keys and private files that must never reach a commit. The gate sends the finding back before a task goes to review. A finding names the file and
/// the kind of secret, never the secret itself, so it does not spread into logs or the agent's next message.
enum Secrets {
    struct Rule { var kind: String; var pattern: String }

    /// High confidence: each of these shapes is a credential wherever it appears.
    static let rules = [
        Rule(kind: "a private key", pattern: #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----"#),
        Rule(kind: "an AWS access key", pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(kind: "a GitHub token", pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"#),
        Rule(kind: "an Anthropic API key", pattern: #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
        Rule(kind: "an OpenAI API key", pattern: #"\bsk-(?:proj-)?[A-Za-z0-9_-]{40,}"#),
        Rule(kind: "a Slack token", pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        Rule(kind: "a live Stripe key", pattern: #"\b[rs]k_live_[A-Za-z0-9]{16,}"#),
        Rule(kind: "a Google API key", pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#),
    ]
    /// Lower confidence: a name that says secret, set to a long literal. Skipped in tests, and when the value looks like a placeholder.
    static let assignment = #"(?i)\b[\w.-]*(?:password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)\b["']?\s*[:=]\s*["']([^"'\s]{16,})["']"#
    static let placeholder = ["example", "placeholder", "changeme", "change-me", "your", "xxxx", "dummy", "fake", "sample", "redacted", "<", "${", "{{", "$(", "process.env", "getenv", "environ"]

    static func problems(_ files: [DiffCheck.FileDiff]) -> [String] {
        var out: [String] = []
        let assign = try? NSRegularExpression(pattern: assignment)
        for f in files where !f.deleted {
            var found: [String] = []
            let name = (f.path as NSString).lastPathComponent.lowercased()
            if (name == ".env" || name.hasPrefix(".env.") && !["example", "sample", "template", "dist"].contains { name.hasSuffix($0) })
                || [".pem", ".p12", ".pfx", ".keystore"].contains(where: name.hasSuffix) || ["id_rsa", "id_ed25519", "id_ecdsa"].contains(name) {
                found.append("a file that holds secrets")
            }
            for line in f.added {
                let l = line.lowercased()
                for r in rules where !found.contains(r.kind) && line.range(of: r.pattern, options: .regularExpression) != nil && !l.contains("example") { found.append(r.kind) }
                if !DiffCheck.isTest(f.path), !found.contains("a hard-coded secret"), let assign,
                   let m = assign.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line),
                   !placeholder.contains(where: { line[r].lowercased().contains($0) }) { found.append("a hard-coded secret") }
            }
            for kind in found {
                out.append("`\(f.path)` contains \(kind). Never commit one: take it out, read it from the environment or the keychain, and rewrite the commit so it is not in the history (`git commit --amend`, or `git rebase -i`). If it is real, tell the user to revoke it, because it has been written to disk and may have been sent to a model.")
            }
        }
        return out
    }
}

/// What to do when a task session ends a turn having written nothing. Nobody wakes it, so it sits until the user prompts it.
public enum TaskNudge {
    /// How many times a session is told to carry on before the user is asked to look.
    public static let limit = 2

    public enum Action: Equatable, Sendable {
        /// Send this to the session.
        case nudge(String)
        /// The session asked the user something; leave it for them.
        case asked
        /// It was told to carry on `limit` times and still wrote nothing.
        case giveUp
    }

    public static func decide(lastText: String, nudges: Int) -> Action {
        if asksQuestion(lastText) { return .asked }
        if nudges >= limit { return .giveUp }
        return .nudge("CPilot: you ended your turn without writing any changes for this task. Nobody will prompt you. Carry on and finish it now: make the change, run the tests, and commit it. If you are blocked on something only the user can answer, ask it in one line and stop.")
    }

    /// True when the last paragraph of a message ends in a question mark: the agent waits for an answer, not for a push.
    public static func asksQuestion(_ text: String) -> Bool {
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").last ?? ""
        return last.trimmingCharacters(in: CharacterSet(charactersIn: "*_` \n")).hasSuffix("?")
    }
}


/// Limits on what one task may change by itself: files that decide how the project is built, checked and shipped, and a change too big to review.
/// A task that names a protected file in its `touches:` may change it (the spec the user approved says so), and the user is told to look.
public enum ScopeGuard {
    /// What a repository protects when it says nothing: CI and the gate's own commands, ownership, and secrets files. A repository adds its own, one
    /// per line, in `.cpilot/protected`: a folder (`deploy/`), a file name (`Dockerfile`), or a pattern (`*.tf`, `.env*`).
    public static let defaultProtected = [".github/", ".cpilot/", "CODEOWNERS", ".env*"]
    /// More than this many files, or this many changed lines, is more than one task should do.
    public static let maxFiles = 40
    public static let maxLines = 1500

    /// True when `path` is covered by an entry of `protected`.
    public static func isProtected(_ path: String, _ protected: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        // A template (`.env.example`) holds no secrets and is meant to be edited.
        if ["example", "sample", "template", "dist"].contains(where: { name.lowercased().hasSuffix("." + $0) }) { return false }
        return protected.contains { entry in
            if entry.hasSuffix("/") { return path.hasPrefix(entry) || path.contains("/" + entry) }
            if entry.contains("*") {
                let re = "^" + NSRegularExpression.escapedPattern(for: entry).replacingOccurrences(of: "\\*", with: "[^/]*") + "$"
                return name.range(of: re, options: .regularExpression) != nil || path.range(of: re, options: .regularExpression) != nil
            }
            return path == entry || name == entry
        }
    }

    static func named(_ path: String, _ touches: [String]) -> Bool {
        touches.contains { !$0.isEmpty && (path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")) }
    }

    /// The protected files a task changed that its spec does name: allowed, but the user should look at them.
    public static func flagged(diff: String, touches: [String], protected: [String]) -> [String] {
        DiffCheck.parse(diff).map(\.path).filter { isProtected($0, protected) && named($0, touches) }
    }

    static func problems(_ files: [DiffCheck.FileDiff], touches: [String], protected: [String]) -> [String] {
        var out: [String] = []
        for f in files where isProtected(f.path, protected) && !named(f.path, touches) {
            out.append("`\(f.path)` is a protected file (it decides how the project is built, checked or shipped) and this task does not name it. Undo that change. If the task cannot be done without it, say so in one line and stop instead of changing it.")
        }
        let counted = files.filter { !isGenerated($0.path) }
        let lines = counted.reduce(0) { $0 + $1.added.count + $1.removed.count }
        if counted.count > maxFiles || lines > maxLines {
            out.append("The change is very large for one task (\(counted.count) files, \(lines) changed lines; the limit is \(maxFiles) files and \(maxLines) lines). Check that nothing outside the task crept in, and leave what does not belong to it out.")
        }
        return out
    }

    /// Lock files, snapshots and minified output grow with the work and say little about its size.
    static func isGenerated(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        return n.hasSuffix(".lock") || ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.resolved", "cargo.lock", "go.sum"].contains(n)
            || n.hasSuffix(".min.js") || n.hasSuffix(".snap") || n.hasSuffix(".svg")
    }
}

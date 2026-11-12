// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A rule that must hold for every change in a repository, written down once in `.cpilot/invariants` ("no request leaves the configured origin", "every delete route needs a fresh sign-in").
/// The tester turns each into a test and the reviewer attacks them, whatever the spec of the day says.
public struct Invariant: Equatable, Sendable {
    public var id: String
    public var text: String
}

public enum Invariants {
    /// One rule per line, starting with `-`, `*` or a number. Blank lines, headings and `#` comments are skipped. Ids are I1, I2, … in order.
    public static func parse(_ text: String) -> [Invariant] {
        var out: [Invariant] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#") else { continue }
            let body: String
            if l.hasPrefix("- ") || l.hasPrefix("* ") { body = String(l.dropFirst(2)) }
            else if let dot = l.firstIndex(where: { $0 == "." || $0 == ")" }), !l[..<dot].isEmpty, l[..<dot].allSatisfy(\.isNumber) { body = String(l[l.index(after: dot)...]) }
            else { continue }
            let t = body.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(Invariant(id: "I\(out.count + 1)", text: t)) }
        }
        return out
    }
}

/// Tests written before the code, by someone who did not write the code. The tester sees the spec's requirements and the repository's invariants, writes tests that fail now, and
/// reports which test covers which requirement. The tests are then locked: the implementer cannot change them, and the gate runs the tester's copy.
public enum TestFirst {
    public enum Mode: String, Sendable { case off, risky, all }

    /// Words that make a task worth testing first. A task is risky when its title, the files it names or the requirements it covers mention one.
    static let riskyWords = ["auth", "login", "password", "passkey", "session", "token", "secret", "crypt", "permission", "role", "tenant", "isolation", "security", "csrf", "cors", "sanitiz",
                             "delete", "remove", "purge", "destroy", "payment", "billing", "invoice", "charge", "refund", "money", "migration", "schema", "database", "concurren", "race", "lock",
                             "gateway", "proxy", "upstream", "redirect", "upload", "webhook", "rate limit", "audit", "privacy", "pii", "encrypt"]

    /// Whether this task gets a tester first, and why (the reasons are shown to the user).
    public static func decide(mode: Mode, task: SpecTask, criteria: [Specs.Criterion]) -> (test: Bool, reasons: [String]) {
        switch mode {
        case .off: return (false, [])
        case .all: return (true, ["every task is tested first"])
        case .risky:
            let hay = ([task.title] + task.touches + criteria.map(\.text)).joined(separator: " ").lowercased()
            let hits = riskyWords.filter { hay.contains($0) }
            return (!hits.isEmpty, hits.prefix(4).map { "mentions \"\($0)\"" })
        }
    }

    // MARK: Prompts

    public static func testerPrompt(task: SpecTask, criteria: [Specs.Criterion], invariants: [Invariant], constitution: String?, hidden: Bool) -> String {
        var reqs = ""
        for c in criteria { reqs += "- \(c.id): \(c.text)\n" + c.checks.map { "    \($0)\n" }.joined() }
        if reqs.isEmpty { reqs = "- (The spec does not number its requirements. Use the task title and the spec text you are given.)\n" }
        let rules = invariants.isEmpty ? "" : "\nRules that hold for every change in this repository (each one needs a test too):\n" + invariants.map { "- \($0.id): \($0.text)" }.joined(separator: "\n") + "\n"
        let hiddenPart = hidden ? """

        Some tests stay hidden from the person who writes the code, so it cannot be fitted to them. Put roughly a third of your tests (the ones for edge cases, abuse and every setting combination) in files of their own, and end your report with one line `HIDDEN: <path>, <path>` naming those files. Every other test file is shown to the implementer.
        """ : ""
        return """
        \(constitution.map { "Project rules:\n\($0)\n\n" } ?? "")You are the tester for one task of a spec. You write the tests, and somebody else writes the code, so you are the check on their reading of the spec. Do not write or change any code that is not a test.

        Task \(task.id): \(task.title)

        Requirements this task covers, with the checks written for them:
        \(reqs)\(rules)
        Write tests that fail now and pass once the task is done correctly:
        1. One or more tests for every requirement and every check above. A test checks the behavior the spec states, through the public interface, not how the code happens to work.
        2. Also test what the spec does not spell out but a user or an attacker would try: empty, huge, malformed and hostile input; boundaries; errors and what is shown to the caller; permissions; what happens twice or at once.
        3. Where code takes input from outside (paths, headers, payloads, files) add a property-based or fuzz test if the language has one, so inputs nobody thought of are tried.
        4. Where a setting, flag or mode changes behavior, test every value of it, not only the default.
        5. Read the repository to learn its test framework, layout and names, and follow them. Read the code only to find interfaces and names; do not design the tests around an implementation.
        6. Run the tests. They must fail now, because the code does not exist yet, and for the right reason: a missing function or an assertion that does not hold, not a typo in the test. A test that passes without the task being done checks nothing.
        7. Commit only test files with the message "\(task.id) tests: \(task.title)". Do not push.\(hiddenPart)

        End your report with one line per requirement, check and rule, in this exact form, naming the test that covers it:
        TRACE: <id>: <test name>, <test name>
        for example `TRACE: A2: testRejectsEmptyName, testRejectsLongName`. An id with no test is a gap you must close before you finish.
        """
    }

    /// The ids the tester must cover: each acceptance check (A1, A2, …) of the requirements, or the requirement itself when it has none, and every rule.
    public static func requiredIds(criteria: [Specs.Criterion], invariants: [Invariant]) -> [String] {
        var out: [String] = []
        for c in criteria {
            let checks = c.checks.compactMap { $0.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "." }).first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*`")).uppercased() } }.filter { !$0.isEmpty }
            out += checks.isEmpty ? [c.id] : checks
        }
        out += invariants.map(\.id)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public static func implementerNote(files: [String], hiddenCount: Int) -> String {
        """

        These tests were written first by an independent tester from the spec: \(files.map { "`\($0)`" }.joined(separator: ", ")). They are locked. Do not edit, delete, rename, skip or weaken them; CPilot checks, and runs the tester's own copy. Make them pass by writing the code.\(hiddenCount > 0 ? " Further checks are held back and run when you finish, so write the behavior the spec asks for, not only what these tests show." : "")
        If you are sure a test contradicts the spec, do not work around it. Stop and end your message with one line `TEST_DISPUTE: <test name>: <what the spec says and why the test is wrong>`; the tester will look at it.
        """
    }

    public static func disputePrompt(task: SpecTask, dispute: String, criteria: [Specs.Criterion] = []) -> String {
        let reqs = criteria.map { "- \($0.id): \($0.text)" + $0.checks.map { "\n    \($0)" }.joined() }.joined(separator: "\n")
        return """
        You are the tester who wrote the locked tests for task \(task.id): \(task.title). The implementer disputes one of them:

        \(dispute)
        \(reqs.isEmpty ? "" : "\nThe requirements of this task:\n\(reqs)\n")
        Decide from the spec, not from the implementer's wish to pass. If the test is wrong, fix it (or remove it and say why) and commit with the message "\(task.id) tests: amend". If the test is right, change nothing. Either way end with one line:
        DISPUTE: UPHELD, because <reason>      (the test stays)
        DISPUTE: AMENDED, because <reason>     (you changed the tests)
        """
    }

    // MARK: Reading what the tester says

    /// `TRACE: A2: testOne, testTwo` lines as id → tests.
    public static func parseTrace(_ report: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for raw in report.split(whereSeparator: \.isNewline) {
            var l = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *`-"))
            guard l.uppercased().hasPrefix("TRACE:") else { continue }
            l = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let colon = l.firstIndex(of: ":") else { continue }
            let id = l[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " *`")).uppercased()
            let tests = l[l.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *`.")) }.filter { !$0.isEmpty }
            if !id.isEmpty, !tests.isEmpty { out[id, default: []] += tests }
        }
        return out
    }

    /// `HIDDEN: a.swift, b.swift` as paths.
    public static func parseHidden(_ report: String) -> [String] {
        for raw in report.split(whereSeparator: \.isNewline).reversed() {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *`-"))
            if l.uppercased().hasPrefix("HIDDEN:") { return l.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *`")) }.filter { !$0.isEmpty } }
        }
        return []
    }

    /// What is wrong with the tester's work: requirements with no test, tests that are not in any changed file, files that are not tests.
    /// `files` maps each changed path to its new text.
    public static func problems(required: [String], trace: [String: [String]], files: [String: String]) -> [String] {
        var out: [String] = []
        let notTests = files.keys.filter { !DiffCheck.isTest($0) }.sorted()
        if !notTests.isEmpty { out.append("Only test files may change. These are not tests: " + notTests.map { "`\($0)`" }.joined(separator: ", ") + ".") }
        if files.isEmpty { out.append("No test file was committed.") }
        let missing = required.filter { trace[$0.uppercased()] == nil }
        if !missing.isEmpty { out.append("No test is named for: " + missing.joined(separator: ", ") + ". Add one TRACE line for each.") }
        let all = files.values.joined(separator: "\n")
        for id in required where trace[id.uppercased()] != nil {
            let absent = trace[id.uppercased()]!.filter { !all.contains(testBaseName($0)) }
            if !absent.isEmpty { out.append("\(id) names tests that are not in the changed files: " + absent.map { "`\($0)`" }.joined(separator: ", ") + ".") }
        }
        return out
    }

    /// `FooTests.testBar()` and `FooTests/testBar` both look for `testBar`.
    static func testBaseName(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespaces)
        if let i = n.lastIndex(where: { $0 == "." || $0 == "/" || $0 == "#" }) { n = String(n[n.index(after: i)...]) }
        if let p = n.firstIndex(of: "(") { n = String(n[..<p]) }
        return n
    }

    // MARK: Red

    public enum Red: Equatable, Sendable {
        /// The tests fail now: this is what the tester should hand over. `why` says how, for the person reading.
        case red(why: String)
        /// The tests pass with no code written: they check nothing.
        case green
        /// They fail, but not in a way that shows a missing behavior (for example a command that could not run).
        case unclear(String)
    }

    private static let missingCode = ["cannot find", "no such module", "undefined", "is not defined", "has no member", "not a member", "cannot resolve", "modulenotfounderror", "importerror", "cannot find symbol",
                                      "unresolved", "is not a function", "cannot read prop", "could not find module", "no matching function", "use of unresolved"]
    private static let assertion = ["assert", "expected", "xctassert", "#expect", "failed:", "fail:", "--- fail", "expect(", "should", "received", "not equal", "to equal", "to be"]
    private static let broken = ["syntax error", "syntaxerror", "unexpected token", "parse error", "expected expression", "expected declaration", "command not found", "permission denied", "unterminated"]

    /// Whether the tests, run on the code as it is, are properly red. Passing means the tests are empty; a syntax error or a missing tool means the tester must try again.
    public static func red(_ checks: [GateCheck]) -> Red {
        guard let failed = checks.first(where: { !$0.ok }) else { return checks.isEmpty ? .unclear("No verification command is set for this repository, so there is nothing to run the tests with.") : .green }
        let out = failed.output.lowercased()
        if broken.contains(where: out.contains), !missingCode.contains(where: out.contains) { return .unclear("`\(failed.command)` failed in a way that looks like a mistake in the tests themselves, not a missing behavior.") }
        if missingCode.contains(where: out.contains) { return .red(why: "the tests refer to code that does not exist yet") }
        if assertion.contains(where: out.contains) { return .red(why: "assertions fail") }
        return .unclear("`\(failed.command)` failed, but its output does not show a missing behavior or a failed assertion.")
    }

    // MARK: Disputes

    /// The dispute in an implementer's closing message, if it made one.
    public static func parseDispute(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *`-"))
            if l.uppercased().hasPrefix("TEST_DISPUTE:") {
                let d = l.dropFirst(13).trimmingCharacters(in: .whitespaces)
                return d.count >= 10 ? String(d.prefix(1000)) : nil
            }
        }
        return nil
    }

    public enum Ruling: Equatable, Sendable { case upheld(String), amended(String) }

    public static func parseRuling(_ text: String) -> Ruling? {
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *`-"))
            guard l.uppercased().hasPrefix("DISPUTE:") else { continue }
            let rest = l.dropFirst(8).trimmingCharacters(in: .whitespaces)
            let reason = rest.range(of: "because", options: .caseInsensitive).map { String(rest[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if rest.uppercased().hasPrefix("UPHELD") { return .upheld(reason) }
            if rest.uppercased().hasPrefix("AMENDED") { return .amended(reason) }
        }
        return nil
    }

    /// How many times one task's tests may be disputed before it goes to a person.
    public static let disputeLimit = 2
}

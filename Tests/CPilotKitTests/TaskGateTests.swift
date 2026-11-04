// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class TaskGateTests: XCTestCase {
    private func fail(_ out: String = "error: cannot find 'foo' in scope") -> [GateCheck] { [GateCheck(command: "swift build", ok: false, output: out)] }
    private let pass = [GateCheck(command: "swift build", ok: true, output: "")]

    func testPassingChecksPassAndClearEarlierFailures() {
        var s = GateState()
        XCTAssertEqual(TaskGate.decide(&s, checks: fail(), problems: []).isRetry, true)
        XCTAssertEqual(TaskGate.decide(&s, checks: pass, problems: []), .pass)
        XCTAssertTrue(s.failures.isEmpty)
    }

    func testAFailureGoesBackWithItsOutput() {
        var s = GateState()
        guard case .retry(let text) = TaskGate.decide(&s, checks: fail(), problems: ["a problem"]) else { return XCTFail() }
        XCTAssertTrue(text.contains("swift build"))
        XCTAssertTrue(text.contains("cannot find 'foo'"))
        XCTAssertTrue(text.contains("a problem"))
    }

    func testTheSameFailureThreeTimesInARowEscalates() {
        var s = GateState()
        // Line numbers and durations move between runs; the failure is the same.
        XCTAssertTrue(TaskGate.decide(&s, checks: fail("Foo.swift:12: error: cannot find 'x' (0.31s)"), problems: []).isRetry)
        XCTAssertTrue(TaskGate.decide(&s, checks: fail("Foo.swift:14: error: cannot find 'x' (0.45s)"), problems: []).isRetry)
        guard case .escalate = TaskGate.decide(&s, checks: fail("Foo.swift:20: error: cannot find 'x' (0.2s)"), problems: []) else { return XCTFail() }
        XCTAssertNotNil(s.escalated)
    }

    func testDifferentFailuresDoNotCountAsTheSame() {
        var s = GateState()
        for msg in ["error: cannot find 'a'", "error: cannot find 'b'", "error: type mismatch", "error: cannot find 'a'"] {
            XCTAssertTrue(TaskGate.decide(&s, checks: fail(msg), problems: []).isRetry, msg)
        }
    }

    func testAFailureBetweenTwoSameOnesBreaksTheRun() {
        var s = GateState()
        _ = TaskGate.decide(&s, checks: fail("error: a"), problems: [])
        _ = TaskGate.decide(&s, checks: fail("error: a"), problems: [])
        _ = TaskGate.decide(&s, checks: fail("error: b"), problems: [])
        XCTAssertTrue(TaskGate.decide(&s, checks: fail("error: a"), problems: []).isRetry)
    }

    func testTheRunLimitEscalates() {
        var s = GateState()
        var last = GateDecision.pass
        for i in 0..<TaskGate.runLimit { last = TaskGate.decide(&s, checks: fail("error: distinct \(i)x\(String(repeating: "y", count: i))"), problems: []) }
        guard case .escalate = last else { return XCTFail("\(last)") }
    }

    func testLongOutputIsCutFromTheFront() {
        let long = String(repeating: "noise\n", count: 2000) + "error: the real one"
        let text = TaskGate.payload(failed: fail(long), problems: [])
        XCTAssertTrue(text.contains("the real one"))
        XCTAssertLessThan(text.count, 5000)
    }

    func testFingerprintIgnoresNumbersAndTemporaryPaths() {
        XCTAssertEqual(TaskGate.fingerprint("/var/folders/ab/T/x1/a.swift:10:5: error: boom 3 tests"), TaskGate.fingerprint("/var/folders/cd/T/y2/a.swift:99:1: error: boom 7 tests"))
        XCTAssertNotEqual(TaskGate.fingerprint("error: boom"), TaskGate.fingerprint("error: bang"))
    }

    // MARK: Diff checks

    private func diff(_ path: String, add: [String] = [], remove: [String] = [], deleted: Bool = false) -> String {
        var s = "diff --git a/\(path) b/\(path)\n"
        if deleted { s += "deleted file mode 100644\n" }
        s += "--- a/\(path)\n+++ b/\(path)\n@@ -1,3 +1,3 @@\n"
        s += remove.map { "-" + $0 + "\n" }.joined() + add.map { "+" + $0 + "\n" }.joined()
        return s
    }

    func testDeletedAssertionsAreCaught() {
        let d = diff("Tests/FooTests.swift", add: ["XCTAssertTrue(ok)"], remove: ["XCTAssertEqual(a, 1)", "XCTAssertEqual(b, 2)"])
        let p = DiffCheck.problems(diff: d, touches: [])
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].contains("lost 1 assertion"))
    }

    func testReplacingAssertionsIsFine() {
        let d = diff("Tests/FooTests.swift", add: ["XCTAssertEqual(a, 2)"], remove: ["XCTAssertEqual(a, 1)"])
        XCTAssertTrue(DiffCheck.problems(diff: d, touches: []).isEmpty)
    }

    func testDeletedAndSkippedTestsAreCaught() {
        XCTAssertTrue(DiffCheck.problems(diff: diff("Tests/A.swift", deleted: true), touches: []).first?.contains("deleted") ?? false)
        XCTAssertTrue(DiffCheck.problems(diff: diff("tests/a.test.ts", add: ["it.skip('x', () => {})"]), touches: []).first?.contains("skipped") ?? false)
    }

    func testAssertionsRemovedFromSourceFilesAreNotTestsLost() {
        XCTAssertTrue(DiffCheck.problems(diff: diff("Sources/A.swift", remove: ["assert(x)"]), touches: []).isEmpty)
    }

    func testTheTaskMustTouchWhatItNames() {
        let d = diff("Sources/Other.swift", add: ["x"])
        XCTAssertEqual(DiffCheck.problems(diff: d, touches: ["Sources/Hush/"]).count, 1)
        XCTAssertTrue(DiffCheck.problems(diff: diff("Sources/Hush/A.swift", add: ["x"]), touches: ["Sources/Hush"]).isEmpty)
        XCTAssertTrue(DiffCheck.problems(diff: d, touches: []).isEmpty)
        XCTAssertTrue(DiffCheck.problems(diff: "", touches: ["Sources/Hush"]).isEmpty, "no change at all is not this check's to judge")
    }
}

private extension GateDecision {
    var isRetry: Bool { if case .retry = self { true } else { false } }
}

final class VerifyKeyTests: XCTestCase {
    func testVerifyIsParsedAndWrittenBack() {
        let line = "- [ ] T002 Add paging (R2) needs: T001 touches: Sources/A.swift, Tests/ATests.swift verify: `swift test --filter ATests, BTests` branch: spec-1-t2"
        let t = Specs.parseTasks(line)[0]
        XCTAssertEqual(t.verify, "swift test --filter ATests, BTests")
        XCTAssertEqual(t.touches, ["Sources/A.swift", "Tests/ATests.swift"])
        XCTAssertEqual(t.branch, "spec-1-t2")
        XCTAssertEqual(Specs.parseTasks(Specs.render(t))[0], t)
    }

    func testTasksWithoutVerifyStillParse() {
        XCTAssertNil(Specs.parseTasks("- [ ] T001 Do it (R1)")[0].verify)
    }
}

final class GateStoreTests: XCTestCase {
    private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("gates-\(UUID().uuidString).json") }

    func testARecordSurvivesAReload() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let key = GateStore.key(repo: "/r", environment: nil, spec: "001-x", task: "T001")
        var rec = GateRecord()
        _ = TaskGate.decide(&rec.state, checks: [GateCheck(command: "swift build", ok: false, output: "error: boom")], problems: [])
        rec.held = "stuck"; rec.answering = true; rec.passedHead = "abc123"
        GateStore(url: url).set(rec, for: key)

        let back = GateStore(url: url).record(key)
        XCTAssertEqual(back?.held, "stuck")
        XCTAssertEqual(back?.state.runs, 1)
        XCTAssertEqual(back?.state.failures.count, 1)
        XCTAssertEqual(back?.passedHead, "abc123")
        XCTAssertEqual(back?.answering, true)
    }

    func testRepositoriesAndEnvironmentsDoNotShareRecords() {
        XCTAssertNotEqual(GateStore.key(repo: "/a", environment: nil, spec: "s", task: "T1"), GateStore.key(repo: "/b", environment: nil, spec: "s", task: "T1"))
        XCTAssertNotEqual(GateStore.key(repo: "/a", environment: nil, spec: "s", task: "T1"), GateStore.key(repo: "/a", environment: "pi", spec: "s", task: "T1"))
    }

    func testClearingAndPruning() {
        let store = GateStore(url: nil)
        store.set(GateRecord(), for: "k")
        XCTAssertNotNil(store.record("k"))
        store.set(nil, for: "k")
        XCTAssertNil(store.record("k"))
        var old = GateRecord(); old.updated = Date().addingTimeInterval(-Double(GateStore.keepDays + 1) * 86_400)
        store.set(GateRecord(), for: "fresh")
        // `set` stamps the time, so an old row can only come from a file; write one.
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(["old": old]).write(to: url)
        let loaded = GateStore(url: url)
        XCTAssertNotNil(loaded.record("old"))
        loaded.set(GateRecord(), for: "new")
        XCTAssertNil(loaded.record("old"), "a record untouched for two months is dropped on the next write")
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class TestFirstTests: XCTestCase {
    let task = SpecTask(id: "T003", title: "Reject upstream hosts that are not configured", done: false, covers: ["R2"])
    let criteria = [Specs.Criterion(id: "R2", text: "A request can never leave the configured origin.", checks: ["A2 (R2) A path starting with // stays on the origin."])]

    // MARK: Invariants

    func testInvariantsAreReadOnePerLine() {
        let text = """
        # What must always hold
        - The control plane never holds tenant data.
        * Every delete route needs a fresh sign-in.
        3. No request leaves the configured origin.
        Some prose that is not a rule.

        -
        """
        XCTAssertEqual(Invariants.parse(text), [Invariant(id: "I1", text: "The control plane never holds tenant data."), Invariant(id: "I2", text: "Every delete route needs a fresh sign-in."),
                                                 Invariant(id: "I3", text: "No request leaves the configured origin.")])
        XCTAssertEqual(Invariants.parse(""), [])
    }

    // MARK: Which tasks

    func testModesDecideWhichTasksGetATesterAndSayWhy() {
        XCTAssertFalse(TestFirst.decide(mode: .off, task: task, criteria: criteria).test)
        XCTAssertTrue(TestFirst.decide(mode: .all, task: SpecTask(id: "T1", title: "Rename a label", done: false), criteria: []).test)
        let risky = TestFirst.decide(mode: .risky, task: task, criteria: criteria)
        XCTAssertTrue(risky.test); XCTAssertTrue(risky.reasons.contains { $0.contains("upstream") || $0.contains("redirect") || $0.contains("gateway") })
        let plain = TestFirst.decide(mode: .risky, task: SpecTask(id: "T2", title: "Rename a label in the toolbar", done: false, touches: ["Sources/Toolbar.swift"]), criteria: [])
        XCTAssertFalse(plain.test); XCTAssertEqual(plain.reasons, [])
        XCTAssertTrue(TestFirst.decide(mode: .risky, task: SpecTask(id: "T3", title: "Add a button", done: false, touches: ["Sources/Auth/Login.swift"]), criteria: []).test)   // a file the task names counts
    }

    // MARK: The prompts

    func testTesterPromptCarriesRequirementsRulesAndTheTraceFormat() {
        let p = TestFirst.testerPrompt(task: task, criteria: criteria, invariants: [Invariant(id: "I1", text: "No request leaves the configured origin.")], constitution: "Use Swift Testing.", hidden: false)
        for expected in ["Use Swift Testing.", "T003", "R2: A request can never leave", "A2 (R2) A path starting with //", "I1: No request leaves", "fuzz", "every value of it", "must fail now", "TRACE: <id>: <test name>", "T003 tests:", "Do not push"] {
            XCTAssertTrue(p.contains(expected), expected)
        }
        XCTAssertFalse(p.contains("HIDDEN:"))
        XCTAssertTrue(TestFirst.testerPrompt(task: task, criteria: criteria, invariants: [], constitution: nil, hidden: true).contains("HIDDEN: <path>"))
        XCTAssertTrue(TestFirst.testerPrompt(task: task, criteria: [], invariants: [], constitution: nil, hidden: false).contains("does not number its requirements"))
    }

    func testImplementerNoteLocksTheTestsAndShowsTheWayOut() {
        let n = TestFirst.implementerNote(files: ["Tests/GatewayTests.swift"], hiddenCount: 1)
        for expected in ["`Tests/GatewayTests.swift`", "locked", "Do not edit, delete, rename, skip or weaken", "TEST_DISPUTE:", "held back"] { XCTAssertTrue(n.contains(expected), expected) }
        XCTAssertFalse(TestFirst.implementerNote(files: ["a"], hiddenCount: 0).contains("held back"))
    }

    // MARK: Reading the tester

    func testTraceLinesAreParsedWhateverTheFormatting() {
        let report = """
        Done. I wrote the tests.
        TRACE: A2: testPathStaysOnOrigin, testBackslashPath
        - **TRACE: R2:** `GatewayTests.testNeverLeaves()`, GatewayTests/testRedirect
        trace: i1: testInvariantOrigin.
        TRACE: A9:
        TRACE nothing here
        """
        let t = TestFirst.parseTrace(report)
        XCTAssertEqual(t["A2"], ["testPathStaysOnOrigin", "testBackslashPath"])
        XCTAssertEqual(t["R2"], ["GatewayTests.testNeverLeaves()", "GatewayTests/testRedirect"])
        XCTAssertEqual(t["I1"], ["testInvariantOrigin"])
        XCTAssertNil(t["A9"]); XCTAssertEqual(t.count, 3)
        XCTAssertEqual(TestFirst.parseHidden("done\nHIDDEN: Tests/A.swift, `Tests/B.swift`"), ["Tests/A.swift", "Tests/B.swift"]); XCTAssertEqual(TestFirst.parseHidden("nothing"), [])
    }

    func testProblemsFindGapsFakeTestsAndNonTestFiles() {
        let files = ["Tests/GatewayTests.swift": "func testPathStaysOnOrigin() {}\nfunc testNeverLeaves() {}"]
        XCTAssertEqual(TestFirst.problems(required: ["R2", "A2"], trace: ["R2": ["GatewayTests.testNeverLeaves()"], "A2": ["testPathStaysOnOrigin"]], files: files), [])
        let gap = TestFirst.problems(required: ["R2", "A2", "I1"], trace: ["R2": ["testNeverLeaves"]], files: files)
        XCTAssertEqual(gap.count, 1); XCTAssertTrue(gap[0].contains("A2, I1"))
        let fake = TestFirst.problems(required: ["A2"], trace: ["A2": ["testThatDoesNotExist"]], files: files)
        XCTAssertTrue(fake[0].contains("testThatDoesNotExist"))
        let code = TestFirst.problems(required: ["A2"], trace: ["A2": ["testPathStaysOnOrigin"]], files: files.merging(["Sources/Gateway.swift": "func resolve() {}"]) { a, _ in a })
        XCTAssertTrue(code[0].contains("Only test files may change")); XCTAssertTrue(code[0].contains("Sources/Gateway.swift"))
        XCTAssertTrue(TestFirst.problems(required: [], trace: [:], files: [:]).contains("No test file was committed."))
    }

    // MARK: Red

    func check(_ output: String, ok: Bool = false) -> [GateCheck] { [GateCheck(command: "swift test", ok: ok, output: output)] }

    func testRedMeansTheTestsFailForTheRightReason() {
        XCTAssertEqual(TestFirst.red(check("", ok: true)), .green)
        XCTAssertEqual(TestFirst.red([]), .unclear("No verification command is set for this repository, so there is nothing to run the tests with."))
        // missing code is what a test written first looks like in a compiled language
        for out in ["error: cannot find 'resolveUpstream' in scope", "ModuleNotFoundError: No module named 'gateway'", "ReferenceError: resolveUpstream is not defined",
                    "./gateway_test.go:12:9: undefined: ResolveUpstream", "error[E0425]: cannot find function `resolve` in this scope"] {
            guard case .red(let why) = TestFirst.red(check(out)) else { return XCTFail(out) }
            XCTAssertTrue(why.contains("does not exist"), out)
        }
        guard case .red(let why) = TestFirst.red(check("Test Case 'GatewayTests.testNeverLeaves' failed: XCTAssertEqual failed: (\"https://evil.example\") is not equal to (\"https://app.example\")")) else { return XCTFail("assertion") }
        XCTAssertEqual(why, "assertions fail")
        guard case .red = TestFirst.red(check("--- FAIL: TestNeverLeaves (0.00s)\n    gateway_test.go:20: expected app.example got evil.example")) else { return XCTFail("go") }
    }

    func testBrokenTestsAreNotRed() {
        for out in ["Tests/GatewayTests.swift:3:1: error: expected declaration", "SyntaxError: Unexpected token '}'", "bash: swift: command not found", "sh: ./run-tests: Permission denied", "the build failed for some reason"] {
            guard case .unclear = TestFirst.red(check(out)) else { return XCTFail(out) }
        }
    }

    // MARK: Disputes

    func testDisputeAndRulingAreReadFromTheEndOfAMessage() {
        let msg = "I could not make it pass.\nTEST_DISPUTE: testBackslashPath: the spec only requires // paths; a backslash is a valid file name here."
        XCTAssertEqual(TestFirst.parseDispute(msg), "testBackslashPath: the spec only requires // paths; a backslash is a valid file name here.")
        XCTAssertNil(TestFirst.parseDispute("all done")); XCTAssertNil(TestFirst.parseDispute("TEST_DISPUTE: nah"))          // too thin to act on
        XCTAssertEqual(TestFirst.parseRuling("Looked.\nDISPUTE: UPHELD, because R2 says every path"), .upheld("R2 says every path"))
        XCTAssertEqual(TestFirst.parseRuling("**DISPUTE: AMENDED, because the test assumed a trailing slash**"), .amended("the test assumed a trailing slash"))
        XCTAssertNil(TestFirst.parseRuling("no ruling here"))
        XCTAssertTrue(TestFirst.disputePrompt(task: task, dispute: "testX: wrong").contains("DISPUTE: UPHELD"))
    }
}

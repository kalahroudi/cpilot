// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class TaskBudgetTests: XCTestCase {
    private let budget = TaskBudget(dollars: 10, turns: 40, minutes: 60)

    func testEachLimitStopsATask() {
        XCTAssertNil(budget.exceeded(used: TaskUsage(cost: 9.99, turns: 39, seconds: 3599)))
        XCTAssertTrue(budget.exceeded(used: TaskUsage(cost: 10, turns: 1, seconds: 1))!.contains("$10"))
        XCTAssertTrue(budget.exceeded(used: TaskUsage(cost: 1, turns: 40, seconds: 1))!.contains("40 turns"))
        XCTAssertTrue(budget.exceeded(used: TaskUsage(cost: 1, turns: 1, seconds: 3600))!.contains("60 minutes"))
    }

    func testZeroIsOffAndAnAgentThatReportsNoCostIsStillLimited() {
        XCTAssertNil(TaskBudget(dollars: 0, turns: 0, minutes: 0).exceeded(used: TaskUsage(cost: 999, turns: 999, seconds: 99_999)))
        XCTAssertNotNil(TaskBudget(dollars: 10, turns: 5, minutes: 0).exceeded(used: TaskUsage(cost: 0, turns: 5, seconds: 0)))
    }

    func testTheCountStartsAgainWhereTheUserSteppedIn() {
        let base = TaskUsage(cost: 10, turns: 40, seconds: 3600)
        XCTAssertNil(budget.exceeded(used: TaskUsage(cost: 12, turns: 45, seconds: 3900), since: base))
        XCTAssertNotNil(budget.exceeded(used: TaskUsage(cost: 20, turns: 45, seconds: 3900), since: base))
    }

    func testUsageIsAddedUpPerSession() {
        let l = Ledger(url: nil)
        l.add(LedgerEntry(session: "a", title: "t", repo: "/r", source: "task", cost: 1.5, seconds: 60))
        l.add(LedgerEntry(session: "a", title: "t", repo: "/r", source: "task", cost: 0.5, seconds: 30))
        l.add(LedgerEntry(session: "b", title: "t", repo: "/r", source: "task", cost: 9, seconds: 600))
        XCTAssertEqual(l.usage(session: "a"), TaskUsage(cost: 2, turns: 2, seconds: 90))
        XCTAssertEqual(l.usage(session: "none"), TaskUsage())
    }

    func testOldGateRecordsLoadWithoutABase() throws {
        let old = #"{"state":{"runs":1,"failures":[]},"answering":false,"updated":"2026-01-01T00:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertNil(try dec.decode(GateRecord.self, from: Data(old.utf8)).budgetBase)
    }
}

final class CriteriaTests: XCTestCase {
    private let spec = """
    # Cursor pagination
    ## Requirements
    - R1 The list endpoint returns a `next_cursor` when more results exist.
    - R2: A bad cursor returns 400.
    - **R3** Page size is capped at 100.
    ## Acceptance checks
    - A1 (R1) Request 3 pages of a 250-item list and see the cursor chain end with null.
    - A2 (R2, R3) Send `cursor=zzz` and `limit=500`.
    ## Out of scope
    - R9 is not here
    """

    func testReadsTheRequirementsATaskCoversWithTheirChecks() {
        let c = Specs.criteria(spec: spec, covers: ["R1", "R3"])
        XCTAssertEqual(c.map(\.id), ["R1", "R3"])
        XCTAssertEqual(c[0].text, "The list endpoint returns a `next_cursor` when more results exist.")
        XCTAssertEqual(c[0].checks.count, 1)
        XCTAssertEqual(c[1].text, "Page size is capped at 100.")
        XCTAssertTrue(c[1].checks[0].contains("limit=500"))
    }

    func testAnUnnumberedSpecGivesNothing() {
        XCTAssertTrue(Specs.criteria(spec: "# x\n- it works", covers: ["R1"]).isEmpty)
        XCTAssertTrue(Specs.criteria(spec: spec, covers: []).isEmpty)
        XCTAssertTrue(Specs.criteria(spec: spec, covers: ["R7"]).isEmpty)
    }

    func testTheReviewerIsAskedForOneLinePerRequirement() {
        let p = ChiefPilot.reviewPrompt(number: 7, title: "t", head: "h", base: "main", criteria: Specs.criteria(spec: spec, covers: ["R2"]))
        XCTAssertTrue(p.contains("- R2: A bad cursor returns 400."))
        XCTAssertTrue(p.contains("check: A2 (R2, R3)"))
        XCTAssertTrue(p.contains("one line per requirement"))
        XCTAssertFalse(ChiefPilot.reviewPrompt(number: 7, title: "t", head: "h", base: "main").contains("requirements of its spec"))
    }

    func testAVerdictThatSkipsARequirementIsCaught() {
        let report = "R1: met, in A.swift\nR3: NOT met, no cap\nVERDICT: OPEN\n- R3 is not capped"
        XCTAssertEqual(ReviewVerdict.unaddressed(report: report, ids: ["R1", "R2", "R3"]), ["R2"])
        XCTAssertEqual(ReviewVerdict.unaddressed(report: "R10: met", ids: ["R1"]), ["R1"], "R10 is not R1")
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class GuardrailsTests: XCTestCase {
    func testSourceFromWhatIsKnownAboutASession() {
        func meta(_ branch: String?, chief: Bool? = nil, review: Int? = nil) -> SessionMeta {
            var m = SessionMeta(title: "t", cwd: "/r", branch: branch); m.chief = chief; m.reviewOf = review; return m
        }
        XCTAssertEqual(Guardrails.source(of: meta(nil, chief: true)), "chief")
        XCTAssertEqual(Guardrails.source(of: meta("feature", review: 4)), "reviewer")
        XCTAssertEqual(Guardrails.source(of: meta("trigger/nightly-ab12")), "trigger")
        XCTAssertEqual(Guardrails.source(of: meta("phone/fix-1")), "phone")
        XCTAssertEqual(Guardrails.source(of: meta("spec-001-t1")), "task")
        XCTAssertEqual(Guardrails.source(of: meta("mine")), "you")
    }

    func testHoldsAtTheLimitAndWhenTheBudgetIsSpent() {
        XCTAssertNil(Guardrails.hold(running: 3, limit: 4, spentToday: 1, budget: 5))
        XCTAssertNotNil(Guardrails.hold(running: 4, limit: 4, spentToday: 1, budget: 5))
        XCTAssertTrue(Guardrails.hold(running: 1, limit: 4, spentToday: 5, budget: 5)?.contains("budget") ?? false)
        XCTAssertNil(Guardrails.hold(running: 99, limit: 0, spentToday: 999, budget: 0), "0 means no limit")
        // The budget is said first: waiting for an agent to finish would not help.
        XCTAssertTrue(Guardrails.hold(running: 9, limit: 4, spentToday: 9, budget: 5)?.contains("budget") ?? false)
    }

    func testSlots() {
        XCTAssertEqual(Guardrails.slots(running: 1, limit: 3), 2)
        XCTAssertEqual(Guardrails.slots(running: 5, limit: 3), 0)
        XCTAssertGreaterThan(Guardrails.slots(running: 5, limit: 0), 1000)
    }

    func testLedgerAddsUpPerSourceAndForgetsOldRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        let l = Ledger(url: url)
        let now = Date()
        l.add(.init(date: now - 40 * 86_400, session: "a", title: "old", repo: "/r", source: "you", cost: 9, seconds: 1))
        l.add(.init(date: now - 3600, session: "b", title: "x", repo: "/r", source: "trigger", cost: 0.5, seconds: 60))
        l.add(.init(date: now, session: "c", title: "y", repo: "/r", source: "trigger", cost: 0.25, seconds: 30))
        l.add(.init(date: now, session: "d", title: "z", repo: "/r", source: "chief", cost: 1, seconds: 10))
        XCTAssertEqual(l.entries(since: .distantPast).count, 3, "a row older than a month is dropped")
        XCTAssertEqual(l.spent(since: now - 1800), 1.25, accuracy: 0.0001)
        let t = l.totals(since: now - 7200)
        XCTAssertEqual(t.map(\.source), ["chief", "trigger"])
        XCTAssertEqual(t[1].turns, 2); XCTAssertEqual(t[1].seconds, 90)
        XCTAssertEqual(Ledger(url: url).entries(since: .distantPast).count, 3, "survives a restart")
    }
}

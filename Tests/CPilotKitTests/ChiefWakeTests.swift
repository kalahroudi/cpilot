// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ChiefWakeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStatusParse() {
        XCTAssertEqual(ChiefStatus.parse("All merged.\nSTATUS: DONE"), .done)
        XCTAssertEqual(ChiefStatus.parse("x\n**STATUS: WAITING** for checks on #12"), .waiting("for checks on #12"))
        XCTAssertEqual(ChiefStatus.parse("status: blocked need the API key"), .blocked("need the API key"))
        XCTAssertNil(ChiefStatus.parse("I will continue later."))
        XCTAssertEqual(ChiefStatus.parse("STATUS: WAITING a\nSTATUS: DONE"), .done)
    }

    func testLooksKeepComingUntilTheLimit() {
        var s = WakeState(now: t0)
        var now = t0, wakes = 0, last = ChiefWake.decide(&s, WakeInputs(), now: now)
        XCTAssertEqual(last, .wait)
        for _ in 0..<2000 where s.expecting {
            now += 15
            last = ChiefWake.decide(&s, WakeInputs(), now: now)
            if case .wake(let finished) = last { XCTAssertFalse(finished); wakes += 1 }
        }
        XCTAssertEqual(wakes, ChiefWake.maxLooks)
        XCTAssertEqual(last, .stalled)
        XCTAssertFalse(s.expecting)
    }

    func testLooksBackOffToTenMinutes() {
        XCTAssertEqual(ChiefWake.lookEvery(after: 0), 180)
        XCTAssertEqual(ChiefWake.lookEvery(after: 1), 360)
        XCTAssertEqual(ChiefWake.lookEvery(after: 11), 600)
    }

    func testFinishedWorkWakesAtOnceEvenIfItEndedBetweenTicks() {
        var s = WakeState(now: t0)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(workInFlight: true), now: t0 + 15), .wait)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(), now: t0 + 30), .wake(finished: true))
        XCTAssertTrue(s.expecting, "it keeps looking until the chief pilot says it is done")
        XCTAssertFalse(s.sawFinish)
    }

    func testNeverWakesABusyOrInterruptedChief() {
        for i in [WakeInputs(chiefBusy: true), WakeInputs(hasPending: true), WakeInputs(hasAttachments: true), WakeInputs(quietFor: 3)] {
            var s = WakeState(now: t0); s.sawFinish = true
            XCTAssertEqual(ChiefWake.decide(&s, i, now: t0 + 9999), .wait)
        }
    }

    func testDoneAndBlockedStopTheWaking() {
        var s = WakeState(now: t0)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(status: .done), now: t0 + 9999), .finish)
        XCTAssertFalse(s.expecting)
        s = WakeState(now: t0)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(status: .blocked("a key")), now: t0 + 9999), .blocked("a key"))
        XCTAssertFalse(s.expecting)
        s = WakeState(now: t0)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(status: .waiting("checks")), now: t0 + 9999), .wake(finished: false))
    }

    func testAHoldIsAnnouncedOnceThenWakesWhenItLifts() {
        var s = WakeState(now: t0); s.sawFinish = true
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(hold: "budget"), now: t0 + 100), .held("budget"))
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(hold: "budget"), now: t0 + 200), .wait)
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(), now: t0 + 300), .wake(finished: true))
        XCTAssertFalse(s.holdAnnounced)
    }

    func testStartingSomethingRestartsTheClock() {
        var s = WakeState(now: t0); s.looks = 9; s.expecting = false
        ChiefWake.started(&s, now: t0 + 500)
        XCTAssertTrue(s.expecting); XCTAssertEqual(s.looks, 0); XCTAssertEqual(s.lastWake, t0 + 500)
    }

    func testStoreSurvivesARestartAndDropsOldEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = WakeStore(url: url)
        a.set(WakeState(now: .now), for: "/r/new")
        a.set(WakeState(now: .now.addingTimeInterval(-10 * 86_400)), for: "/r/old")
        let b = WakeStore(url: url)
        XCTAssertEqual(Set(b.all().keys), ["/r/new"])
    }

    func testGuidanceAsksForAStatusLine() {
        XCTAssertTrue(ChiefPilot.guidance(repo: "/r").contains("STATUS: DONE"))
        XCTAssertTrue(ChiefWake.message(finished: false).contains("STATUS: WAITING"))
    }

    /// The chase in the screenshot: every failed turn counted as work finishing, so the chief was woken again and again against a limit that was already hit.
    func testAUsageLimitHoldsTheChiefQuietThroughManyFinishesAndItWakesOnceAfter() {
        var s = WakeState(now: t0)
        s.expecting = true
        let limit = "Claude's usage limit is reached. Work that starts by itself carries on at 2:01 AM."
        var now = t0 + 600, announced = 0, wakes = 0
        for _ in 0..<40 {                                   // every tick, a session ends a (failed) turn
            now += 60; s.sawFinish = true
            switch ChiefWake.decide(&s, WakeInputs(quietFor: 600, hold: limit), now: now) {
            case .held: announced += 1
            case .wake: wakes += 1
            default: break
            }
        }
        XCTAssertEqual(announced, 1); XCTAssertEqual(wakes, 0)             // said once, never asked again
        XCTAssertTrue(s.expecting && s.sawFinish)                          // and it still knows work finished while it waited
        // the limit lifts: it looks at where things stand, once, straight away
        now += 60
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(quietFor: 600), now: now), .wake(finished: true))
        XCTAssertEqual(ChiefWake.decide(&s, WakeInputs(quietFor: 600), now: now + 1), .wait)
    }
}

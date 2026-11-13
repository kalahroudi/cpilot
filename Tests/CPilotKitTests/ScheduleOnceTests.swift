// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ScheduleOnceTests: XCTestCase {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }()

    func testAOneOffRunsOnceWhenItsMomentComes() {
        let s = Schedule(frequency: .once, at: at("2026-11-13T02:05:00Z"))
        let made = at("2026-11-12T23:30:00Z")
        XCTAssertFalse(s.isDue(lastRun: nil, createdAt: made, now: at("2026-11-13T02:04:59Z"), calendar: cal))
        XCTAssertTrue(s.isDue(lastRun: nil, createdAt: made, now: at("2026-11-13T02:05:00Z"), calendar: cal))
        // a Mac that was off at the time runs it when it is next on, however late
        XCTAssertTrue(s.isDue(lastRun: nil, createdAt: made, now: at("2026-11-14T09:00:00Z"), calendar: cal))
        // and never again once it has run
        XCTAssertFalse(s.isDue(lastRun: at("2026-11-13T02:05:30Z"), createdAt: made, now: at("2026-11-20T09:00:00Z"), calendar: cal))
        // one with no moment never runs
        XCTAssertFalse(Schedule(frequency: .once).isDue(lastRun: nil, createdAt: made, now: at("2027-01-01T00:00:00Z"), calendar: cal))
        XCTAssertEqual(s.next(after: made, calendar: cal), at("2026-11-13T02:05:00Z"))
    }

    func testTheOtherFrequenciesAreAsTheyWere() {
        let daily = Schedule(frequency: .daily, hour: 9, minute: 0)
        let created = at("2026-11-12T08:00:00Z")
        XCTAssertTrue(daily.isDue(lastRun: nil, createdAt: created, now: at("2026-11-12T09:30:00Z"), calendar: cal))
        XCTAssertFalse(daily.isDue(lastRun: at("2026-11-12T09:01:00Z"), createdAt: created, now: at("2026-11-12T23:00:00Z"), calendar: cal))
    }

    func testOldFilesWithoutTheNewFieldsStillLoadAndNewOnesRoundTrip() throws {
        let old = #"{"id":"a","name":"Nightly","repo":"/r","kind":"schedule","action":"session","enabled":true,"prompt":"do it","label":"cpilot","schedule":{"frequency":"daily","everyHours":6,"hour":9,"minute":0,"weekday":2},"createdAt":0}"#
        let t = try JSONDecoder().decode(Trigger.self, from: Data(old.utf8))
        XCTAssertNil(t.sessionId); XCTAssertNil(t.schedule.at); XCTAssertFalse(t.isFinishedOneOff)
        let once = Trigger(name: "Carry on", repo: "/r", kind: .schedule, action: .session, prompt: "Continue.", schedule: Schedule(frequency: .once, at: at("2026-11-13T02:05:00Z")), sessionId: "abc")
        let back = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(once))
        XCTAssertEqual(back, once); XCTAssertEqual(back.sessionId, "abc")
    }

    func testAOneOffNeedsAMomentAndIsMarkedDoneAfterItRuns() {
        var t = Trigger(name: "Carry on", repo: "/r", kind: .schedule, action: .session, prompt: "Continue.", schedule: Schedule(frequency: .once))
        XCTAssertEqual(t.problem, "Choose when it should run.")
        t.schedule.at = at("2026-11-13T02:05:00Z"); XCTAssertNil(t.problem); XCTAssertFalse(t.isFinishedOneOff)
        t.lastRun = at("2026-11-13T02:06:00Z"); XCTAssertTrue(t.isFinishedOneOff)
        t.schedule.frequency = .daily; XCTAssertFalse(t.isFinishedOneOff)           // a recurring one is never "finished"
    }

    func testWordsForTheList() {
        let s = Schedule(frequency: .once, at: at("2026-11-13T02:05:00Z"))
        XCTAssertTrue(s.summary().hasPrefix("Once, ")); XCTAssertEqual(Schedule(frequency: .once).summary(), "Once")
        let toSession = Trigger(name: "x", repo: "/r", kind: .schedule, action: .session, prompt: "p", schedule: s, sessionId: "abc")
        XCTAssertTrue(toSession.summary().hasSuffix("a message to a session"))
        XCTAssertTrue(TriggerPolicy.scheduledPrompt(toSession).hasPrefix("CPilot (scheduled for "))
        XCTAssertTrue(TriggerPolicy.scheduledPrompt(toSession).hasSuffix(": p"))
        var task = toSession; task.sessionId = nil
        XCTAssertTrue(TriggerPolicy.scheduledPrompt(task).hasPrefix("This is a scheduled task"))
    }
}

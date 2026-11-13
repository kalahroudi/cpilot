// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class UsageLimitTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    func at(_ s: String, _ tz: TimeZone? = nil) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = tz ?? london; f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f.date(from: s)!
    }
    func hit(_ text: String, now: String, tz: TimeZone? = nil) -> UsageLimit.Hit? { UsageLimit.detect(text, now: at(now), timeZone: tz ?? london) }

    func testTheExactMessageFromTheScreenshot() throws {
        // 23:24 on 12 November in London: the next 2am is on the 13th
        let h = try XCTUnwrap(hit("You've hit your session limit · resets 2am (Europe/London)", now: "2026-11-12T23:24:00Z"))
        XCTAssertEqual(h.resets, at("2026-11-13T02:00:00Z")); XCTAssertFalse(h.weekly)
        XCTAssertEqual(h.resumeAt(now: at("2026-11-12T23:24:00Z")), at("2026-11-13T02:01:00Z"))          // a minute after, so the reset has happened
        // before 2am the same night: that very 2am
        XCTAssertEqual(hit("You've hit your session limit · resets 2am (Europe/London)", now: "2026-11-13T01:10:00Z")?.resets, at("2026-11-13T02:00:00Z"))
        // after it has passed: tomorrow's
        XCTAssertEqual(hit("You've hit your session limit · resets 2am (Europe/London)", now: "2026-11-13T02:30:00Z")?.resets, at("2026-11-14T02:00:00Z"))
    }

    func testTheTimeZoneInTheMessageIsTheOneThatCounts() {
        // the Mac is in London but the message names New York: 2am there is 07:00 in London in November
        let h = hit("You've hit your session limit · resets 2am (America/New_York)", now: "2026-11-12T23:24:00Z")
        XCTAssertEqual(h?.resets, at("2026-11-13T07:00:00Z"))
        XCTAssertEqual(hit("You've hit your limit · resets 3pm (UTC)", now: "2026-11-12T10:00:00Z")?.resets, at("2026-11-12T15:00:00Z"))
        // no zone given: the Mac's
        XCTAssertEqual(hit("You've hit your limit · resets 3pm", now: "2026-11-12T10:00:00Z")?.resets, at("2026-11-12T15:00:00Z"))
    }

    func testOtherWaysOfWritingTheTime() {
        let now = "2026-11-12T10:00:00Z"
        XCTAssertEqual(hit("You've hit your session limit · resets 2:30pm (Europe/London)", now: now)?.resets, at("2026-11-12T14:30:00Z"))
        XCTAssertEqual(hit("You've hit your session limit · resets 12am (Europe/London)", now: now)?.resets, at("2026-11-13T00:00:00Z"))
        XCTAssertEqual(hit("You've hit your session limit · resets 12pm (Europe/London)", now: now)?.resets, at("2026-11-12T12:00:00Z"))
        XCTAssertEqual(hit("5-hour limit reached ∙ resets 14:00", now: now)?.resets, at("2026-11-12T14:00:00Z"))
        XCTAssertEqual(hit("You've hit your session limit. Your limit will reset at 4 PM (Europe/London).", now: now)?.resets, at("2026-11-12T16:00:00Z"))
        XCTAssertEqual(hit("You've hit your session limit · resets tomorrow at 9am (Europe/London)", now: now)?.resets, at("2026-11-13T09:00:00Z"))
    }

    func testWeeklyLimitsWithADateOrAWeekday() throws {
        let w = try XCTUnwrap(hit("You've hit your weekly limit · resets Nov 17, 9am (Europe/London)", now: "2026-11-12T10:00:00Z"))
        XCTAssertEqual(w.resets, at("2026-11-17T09:00:00Z")); XCTAssertTrue(w.weekly)
        XCTAssertEqual(hit("You've hit your weekly limit · resets 17 Nov at 9am (Europe/London)", now: "2026-11-12T10:00:00Z")?.resets, at("2026-11-17T09:00:00Z"))
        // 12 Nov 2026 is a Thursday: Monday is the 16th, and "Thu" at a time already passed is next week
        XCTAssertEqual(hit("You've hit your weekly limit · resets Mon 9am (Europe/London)", now: "2026-11-12T10:00:00Z")?.resets, at("2026-11-16T09:00:00Z"))
        XCTAssertEqual(hit("You've hit your weekly limit · resets Thu 9am (Europe/London)", now: "2026-11-12T10:00:00Z")?.resets, at("2026-11-19T09:00:00Z"))
        XCTAssertEqual(hit("You've hit your weekly limit · resets Dec 2, 9am (Europe/London)", now: "2026-11-12T10:00:00Z")?.resets, at("2026-12-02T09:00:00Z"))
        XCTAssertEqual(hit("You've hit your weekly limit · resets Jan 3, 9am (Europe/London)", now: "2026-12-30T10:00:00Z")?.resets, at("2027-01-03T09:00:00Z"))     // across the new year
    }

    func testTheOlderEpochForm() throws {
        let h = try XCTUnwrap(UsageLimit.detect("Claude AI usage limit reached|1794536400", now: at("2026-11-12T20:00:00Z")))
        XCTAssertEqual(h.resets, Date(timeIntervalSince1970: 1794536400))
    }

    func testALimitWithNoTimeIsWaitedOutForHalfAnHour() throws {
        let now = at("2026-11-12T10:00:00Z")
        let h = try XCTUnwrap(UsageLimit.detect("You've hit your usage limit.", now: now, timeZone: london))
        XCTAssertNil(h.resets); XCTAssertEqual(h.resumeAt(now: now), now.addingTimeInterval(1800))
        // a reset that is already past (the Mac's clock is off) is not "now": it waits at least two minutes
        let past = UsageLimit.Hit(message: "x", resets: now.addingTimeInterval(-3600), weekly: false)
        XCTAssertEqual(past.resumeAt(now: now), now.addingTimeInterval(120))
    }

    func testOnlyTheLimitMessageCountsNotTalkAboutLimits() {
        for text in ["", "The build failed.", "I added rate limiting to the login route, with a limit of 5 attempts.", "Error: 429 too many requests",
                     "You should check whether you've hit your limit before sending many requests, since it resets at 2am (Europe/London) according to the docs. " + String(repeating: "More words. ", count: 40),
                     "The usage limit reached state is tested in UsageTests."] {
            XCTAssertNil(UsageLimit.detect(text), text)
        }
        XCTAssertNotNil(UsageLimit.detect("You've hit your Opus limit · resets 5pm (Europe/London)"))
    }

    /// How the limit really arrives: an error result whose text is Claude's message. The detector must recognise what the stream parser hands over.
    func testTheStreamsErrorResultCarriesTheLimitToTheDetector() throws {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 2am (Europe/London)","total_cost_usd":0}"#
        var parser = ClaudeStreamParser()
        guard case .turnEnded(let isError, let text, _)? = parser.parse(line: line).first else { return XCTFail("not a finished turn") }
        XCTAssertTrue(isError)
        let h = try XCTUnwrap(UsageLimit.detect(try XCTUnwrap(text), now: at("2026-11-12T23:24:00Z"), timeZone: london))
        XCTAssertEqual(h.resets, at("2026-11-13T02:00:00Z"))
        // an ordinary failed turn is not a limit
        guard case .turnEnded(_, let other, _)? = parser.parse(line: #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached the maximum number of turns."}"#).first else { return XCTFail() }
        XCTAssertNil(UsageLimit.detect(try XCTUnwrap(other)))
    }
}

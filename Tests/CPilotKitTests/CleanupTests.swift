// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class CleanupTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private func decide(_ f: CleanupPolicy.Facts, keep: Int = 30) -> CleanupPolicy.Action { CleanupPolicy.decide(f, keepArchivedDays: keep) }
    private func keeps(_ a: CleanupPolicy.Action, _ words: String) -> Bool { if case .keep(let why) = a { why.contains(words) } else { false } }

    func testYourOwnSessionsAreNeverTouched() {
        XCTAssertTrue(keeps(decide(.init(automatic: false, pr: .merged, idle: 99 * day)), "you"))
        XCTAssertTrue(keeps(decide(.init(automatic: false, archived: true, hasWorktree: false, idle: 999 * day, archivedFor: 999 * day)), "you"))
    }

    func testADeliveredTaskReleasesItsCheckoutAndIsPutAway() {
        XCTAssertEqual(decide(.init(automatic: true, pr: .merged, idle: 2 * 3600)), .finish(release: true))
        XCTAssertEqual(decide(.init(automatic: true, pr: .closed, idle: 2 * 3600)), .finish(release: true))
    }

    func testASessionWhoseCheckoutIsAlreadyGoneIsJustPutAway() {
        XCTAssertEqual(decide(.init(automatic: true, hasWorktree: false, pr: .merged, idle: day)), .finish(release: false))
    }

    func testBusyAndRecentlyUsedAreLeftAlone() {
        XCTAssertTrue(keeps(decide(.init(automatic: true, busy: true, pr: .merged, idle: 9 * day)), "working"))
        XCTAssertTrue(keeps(decide(.init(automatic: true, pr: .merged, idle: 600)), "last hour"))
    }

    func testAnOpenPullRequestKeepsItsSessions() {
        XCTAssertTrue(keeps(decide(.init(automatic: true, pr: .open, idle: 90 * day)), "open"))
    }

    func testWorkThatExistsNowhereElseIsNeverRemoved() {
        XCTAssertTrue(keeps(decide(.init(automatic: true, uncommitted: 2, pr: .merged, idle: day)), "not committed"))
        XCTAssertTrue(keeps(decide(.init(automatic: true, onRemote: false, pr: .closed, idle: day)), "no remote"))
        // The same facts with the checkout already gone are nothing to protect.
        XCTAssertEqual(decide(.init(automatic: true, hasWorktree: false, uncommitted: 2, onRemote: false, pr: .merged, idle: day)), .finish(release: false))
    }

    func testNoPullRequestMeansAbandonedOnlyAfterTwoWeeks() {
        XCTAssertTrue(keeps(decide(.init(automatic: true, pr: .none, idle: 13 * day)), "no pull request"))
        XCTAssertEqual(decide(.init(automatic: true, pr: .none, idle: 15 * day)), .finish(release: true))
        XCTAssertTrue(keeps(decide(.init(automatic: true, uncommitted: 1, pr: .none, idle: 40 * day)), "not committed"))
    }

    func testPutAwaySessionsAreDeletedAfterTheRetention() {
        let a = CleanupPolicy.Facts(automatic: true, archived: true, hasWorktree: false, pr: .merged, idle: 100 * day, archivedFor: 29 * day)
        XCTAssertTrue(keeps(decide(a), "30 days"))
        var b = a; b.archivedFor = 31 * day
        XCTAssertEqual(decide(b), .delete)
        var c = a; c.archivedFor = nil; c.idle = 31 * day
        XCTAssertEqual(decide(c), .delete, "without an archive date the last use stands in")
        XCTAssertTrue(keeps(decide(b, keep: 0), "for ever"))
    }

    func testAPutAwaySessionThatStillHasACheckoutIsReleasedFirst() {
        XCTAssertEqual(decide(.init(automatic: true, archived: true, hasWorktree: true, pr: .merged, idle: 100 * day, archivedFor: 100 * day)), .finish(release: true))
    }

    func testOrphanFolders() {
        let now = Date()
        let list = [("owned", now.addingTimeInterval(-30 * day)), ("old-orphan", now.addingTimeInterval(-8 * day)), ("new-orphan", now.addingTimeInterval(-1 * day))]
        XCTAssertEqual(CleanupPolicy.orphans(entries: list, owned: ["owned"], now: now), ["old-orphan"])
    }

    func testWhichSessionsAreAutomatic() {
        func meta(_ branch: String?, chief: Bool? = nil, review: Int? = nil) -> SessionMeta { var m = SessionMeta(title: "t", cwd: "/r", branch: branch); m.chief = chief; m.reviewOf = review; return m }
        XCTAssertTrue(CleanupPolicy.isAutomatic(meta("spec-001-t1")))
        XCTAssertTrue(CleanupPolicy.isAutomatic(meta("x", review: 4)))
        XCTAssertTrue(CleanupPolicy.isAutomatic(meta("trigger/nightly")))
        XCTAssertTrue(CleanupPolicy.isAutomatic(meta("collapse-spec-001-t102-combined")))
        XCTAssertFalse(CleanupPolicy.isAutomatic(meta(nil, chief: true)))
        XCTAssertFalse(CleanupPolicy.isAutomatic(meta("my-feature")))
        XCTAssertFalse(CleanupPolicy.isAutomatic(meta("phone/x")))
    }
}

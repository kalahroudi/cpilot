// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class CIWatchTests: XCTestCase {
    typealias Item = CIPullRequest.Item
    private func pr(_ oid: String, _ items: [Item]?) -> CIPullRequest { CIPullRequest(number: 5, title: "T", url: "u/5", headRefOid: oid, statusCheckRollup: items) }
    private let running = [Item(name: "build", status: "IN_PROGRESS"), Item(name: "lint", status: "COMPLETED", conclusion: "SUCCESS")]
    private let green = [Item(name: "build", status: "COMPLETED", conclusion: "SUCCESS"), Item(context: "ci/x", state: "SUCCESS")]
    private let red = [Item(name: "build", status: "COMPLETED", conclusion: "FAILURE"), Item(name: "lint", status: "COMPLETED", conclusion: "SUCCESS")]

    func testVerdicts() {
        XCTAssertEqual(CIVerdict.of(nil), .none)
        XCTAssertEqual(CIVerdict.of(running), .pending)
        XCTAssertEqual(CIVerdict.of(green), .passed)
        XCTAssertEqual(CIVerdict.of(red), .failed(["build"]))
        XCTAssertEqual(CIVerdict.of(running + red), .failed(["build"]))   // a failure is news while the rest still run
        XCTAssertEqual(CIVerdict.of([Item(context: "ci", state: "PENDING")]), .pending)
    }

    func testAnnouncesOnceWhenRunningChecksFinish() {
        var w = CIWatch()
        XCTAssertTrue(w.observe([pr("a", green)]).isEmpty)               // first met finished: not news
        XCTAssertTrue(w.observe([pr("b", running)]).isEmpty)
        XCTAssertTrue(w.hasPending)
        XCTAssertEqual(w.observe([pr("b", green)]).map(\.verdict), [.passed])
        XCTAssertTrue(w.observe([pr("b", green)]).isEmpty)               // not again
        XCTAssertFalse(w.hasPending)
    }

    func testNewCommitFinishingBetweenLooksIsAnnounced() {
        var w = CIWatch()
        _ = w.observe([pr("a", green)])
        XCTAssertEqual(w.observe([pr("b", red)]).map(\.verdict), [.failed(["build"])])
    }

    func testClosedPullRequestIsForgotten() {
        var w = CIWatch()
        _ = w.observe([pr("a", running)])
        _ = w.observe([])
        XCTAssertTrue(w.observe([pr("a", green)]).isEmpty)
    }

    func testConflictIsAnnouncedOnceWhenItAppears() {
        var w = CIWatch()
        func conflicted(_ m: String) -> CIPullRequest { CIPullRequest(number: 5, title: "T", url: "u/5", headRefOid: "a", statusCheckRollup: green, mergeable: m) }
        XCTAssertTrue(w.observe([conflicted("MERGEABLE")]).isEmpty)
        XCTAssertEqual(w.observe([conflicted("CONFLICTING")]).map(\.conflict), [true])
        XCTAssertTrue(w.observe([conflicted("CONFLICTING")]).isEmpty)    // not again
        XCTAssertTrue(w.observe([conflicted("MERGEABLE")]).isEmpty)
        XCTAssertEqual(w.observe([conflicted("CONFLICTING")]).count, 1)  // a new conflict is news again
        _ = w.observe([conflicted("UNKNOWN")])
        XCTAssertTrue(w.hasPending)                                      // GitHub has not decided yet: keep looking
    }

    func testConflictNamesFromMergeTree() {
        XCTAssertEqual(Git.conflictedNames("abc123\na.swift\nb/c.swift\n\nAuto-merging a.swift\n"), ["a.swift", "b/c.swift"])
    }
}

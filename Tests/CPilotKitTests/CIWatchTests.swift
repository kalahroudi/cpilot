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
}

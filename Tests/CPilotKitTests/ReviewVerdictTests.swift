// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ReviewVerdictTests: XCTestCase {
    func testClean() {
        XCTAssertEqual(ReviewVerdict.parse("Fixed two things.\n\nVERDICT: CLEAN"), .clean)
        XCTAssertEqual(ReviewVerdict.parse("done\n**VERDICT: CLEAN**\n"), .clean)
        XCTAssertEqual(ReviewVerdict.parse("verdict: clean"), .clean)
    }

    func testOpenWithIssues() {
        let v = ReviewVerdict.parse("Report.\n\nVERDICT: OPEN\n- no test for the empty page\n- the limit is in bytes, not rows\n")
        XCTAssertEqual(v, .open(["no test for the empty page", "the limit is in bytes, not rows"]))
        XCTAssertEqual(v?.label, "open")
    }

    func testOpenWithoutAListIsStillOpen() {
        XCTAssertEqual(ReviewVerdict.parse("VERDICT: OPEN"), .open([]))
    }

    func testTheLastVerdictWins() {
        XCTAssertEqual(ReviewVerdict.parse("VERDICT: OPEN\n- a\n\nlater, after a fix:\nVERDICT: CLEAN"), .clean)
    }

    func testNoVerdictIsNil() {
        XCTAssertNil(ReviewVerdict.parse("Everything looks fine to me."))
        XCTAssertNil(ReviewVerdict.parse("The verdict was that this is clean."), "only a line that starts with the verdict counts")
    }

    func testTheReviewPromptAsksForIt() {
        XCTAssertTrue(ChiefPilot.reviewPrompt(number: 3, title: "t", head: "h", base: "main").contains("VERDICT: CLEAN"))
    }
}

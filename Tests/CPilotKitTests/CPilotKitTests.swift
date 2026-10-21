import XCTest
@testable import CPilotKit

final class KitTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("v1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("garbage", than: "1.0.0"))
    }

    func testIssueReportHasNoUserDetails() {
        let err = ShellError.failed(command: "gh pr create --title Secret title --body private", status: 1, stderr: "fail at \(NSHomeDirectory())/proj/x by me@example.com on 192.168.1.5 token=abc123 /Users/someone/else")
        let body = ErrorReport(err, action: "Create the pull request").issueBody(version: "1")
        for leak in [NSHomeDirectory(), NSUserName(), "Secret title", "private", "me@example.com", "192.168.1.5", "abc123", "/Users/someone"] {
            XCTAssertFalse(body.contains(leak), "leaked \(leak)")
        }
    }

    func testIssueReportHidesRepositoryNames() {
        let err = ShellError.failed(command: "gh pr review 4 --approve", status: 1, stderr: "GraphQL: Could not resolve to a Repository with the name 'acme-corp/secret-app'. See https://github.com/acme-corp/secret-app/pull/4")
        let body = ErrorReport(err, action: "Send the review").issueBody(version: "1")
        for leak in ["acme-corp", "secret-app"] { XCTAssertFalse(body.contains(leak), "leaked \(leak)") }
        XCTAssertTrue(body.contains("Send the review"))
    }

    func testOwnPullRequestApprovalHasPlainMessage() {
        let err = ShellError.failed(command: "gh pr review 4 --approve", status: 1, stderr: "failed to create review: GraphQL: Review Can not approve your own pull request (addPullRequestReview)\n")
        XCTAssertTrue(UserError.message(for: err, action: "Send the review").contains("approve your own pull request"))
    }

    func testScanResultsSurviveRestart() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scans-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clean = SecurityResult(findings: [], report: "# Report\n\nNothing found.\n")
        ScanStore(url: url).save(clean, for: "repo#1#abc")
        let again = ScanStore(url: url)        // a new instance, as after a relaunch
        XCTAssertEqual(again.result(for: "repo#1#abc")?.findings.count, 0)
        XCTAssertNotNil(again.result(for: "repo#1#abc"))
        XCTAssertNil(again.result(for: "repo#1#def"), "a new head commit must not reuse the old scan")
    }

    func testChecksumLookup() {
        let sums = "abc123  CPilot-0.1.0.dmg\ndef456 *other.dmg\n"
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "CPilot-0.1.0.dmg"), "abc123")
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "other.dmg"), "def456")
        XCTAssertNil(UpdateChecker.checksum(in: sums, for: "missing.dmg"))
    }

    func testCompareDecision() throws {
        let ahead = Data(#"{"status":"ahead","ahead_by":1,"commits":[{"commit":{"message":"Fix a thing\n\nbody"}}]}"#.utf8)
        guard case .available(let info) = try UpdateChecker.decide(compareJSON: ahead, head: "deadbeef") else { return XCTFail("expected available") }
        XCTAssertEqual(info.summaries, ["Fix a thing"])
        XCTAssertEqual(try UpdateChecker.decide(compareJSON: Data(#"{"status":"identical"}"#.utf8), head: "x"), .upToDate)
    }

    func testSwapScriptRollsBack() {
        XCTAssertTrue(UpdateSwap.script.contains("restored"))
    }

    func testAgentConfigRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"other":1,"mcpServers":{"keep":{"command":"x"}}}"#.utf8).write(to: url)
        try AgentIntegrations.jsonInstall(at: url, command: "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp")
        XCTAssertEqual(AgentIntegrations.jsonCommand(at: url), "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp")
        try AgentIntegrations.jsonRemove(at: url)
        XCTAssertNil(AgentIntegrations.jsonCommand(at: url))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil((root?["mcpServers"] as? [String: Any])?["keep"], "other servers must survive")
        XCTAssertEqual(root?["other"] as? Int, 1)
    }

    func testSetupStateWithNothingMissingIsReady() {
        XCTAssertTrue(SetupState(items: []).ready)
    }
}

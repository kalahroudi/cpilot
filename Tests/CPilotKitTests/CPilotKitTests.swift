import XCTest
@testable import CPilotKit

final class KitTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("v1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("garbage", than: "1.0.0"))
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

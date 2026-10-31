// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ChiefPilotTests: XCTestCase {
    private func req(_ tool: String, path: String? = nil) -> PermissionRequest { PermissionRequest(id: "1", tool: tool, summary: tool, input: "{}", path: path) }

    func testChiefMayCallCPilotToolsButNothingElse() {
        var pol = AccessPolicy()
        pol.rules = [AccessRule(path: "/code/shop", level: .fullAccess)]       // even a Full access rule does not let it edit
        var s = SessionMeta(title: ChiefPilot.title, cwd: "/code/shop", access: .askFirst)
        s.chief = true
        XCTAssertEqual(pol.decide(req("mcp__cpilot__spec_create"), session: s), .allow(reason: "Chief pilot"))
        XCTAssertEqual(pol.decide(req("Read", path: "/code/shop/a"), session: s), .allow(reason: "Full access"))       // reading goes by the access level as before
        for tool in ["Bash", "Edit", "Write", "mcp__other__thing"] {
            if case .deny = pol.decide(req(tool, path: "/code/shop/a"), session: s) {} else { XCTFail("\(tool) should be denied") }
        }
        s.chief = nil
        XCTAssertEqual(pol.decide(req("mcp__cpilot__spec_create"), session: s), .allow(reason: "Full access"))      // a normal session is unchanged
    }

    func testOnlyPushAndMergeAsk() {
        XCTAssertEqual(Set(ChiefPilot.Action.allCases.filter(\.needsApproval)), [.stackSubmit, .prMerge])
    }

    func testMcpConfigNamesTheSessionAndKeepsOtherServers() throws {
        let memory = MemoryEngine.claudeConfig(base: "http://localhost:8888", bank: "shop")
        let json = ChiefPilot.mcpConfig(server: "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp", session: "abc", existing: memory)
        let servers = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["memory"])
        let me = try XCTUnwrap(servers["cpilot"] as? [String: Any])
        XCTAssertEqual(me["command"] as? String, "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp")
        XCTAssertEqual((me["env"] as? [String: String])?[ChiefPilot.sessionEnvironment], "abc")
    }

    func testGuidanceNamesTheRepositoryAndEveryTool() {
        let g = ChiefPilot.guidance(repo: "/code/shop")
        XCTAssertTrue(g.contains("/code/shop"))
        for a in ChiefPilot.Action.allCases { XCTAssertTrue(g.contains(a.rawValue), a.rawValue) }
    }
}

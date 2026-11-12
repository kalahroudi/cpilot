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

    func testOnlyPushAndMergeCanAsk() {
        XCTAssertEqual(Set(ChiefPilot.Action.allCases.filter(\.needsApproval)), [.stackSubmit, .prMerge])
    }

    func testLeadingIsTheDefaultAndNeverAsks() {
        for a in ChiefPilot.Action.allCases { XCTAssertFalse(a.requiresApproval(.leads), a.rawValue) }
        XCTAssertTrue(ChiefPilot.Action.prMerge.requiresApproval(.asks)); XCTAssertTrue(ChiefPilot.Action.stackSubmit.requiresApproval(.asks))
        XCTAssertFalse(ChiefPilot.Action.taskStart.requiresApproval(.asks))
    }

    func testGuidanceFollowsTheAutonomy() {
        let leads = ChiefPilot.guidance(repo: "/r"), asks = ChiefPilot.guidance(repo: "/r", autonomy: .asks)
        XCTAssertEqual(leads, ChiefPilot.guidance(repo: "/r", autonomy: .leads))          // leading is the default
        XCTAssertTrue(leads.contains("accept_open_questions: true")); XCTAssertTrue(leads.contains("Do not ask the user for permission to push or merge"))
        XCTAssertFalse(leads.contains("ask the user first"))
        XCTAssertTrue(asks.contains("ask the user first")); XCTAssertFalse(asks.contains("Do not ask the user for permission"))
        for g in [leads, asks] { XCTAssertTrue(g.contains("CPilot wakes you")) }
    }

    func testOnlyWorkStartingActionsNeedAWake() {
        XCTAssertEqual(Set(ChiefPilot.Action.allCases.filter { !$0.startsWork }), [.specApprove, .specJob, .prReviews, .taskDone, .worktreeStatus])
    }

    func testChiefOwnsCompletenessInEveryMode() {
        for mode in ChiefPilot.Autonomy.allCases {
            let g = ChiefPilot.guidance(repo: "/r", autonomy: mode)
            XCTAssertTrue(g.contains("session_message")); XCTAssertTrue(g.contains("You own completeness"))
            XCTAssertTrue(g.contains("do not hand the user a choice about how to proceed with a review"))
        }
        XCTAssertFalse(ChiefPilot.Action.sessionMessage.needsApproval)
    }

    func testReviewerIsToldToLoopAndTakesAFocus() {
        let plain = ChiefPilot.reviewPrompt(number: 13, title: "t", head: "h", base: "main")
        XCTAssertTrue(plain.contains("until a full pass finds nothing left")); XCTAssertFalse(plain.contains("asked for specifically"))
        let focused = ChiefPilot.reviewPrompt(number: 13, title: "t", head: "h", base: "main", focus: "wait for both loops in connect")
        XCTAssertTrue(focused.contains("asked for specifically: wait for both loops in connect"))
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

final class ServerPathTests: XCTestCase {
    func testAppBundleDevelopmentBuildAndFallback() throws {
        XCTAssertEqual(AgentIntegrations.serverPath(bundlePath: "/Applications/CPilot.app", executableDir: nil), "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(AgentIntegrations.serverPath(bundlePath: "/x/.build/debug", executableDir: dir.path), "/Applications/CPilot.app/Contents/MacOS/cpilot-mcp")   // nothing built next to it
        let exe = dir.appendingPathComponent("cpilot-mcp")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertEqual(AgentIntegrations.serverPath(bundlePath: "/x/.build/debug", executableDir: dir.path), exe.path)
    }
}

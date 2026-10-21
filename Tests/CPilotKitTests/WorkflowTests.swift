// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class WorkflowTests: XCTestCase {
    func testDiffParser() {
        let d = """
        diff --git a/src/a.ts b/src/a.ts
        index 1..2 100644
        --- a/src/a.ts
        +++ b/src/a.ts
        @@ -10,3 +10,4 @@ func
         keep
        -old
        +new
        +extra
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        let files = DiffParser.parse(d)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "src/a.ts")
        XCTAssertEqual(files[0].additions, 2); XCTAssertEqual(files[0].deletions, 1)
        let added = files[0].lines.filter { $0.kind == .added }
        XCTAssertEqual(added.first?.newNumber, 11)
        XCTAssertEqual(files[0].lines.first { $0.kind == .removed }?.oldNumber, 11)
        XCTAssertTrue(files[1].isBinary)
    }

    func testRemoteSlug() {
        XCTAssertEqual(Git.slug(fromRemote: "https://kalahroudi@github.com/kalahroudi/cpilot.git"), "kalahroudi/cpilot")
        XCTAssertEqual(Git.slug(fromRemote: "git@github.com:a/b.git\n"), "a/b")
        XCTAssertNil(Git.slug(fromRemote: "https://example.com/a/b"))
        XCTAssertEqual(Git.slugify("Fix flaky login test!"), "fix-flaky-login-test")
    }

    func testRuleset() throws {
        let j = try JSONSerialization.jsonObject(with: Data(RepoSetup.rulesetJSON(requiredChecks: []).utf8)) as! [String: Any]
        let types = (j["rules"] as! [[String: Any]]).map { $0["type"] as! String }
        XCTAssertEqual(types, ["deletion", "non_fast_forward", "required_linear_history", "pull_request"])
        let withChecks = try JSONSerialization.jsonObject(with: Data(RepoSetup.rulesetJSON(requiredChecks: ["build"]).utf8)) as! [String: Any]
        XCTAssertTrue((withChecks["rules"] as! [[String: Any]]).contains { $0["type"] as? String == "required_status_checks" })
    }

    func testSecurityReportParsing() {
        let md = """
        # Report
        ## Fix these
        ### Session cookie missing SameSite
        src/api/session.ts:41 reproduced in a container
        ## We couldn't confirm these
        - **Possible open redirect** in /login
        - Weak default secret
        ## Notes
        - ignored
        """
        let r = SecurityCage.parse(report: md)
        XCTAssertEqual(r.confirmed.map(\.title), ["Session cookie missing SameSite"])
        XCTAssertEqual(r.leads.count, 2)
        XCTAssertTrue(r.blocksMerge)
        XCTAssertTrue(r.confirmed[0].detail.contains("session.ts"))
        XCTAssertFalse(SecurityCage.parse(report: "## Fix these\n\n## We couldn't confirm these\n- a").blocksMerge)
    }

    func testMemoryAndSkills() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = MemoryStore(root: dir)
        let scope = MemoryStore.scope(forProject: "/code/shop")
        m.save(scope: scope, name: "Test command", body: "Run npm test")
        m.save(scope: MemoryStore.globalScope, name: "Style", body: "Plain language")
        XCTAssertEqual(m.search("npm", scopes: [scope]).count, 1)
        XCTAssertTrue(m.context(forProject: "/code/shop")!.contains("Run npm test"))
        XCTAssertFalse(m.context(forProject: "/code/other-x")!.contains("npm test"))
        XCTAssertEqual(SkillCatalog.frontmatter("---\nname: a\ndescription: \"Does b\"\n---\nbody")["description"], "Does b")
    }

    func testCompose() {
        let a = Capture.snippet("Error: ECONNRESET\n at x", source: "Terminal")
        let out = Capture.compose(message: "Why?", attachments: [a, Capture.link(title: "Docs", url: "https://x.dev", source: nil)])
        XCTAssertTrue(out.text.contains("From Terminal"))
        XCTAssertTrue(out.text.contains("<https://x.dev>"))
        XCTAssertTrue(out.images.isEmpty)
    }

    func testAcpReducer() {
        var r = AcpUpdateReducer()
        func msg(_ t: String) -> [String: Any] { ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": t]] }
        _ = r.apply(update: msg("Hel"))
        let grown = r.apply(update: msg("lo"))
        XCTAssertEqual(grown.first?.text, "Hello")
        let tool = r.apply(update: ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read a.ts", "kind": "read", "status": "pending"])
        XCTAssertEqual(tool.count, 2)               // closes the message, opens the tool row
        XCTAssertEqual(tool[0].status, .done)
        let done = r.apply(update: ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"])
        XCTAssertEqual(done.first?.status, .done)
        let after = r.apply(update: msg("Next"))
        XCTAssertNotEqual(after.first?.id, grown.first?.id)   // text after a tool call is a new row
    }
}

final class MergeGateTests: XCTestCase {
    func pr(draft: Bool = false, review: String? = nil, mergeable: String? = "MERGEABLE") -> PullRequest {
        PullRequest(number: 1, title: "t", state: "OPEN", isDraft: draft, headRefName: "h", baseRefName: "main", author: nil, url: "u",
                    reviewDecision: review, mergeable: mergeable)
    }
    func testGate() {
        let ok = PullRequest.Check(name: "build", state: "SUCCESS")
        let bad = PullRequest.Check(name: "test", state: "FAILURE")
        let wait = PullRequest.Check(name: "lint", state: "PENDING")
        let clean = SecurityResult(findings: [], report: "")
        let issue = SecurityResult(findings: [SecurityFinding(title: "x", confirmed: true, detail: "")], report: "")
        XCTAssertTrue(MergeGate.evaluate(pr: pr(), checks: [ok], scan: clean, requireScan: true).ready)
        XCTAssertFalse(MergeGate.evaluate(pr: pr(), checks: [ok, bad], scan: clean, requireScan: true).ready)
        XCTAssertEqual(MergeGate.evaluate(pr: pr(), checks: [ok, wait], scan: clean, requireScan: true).reasons, ["Checks are still running."])
        XCTAssertFalse(MergeGate.evaluate(pr: pr(), checks: [ok], scan: issue, requireScan: true).ready)
        XCTAssertTrue(MergeGate.evaluate(pr: pr(), checks: [ok], scan: issue, requireScan: false).ready)
        XCTAssertFalse(MergeGate.evaluate(pr: pr(), checks: [ok], scan: nil, requireScan: true).ready)
        XCTAssertFalse(MergeGate.evaluate(pr: pr(draft: true), checks: [], scan: nil, requireScan: false).ready)
        XCTAssertFalse(MergeGate.evaluate(pr: pr(review: "CHANGES_REQUESTED"), checks: [], scan: nil, requireScan: false).ready)
        XCTAssertFalse(MergeGate.evaluate(pr: pr(mergeable: "CONFLICTING"), checks: [], scan: nil, requireScan: false).ready)
    }
}

final class RegistryTests: XCTestCase {
    func testRegistryParsing() {
        let json = #"{"agents":[{"id":"a","name":"Alpha","description":"d","distribution":{"npx":{"package":"alpha@1.0","args":["--acp"],"env":{"K":"V"}}}},{"id":"b","name":"Beta","distribution":{"uvx":{"package":"beta==2"}}},{"id":"c","name":"Gamma","distribution":{"binary":{}}}]}"#
        let list = AcpRegistry.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(list[0].config?.command, "npx")
        XCTAssertEqual(list[0].config?.args, ["-y", "alpha@1.0", "--acp"])
        XCTAssertEqual(list[0].config?.env, ["K": "V"])
        XCTAssertEqual(list[1].config?.args, ["beta==2"])
        XCTAssertNil(list[2].config)
    }
}

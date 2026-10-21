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

final class MemoryEngineTests: XCTestCase {
    func testConfigShapes() throws {
        XCTAssertEqual(MemoryEngine.mcpURL(base: "http://localhost:8888/", bank: "shop-1"), "http://localhost:8888/mcp/shop-1/")
        let j = try JSONSerialization.jsonObject(with: Data(MemoryEngine.claudeConfig(base: "http://h:1", bank: "b").utf8)) as! [String: Any]
        let server = (j["mcpServers"] as! [String: Any])["memory"] as! [String: Any]
        XCTAssertEqual(server["url"] as? String, "http://h:1/mcp/b/"); XCTAssertEqual(server["type"] as? String, "http")
        XCTAssertEqual(MemoryEngine.acpServers(base: "http://h:1", bank: "b").first?["name"] as? String, "memory")
    }
}

final class MemoryQualityTests: XCTestCase {
    func testDigestCompactsAndKeepsRecent() {
        XCTAssertEqual(ContextDigest.compact("a   b\n c"), "a b c")
        XCTAssertEqual(ContextDigest.compact(String(repeating: "x", count: 300)).count, 240)
        let items = [ChatItem(kind: .user, text: "first question"),
                     ChatItem(kind: .assistant, text: "an answer"),
                     ChatItem(kind: .tool, title: "Bash", detail: "npm test", status: .done),
                     ChatItem(kind: .tool, title: "Edit", detail: "src/a.ts", status: .done),
                     ChatItem(kind: .thinking, text: "hmm"), ChatItem(kind: .notice, text: "n")]
        let d = ContextDigest.build(items: items)
        XCTAssertEqual(d, "User: first question\nAssistant: an answer\nRan: npm test\nChanged: src/a.ts")
        let tight = ContextDigest.build(items: items, budget: 40)
        XCTAssertTrue(tight.hasPrefix("(") && tight.contains("Changed: src/a.ts"))
        XCTAssertFalse(tight.contains("first question"))
    }

    func testRankingAndPlan() {
        let m = MemoryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope = MemoryStore.scope(forProject: "/code/shop")
        m.save(scope: scope, name: "Login tests", body: "flaky because of redirect")
        m.save(scope: scope, name: "Deploy", body: "login is not part of deploy but mentioned login login")
        XCTAssertEqual(m.search("login", scopes: [scope]).first?.name, "login-tests")
        XCTAssertTrue(m.search("nonexistent", scopes: [scope]).isEmpty)
        let plan = m.plan(forProject: "/code/shop", limit: 120)
        XCTAssertEqual(plan.included.count + plan.dropped.count, 2)
        XCTAssertFalse(plan.dropped.isEmpty)
        XCTAssertNil(m.plan(forProject: "/code/none-xyz", limit: 6000).text?.contains("Login") == true ? "" : nil)
    }

    func testForkArguments() {
        var c = ClaudeRunner.Config(cwd: "/tmp"); c.resumeId = "abc"; c.fork = true
        XCTAssertTrue(ClaudeRunner.arguments(c).contains("--fork-session"))
        c.resumeId = nil
        XCTAssertFalse(ClaudeRunner.arguments(c).contains("--fork-session"))
    }
}

/// A tiny deterministic "meaning" model: words in the same group get the same direction.
struct FakeEmbedder: TextEmbedder {
    static let groups = [["car", "vehicle", "automobile"], ["cookie", "session", "login"], ["banana", "fruit"]]
    func embed(_ text: String) -> [Float]? {
        var v = [Float](repeating: 0, count: Self.groups.count)
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter }) { for (i, g) in Self.groups.enumerated() where g.contains(String(w)) { v[i] += 1 } }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : nil
    }
}

final class MemoryIndexTests: XCTestCase {
    func index() -> MemoryIndex { MemoryIndex(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db"), embedder: FakeEmbedder()) }

    func testKeywordAndMeaningRecall() {
        let ix = index(); XCTAssertTrue(ix.isOpen)
        ix.add(scope: "shop", source: "chat", ref: "s1", text: "We fixed the flaky login test by waiting for the session response.")
        ix.add(scope: "shop", source: "chat", ref: "s2", text: "The banana pricing table needs a rounding fix in the invoice code.")
        ix.add(scope: "other", source: "chat", ref: "s3", text: "The login redirect in the other project was broken.")
        // keyword
        XCTAssertEqual(ix.search("flaky tests", scopes: ["shop"]).first?.ref, "s1")
        // meaning: "cookie" shares no word with the text but sits in the same group as "session"/"login"
        XCTAssertEqual(ix.search("cookie problem", scopes: ["shop"]).first?.ref, "s1")
        // scope is respected
        XCTAssertFalse(ix.search("login", scopes: ["shop"]).contains { $0.ref == "s3" })
        XCTAssertTrue(ix.search("login").contains { $0.ref == "s3" })
        XCTAssertFalse(ix.search("login", scopes: ["shop"], excludingRef: "s1").contains { $0.ref == "s1" })
        XCTAssertEqual(ix.counts().chats, 3)
    }

    func testReplaceRemoveDedupeAndRedaction() {
        let ix = index()
        ix.replace(scope: "g", source: "note", ref: "n", text: "Use the old deploy script for staging servers.")
        ix.replace(scope: "g", source: "note", ref: "n", text: "Use the new release pipeline for staging servers.")
        XCTAssertEqual(ix.counts().notes, 1)
        XCTAssertTrue(ix.search("pipeline").first?.text.contains("new release") == true)
        XCTAssertTrue(ix.search("script deploy").isEmpty)
        ix.add(scope: "g", source: "chat", ref: "c", text: "My key is sk-abcdefghijklmnop1234 please keep it.")
        XCTAssertFalse(ix.search("please keep").first?.text.contains("sk-abc") ?? false)
        ix.remove(ref: "n"); XCTAssertEqual(ix.counts().notes, 0)
        let again = "Same sentence repeated here."
        ix.add(scope: "g", source: "chat", ref: "d", text: again); ix.add(scope: "g", source: "chat", ref: "d", text: again)
        XCTAssertEqual(ix.counts().chats, 2)   // "c" plus a single "d"
    }

    func testChunkingAndRecallText() {
        XCTAssertEqual(MemoryIndex.chunks("short").count, 1)
        XCTAssertGreaterThan(MemoryIndex.chunks(String(repeating: "A sentence here. ", count: 80)).count, 1)
        let hit = MemoryIndex.Hit(id: 1, scope: "s", source: "chat", ref: "r", text: "Fixed it", score: 1)
        XCTAssertTrue(Recall.context([hit], titles: ["r": "Login fix"])!.contains("Login fix"))
        XCTAssertNil(Recall.context([]))
    }

    func testRealEmbedderRelatesSimilarSentences() throws {
        let e = NLEmbedder()
        try XCTSkipUnless(e.isAvailable, "no on-device embedding")
        let a = e.embed("The car would not start this morning")!, b = e.embed("My vehicle failed to turn on today")!, c = e.embed("Quarterly tax filing deadlines")!
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        XCTAssertGreaterThan(dot(a, b), dot(a, c))
    }
}

final class RecapTests: XCTestCase {
    func items() -> [ChatItem] {
        [ChatItem(kind: .user, text: "Fix the flaky login test"),
         ChatItem(kind: .assistant, text: "I found a race. Fixing it now.", status: .done),
         ChatItem(kind: .tool, title: "Edit", detail: "/code/shop/tests/login.spec.ts", status: .done),
         ChatItem(kind: .tool, title: "Bash", detail: "npm test", status: .failed),
         ChatItem(kind: .user, text: "Also run it 20 times"),
         ChatItem(kind: .assistant, text: "Sure. Running it twenty times.", status: .done),
         ChatItem(id: "perm-1", kind: .permission, text: "npm test -- --repeat-each=20", title: "Bash", status: .pending)]
    }

    func testPartsAndText() {
        let p = Recap.parts(items())
        XCTAssertEqual(p.firstAsk, "Fix the flaky login test"); XCTAssertEqual(p.latestAsk, "Also run it 20 times")
        XCTAssertEqual(p.files, ["login.spec.ts"]); XCTAssertEqual(p.commands, ["npm test"]); XCTAssertEqual(p.failures, 1)
        XCTAssertEqual(p.lastReply, "Sure")
        XCTAssertTrue(p.waiting?.contains("npm test -- --repeat-each=20") == true)
        let t = Recap.text(p)
        XCTAssertTrue(t.contains("**Latest ask:** Also run it 20 times") && t.contains("**Started with:**") && t.contains("changed 1 file") && t.contains("1 step failed") && t.contains("**Waiting on you:**"))
        XCTAssertTrue(Recap.headline(p).hasPrefix("Waiting on approval to run"))
    }

    func testEmptyAndDue() {
        XCTAssertTrue(Recap.parts([]).isEmpty)
        XCTAssertEqual(Recap.text(Recap.parts([])), "Nothing has happened in this session yet.")
        XCTAssertTrue(Recap.isDue(lastActivity: .now.addingTimeInterval(-1300)))
        XCTAssertFalse(Recap.isDue(lastActivity: .now.addingTimeInterval(-60)))
        XCTAssertEqual(Recap.headline(Recap.parts([ChatItem(kind: .user, text: "Hello there")])), "Hello there")
    }
}

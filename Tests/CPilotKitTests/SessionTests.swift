// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class SessionTests: XCTestCase {
    func testStreamingReplyGrowsInPlaceAndToolsComplete() {
        var p = ClaudeStreamParser()
        var items: [ChatItem] = []
        func feed(_ s: String) -> [ClaudeEvent] {
            let ev = p.parse(line: s)
            for case .item(let i) in ev { items.upsert(i) }
            return ev
        }
        XCTAssertEqual(feed(#"{"type":"system","subtype":"init","session_id":"S1","model":"m"}"#), [.initialized(sessionId: "S1", model: "m")])
        _ = feed(#"{"type":"stream_event","api_message_id":"A","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#)
        _ = feed(#"{"type":"stream_event","api_message_id":"A","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"po"}}}"#)
        _ = feed(#"{"type":"stream_event","api_message_id":"A","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ng"}}}"#)
        _ = feed(#"{"type":"assistant","message":{"id":"A","content":[{"type":"text","text":"pong"}]}}"#)
        _ = feed(#"{"type":"stream_event","api_message_id":"A","event":{"type":"content_block_stop","index":0}}"#)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "pong")
        XCTAssertEqual(items[0].status, .done)

        _ = feed(#"{"type":"assistant","message":{"id":"B","content":[{"type":"tool_use","id":"T1","name":"Bash","input":{"command":"npm test"}}]}}"#)
        XCTAssertEqual(items.last?.detail, "npm test")
        XCTAssertEqual(items.last?.status, .running)
        _ = feed(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"T1","content":"ok","is_error":false}]}}"#)
        XCTAssertEqual(items.last?.status, .done)
        XCTAssertEqual(items.last?.text, "ok")
    }

    func testPermissionRequestAndAnswers() {
        var p = ClaudeStreamParser()
        let ev = p.parse(line: #"{"type":"control_request","request_id":"R","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"echo hi > out.txt"},"blocked_path":"/tmp/x/out.txt"}}"#)
        guard case .permission(let r) = ev.first else { return XCTFail("no permission") }
        XCTAssertEqual(r.id, "R"); XCTAssertEqual(r.summary, "echo hi > out.txt"); XCTAssertEqual(r.path, "/tmp/x/out.txt")
        XCTAssertTrue(ClaudeWire.allow(requestId: "R", updatedInput: r.input).contains(#""behavior":"allow""#))
        XCTAssertTrue(ClaudeWire.deny(requestId: "R", message: "no").contains(#""behavior":"deny""#))
    }

    func testResultEvent() {
        var p = ClaudeStreamParser()
        XCTAssertEqual(p.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.5}"#),
                       [.turnEnded(isError: false, text: "done", cost: 0.5)])
    }

    func testArguments() {
        var c = ClaudeRunner.Config(cwd: "/tmp"); c.access = .fullAccess; c.resumeId = "abc"; c.model = "opus"
        let a = ClaudeRunner.arguments(c)
        XCTAssertTrue(a.contains("--allow-dangerously-skip-permissions"))
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], "abc")
        XCTAssertEqual(a[a.firstIndex(of: "--permission-mode")! + 1], "bypassPermissions")
    }

    func testStoreRoundTripAndUpsert() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(root: dir)
        let m = SessionMeta(title: "t", cwd: "/tmp/shop")
        store.save(m)
        store.append(ChatItem(id: "1", kind: .assistant, text: "a"), to: m.id)
        store.append(ChatItem(id: "1", kind: .assistant, text: "ab", status: .done), to: m.id)
        store.append(ChatItem(id: "2", kind: .user, text: "q"), to: m.id)
        let items = store.items(m.id)
        XCTAssertEqual(items.map(\.text), ["ab", "q"])
        XCTAssertEqual(store.list().first?.project, "shop")
    }

    func testSpecFullAccessRepos() throws {
        var pol = AccessPolicy()
        XCTAssertTrue(pol.specSessionsHaveFullAccess("/code/shop"))
        pol.setSpecFullAccess(false, repo: "/code/shop")
        XCTAssertFalse(pol.specSessionsHaveFullAccess("/code/shop"))
        XCTAssertTrue(pol.specSessionsHaveFullAccess("/code/other"))
        pol.setSpecFullAccess(true, repo: "/code/shop")
        XCTAssertNil(pol.specAskRepos)
        // An older policy file without the key still loads.
        let old = try JSONDecoder().decode(AccessPolicy.self, from: JSONEncoder().encode(AccessPolicy()))
        XCTAssertNil(old.specAskRepos)
    }

    func testPolicy() {
        var pol = AccessPolicy()
        pol.rules = [AccessRule(path: "/code/shop", allowCommands: ["npm test", "git status"])]
        let s = SessionMeta(title: "t", cwd: "/code/shop", access: .askFirst)
        func req(_ tool: String, _ sum: String, path: String? = nil) -> PermissionRequest { PermissionRequest(id: "1", tool: tool, summary: sum, input: "{}", path: path) }
        XCTAssertEqual(pol.decide(req("Read", "/code/shop/a", path: "/code/shop/a"), session: s), .allow(reason: "Reading is free"))
        XCTAssertEqual(pol.decide(req("Bash", "npm test -- x"), session: s), .allow(reason: "Project rule"))
        XCTAssertEqual(pol.decide(req("Bash", "npm test; rm -rf /"), session: s), .ask)
        XCTAssertEqual(pol.decide(req("Bash", "npm testing"), session: s), .ask)
        XCTAssertEqual(pol.decide(req("Write", "/etc/x", path: "/etc/x"), session: s), .ask)
        var ro = s; ro.access = .readOnly
        if case .deny = pol.decide(req("Bash", "ls"), session: ro) {} else { XCTFail("read only should deny") }
        var ef = s; ef.access = .editFiles
        XCTAssertEqual(pol.decide(req("Edit", "/code/shop/a.ts", path: "/code/shop/a.ts"), session: ef), .allow(reason: "Edit files"))
        XCTAssertEqual(pol.decide(req("Bash", "make"), session: s, sessionGrants: ["Bash:make"]), .allow(reason: "Allowed for this session"))
    }
}

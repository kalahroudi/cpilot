// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class AcpAuthTests: XCTestCase {
    let antigravity = [AcpAuthMethod(id: "oauth-personal", name: "Log in with Google"), AcpAuthMethod(id: "oauth-business", name: "Log in with Gemini Enterprise"),
                       AcpAuthMethod(id: "gemini-api-key", name: "Gemini API key"), AcpAuthMethod(id: "agent-platform", name: "Gemini Enterprise Agent Platform")]

    // MARK: Which error means "sign in"

    func testSignInErrorsAreRecognised() {
        XCTAssertTrue(AcpAuth.isAuthRequired(code: -32000, message: "Authentication required"))
        XCTAssertTrue(AcpAuth.isAuthRequired(code: nil, message: "auth_required"))
        XCTAssertTrue(AcpAuth.isAuthRequired(code: -32000, message: "Please sign in first"))
        XCTAssertFalse(AcpAuth.isAuthRequired(code: -32000, message: "Internal error"))
        XCTAssertFalse(AcpAuth.isAuthRequired(code: -32602, message: "Invalid params"))
    }

    // MARK: Which method

    func testWithNoKeysItUsesTheBrowserLogin() {
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: nil, env: [:])?.id, "oauth-personal")
    }

    func testAKeyAlreadyInTheEnvironmentIsUsedWithoutAskingYou() {
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: nil, env: ["GEMINI_API_KEY": "k"])?.id, "gemini-api-key")
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: nil, env: ["GOOGLE_API_KEY": "k"])?.id, "agent-platform")
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: nil, env: ["GEMINI_API_KEY": ""])?.id, "oauth-personal", "an empty key is no key")
    }

    func testYourChoiceForTheAgentWins() {
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: "oauth-business", env: ["GEMINI_API_KEY": "k"])?.id, "oauth-business")
        XCTAssertEqual(AcpAuth.choose(from: antigravity, preferred: "gone", env: [:])?.id, "oauth-personal", "a choice the agent no longer offers is ignored")
    }

    func testFallsBackToTheFirstMethodAndHandlesNone() {
        let onlyKeys = [AcpAuthMethod(id: "api-key", name: "Key")]
        XCTAssertEqual(AcpAuth.choose(from: onlyKeys, preferred: nil, env: [:])?.id, "api-key")
        XCTAssertNil(AcpAuth.choose(from: [], preferred: nil, env: [:]))
    }

    // MARK: Registry extras

    func testDeepSeekHarnessIsListedEvenThoughTheRegistryDoesNotHaveIt() {
        let list = AcpRegistry.withExtras([])
        let dsh = list.first { $0.id == "deepseek-harness" }
        XCTAssertEqual(dsh?.config?.command, "npx")
        XCTAssertEqual(dsh?.config?.args, ["-y", "@deepseek-ai/dsh@0.2.1-rc.2", "--profile", "acp"])
        XCTAssertEqual(AcpRegistry.withExtras(list).count, list.count, "listing twice does not duplicate")
    }

    func testARegistryEntryWithTheSameIdWinsOverTheExtra() {
        let own = RegistryAgent(id: "deepseek-harness", name: "Theirs", detail: "", config: nil, needsRuntime: nil)
        let list = AcpRegistry.withExtras([own])
        XCTAssertEqual(list.filter { $0.id == "deepseek-harness" }.map(\.name), ["Theirs"])
    }

    // MARK: Through the real client, against a small fake agent

    /// A fake ACP agent in Python: it asks for sign-in until `authenticate` is called, and writes the method it was given next to itself.
    func fakeAgent(requireAuth: Bool, authFails: Bool = false) throws -> (AcpAgentConfig, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-acp-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        import sys, json
        authed = not \(requireAuth ? "True" : "False")
        for line in sys.stdin:
            m = json.loads(line)
            def reply(result=None, error=None):
                out = {"jsonrpc": "2.0", "id": m["id"]}
                if error: out["error"] = error
                else: out["result"] = result
                sys.stdout.write(json.dumps(out) + "\\n"); sys.stdout.flush()
            if m["method"] == "initialize":
                reply({"protocolVersion": 1, "agentCapabilities": {}, "authMethods": [{"id": "oauth-personal", "name": "Log in with Google"}, {"id": "gemini-api-key", "name": "Gemini API key"}]})
            elif m["method"] == "authenticate":
                open(sys.argv[1], "a").write(m["params"]["methodId"] + "\\n")
                if \(authFails ? "True" : "False"): reply(error={"code": -32000, "message": "login cancelled"})
                else:
                    authed = True; reply({})
            elif m["method"] == "session/new":
                if authed: reply({"sessionId": "s1"})
                else: reply(error={"code": -32000, "message": "Authentication required"})
        """
        let py = dir.appendingPathComponent("agent.py"); try script.write(to: py, atomically: true, encoding: .utf8)
        let record = dir.appendingPathComponent("auth.log")
        return (AcpAgentConfig(id: "fake", name: "Fake", command: "/usr/bin/python3", args: [py.path, record.path]), record)
    }

    func methodsTried(_ record: URL) -> [String] { ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func testSignsInByItselfWhenTheAgentAsksAndThenOpensTheSession() async throws {
        let (cfg, record) = try fakeAgent(requireAuth: true)
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { _ in }
        defer { client.stop() }
        try await client.start()
        XCTAssertEqual(client.authMethods.map(\.id), ["oauth-personal", "gemini-api-key"])
        let id = try await client.newSession()
        XCTAssertEqual(id, "s1")
        XCTAssertEqual(methodsTried(record), ["oauth-personal"])
    }

    func testUsesTheMethodChosenForTheAgent() async throws {
        var (cfg, record) = try fakeAgent(requireAuth: true)
        cfg.authMethod = "gemini-api-key"
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { _ in }
        defer { client.stop() }
        try await client.start()
        _ = try await client.newSession()
        XCTAssertEqual(methodsTried(record), ["gemini-api-key"])
    }

    func testDoesNotSignInWhenTheAgentDoesNotAsk() async throws {
        let (cfg, record) = try fakeAgent(requireAuth: false)
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { _ in }
        defer { client.stop() }
        try await client.start()
        _ = try await client.newSession()
        XCTAssertEqual(methodsTried(record), [])
    }

    func testAgentCheckReportsWorkingNeedsSignInAndBroken() async throws {
        let (ready, _) = try fakeAgent(requireAuth: false)
        let ok = await AgentCheck.run(ready, on: nil)
        XCTAssertEqual(ok.state, .ok)
        let (locked, record) = try fakeAgent(requireAuth: true)
        let needs = await AgentCheck.run(locked, on: nil)
        XCTAssertEqual(needs.state, .needsSignIn)
        XCTAssertEqual(methodsTried(record), [], "a test never starts a sign-in")
        let broken = await AgentCheck.run(AcpAgentConfig(id: "x", name: "X", command: "/usr/bin/false"), on: nil)
        XCTAssertEqual(broken.state, .failed)
    }

    func testAFailedSignInSaysWhichMethodFailedAndWhy() async throws {
        let (cfg, _) = try fakeAgent(requireAuth: true, authFails: true)
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { _ in }
        defer { client.stop() }
        try await client.start()
        do { _ = try await client.newSession(); XCTFail("should not open a session") }
        catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Log in with Google") && text.contains("login cancelled"), text)
        }
    }

    func testTellsYouInTheChatThatItIsSigningIn() async throws {
        let (cfg, _) = try fakeAgent(requireAuth: true)
        let seen = Box()
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { if case .items(let i) = $0 { seen.add(i) } }
        defer { client.stop() }
        try await client.start()
        _ = try await client.newSession()
        XCTAssertTrue(seen.items.contains { $0.kind == .notice && $0.text.contains("Log in with Google") })
    }

    func testASignInThatNeverFinishesEndsInsteadOfWaitingForever() async throws {
        var (cfg, _) = try fakeAgent(requireAuth: true)
        let py = URL(fileURLWithPath: cfg.args[0])
        // The same agent, but `authenticate` is never answered (you walked away from the browser).
        let script = try String(contentsOf: py, encoding: .utf8).replacingOccurrences(of: "authed = True; reply({})", with: "pass")
        try script.write(to: py, atomically: true, encoding: .utf8)
        cfg.authMethod = "oauth-personal"
        let old = AcpClient.signInTimeout; AcpClient.signInTimeout = 1; defer { AcpClient.signInTimeout = old }
        let client = AcpClient(config: cfg, cwd: FileManager.default.temporaryDirectory) { _ in }
        defer { client.stop() }
        try await client.start()
        let started = Date()
        do { _ = try await client.newSession(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Timed out"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    final class Box: @unchecked Sendable { private let lock = NSLock(); private var all: [ChatItem] = []
        func add(_ i: [ChatItem]) { lock.lock(); all += i; lock.unlock() }
        var items: [ChatItem] { lock.lock(); defer { lock.unlock() }; return all } }
}

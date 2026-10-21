// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

/// Talks to the real Claude command line. Runs only when CPILOT_LIVE=1, because it uses a little of your quota.
final class LiveClaudeTests: XCTestCase {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var parser = ClaudeStreamParser()
        var items: [ChatItem] = []
        var sessionId: String?
        var permissions: [PermissionRequest] = []
        var ended = false
        var runner: ClaudeRunner?
        var autoAllow = true
        func feed(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            for ev in parser.parse(line: line) {
                switch ev {
                case .initialized(let s, _): sessionId = s
                case .item(let i): items.upsert(i)
                case .permission(let p):
                    permissions.append(p)
                    runner?.send(autoAllow ? ClaudeWire.allow(requestId: p.id, updatedInput: p.input) : ClaudeWire.deny(requestId: p.id, message: "no"))
                case .turnEnded: ended = true
                }
            }
        }
    }

    func run(_ prompt: String, resume: String? = nil, allow: Bool = true, dir: URL) async throws -> Box {
        let box = Box(); box.autoAllow = allow
        var cfg = ClaudeRunner.Config(cwd: dir.path); cfg.model = "haiku"; cfg.resumeId = resume
        let r = ClaudeRunner(config: cfg, onLine: { box.feed($0) }, onExit: { _ in })
        box.runner = r
        try await r.start()
        r.send(ClaudeWire.userMessage(text: prompt))
        for _ in 0..<240 { if box.ended { break }; try await Task.sleep(for: .milliseconds(250)) }
        r.stop()
        return box
    }

    func testLiveTurnApprovalAndResume() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_LIVE"] == "1", "live test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cpilot-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. A plain turn streams text and ends.
        let a = try await run("Remember the secret word pineapple. Reply with only: ok", dir: dir)
        XCTAssertTrue(a.ended, "turn did not end")
        XCTAssertNotNil(a.sessionId)
        XCTAssertTrue(a.items.contains { $0.kind == .assistant && !$0.text.isEmpty })

        // 2. Resuming by id restores context.
        let b = try await run("What was the secret word? Reply with only the word.", resume: a.sessionId, dir: dir)
        XCTAssertTrue(b.items.contains { $0.kind == .assistant && $0.text.lowercased().contains("pineapple") }, "context was not restored: \(b.items.map(\.text))")

        // 2b. Forking starts a new session that still knows the conversation, and leaves the original alone.
        var cfg = ClaudeRunner.Config(cwd: dir.path); cfg.model = "haiku"; cfg.resumeId = a.sessionId; cfg.fork = true
        let fbox = Box()
        let fr = ClaudeRunner(config: cfg, onLine: { fbox.feed($0) }, onExit: { _ in })
        fbox.runner = fr
        try await fr.start()
        fr.send(ClaudeWire.userMessage(text: "What was the secret word? Reply with only the word."))
        for _ in 0..<240 { if fbox.ended { break }; try await Task.sleep(for: .milliseconds(250)) }
        fr.stop()
        XCTAssertTrue(fbox.items.contains { $0.kind == .assistant && $0.text.lowercased().contains("pineapple") }, "fork lost the context")
        XCTAssertNotEqual(fbox.sessionId, a.sessionId, "fork reused the original session id")

        // 3. A command asks for approval; allowing it runs the tool.
        let c = try await run("Run the shell command: echo cpilot-ok > proof.txt", dir: dir)
        XCTAssertFalse(c.permissions.isEmpty, "no approval was requested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("proof.txt").path), "approved command did not run")

        // 4. Denying stops it.
        let d = try await run("Run the shell command: echo no > denied.txt", allow: false, dir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("denied.txt").path), "denied command ran anyway")
        _ = d
    }
}

/// The whole remote path with the real Claude command line: a server-held agent that survives a dropped connection.
final class LiveRemoteTests: XCTestCase {
    func session(_ dir: URL, env: EnvironmentConfig, key: String, attachOnly: Bool, from: Int, access: AccessLevel = .askFirst) async throws -> (LiveClaudeTests.Box, ClaudeRunner) {
        let box = LiveClaudeTests.Box()
        var cfg = ClaudeRunner.Config(cwd: dir.path); cfg.model = "haiku"; cfg.access = access
        cfg.transport = .daemon(env, key: key, attachOnly: attachOnly, fromLine: from)
        let r = ClaudeRunner(config: cfg, onLine: { box.feed($0) }, onExit: { _ in })
        box.runner = r
        try await r.start()
        return (box, r)
    }

    func waitEnded(_ box: LiveClaudeTests.Box) async throws {
        for _ in 0..<160 { if box.ended { return }; try await Task.sleep(for: .milliseconds(250)) }
    }

    func testLiveServerHeldAgentSurvivesDetach() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_LIVE"] == "1", "live test")
        try XCTSkipIf(Shell.find("node") == nil, "node is not installed")
        FakeSSH.use()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cpilotd-live-\(UUID().uuidString.prefix(8))")
        let dir = home.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("CPILOTD_HOME", home.appendingPathComponent("sessions").path, 1)
        RemoteHost.scriptLocation = home.appendingPathComponent("cpilotd.mjs").path
        defer { unsetenv("CPILOTD_HOME"); RemoteHost.scriptLocation = "$HOME/.cpilot/cpilotd.mjs" }
        let env = EnvironmentConfig(name: "t", routes: ["good"], persistent: true)
        try await Exec.with(env) { try await RemoteHost.install() }

        // 1. A turn through the server-held agent.
        let (a, ra) = try await session(dir, env: env, key: "k1", attachOnly: false, from: 0)
        ra.send(ClaudeWire.userMessage(text: "Remember the secret word mango. Reply with only: ok"))
        try await waitEnded(a)
        XCTAssertTrue(a.ended, "first turn did not end")
        let seen = ra.linesReceived
        ra.detach()                                    // the connection drops

        // 2. The agent is still there with its context. Attach again from where we left off.
        let status = await Exec.with(env) { await RemoteHost.status(id: "k1") }
        XCTAssertEqual(status?.running, true)
        let (b, rb) = try await session(dir, env: env, key: "k1", attachOnly: true, from: seen)
        rb.send(ClaudeWire.userMessage(text: "What was the secret word? Reply with only the word."))
        try await waitEnded(b)
        XCTAssertTrue(b.items.contains { $0.kind == .assistant && $0.text.lowercased().contains("mango") }, "context lost: \(b.items.map(\.text))")
        let seen2 = rb.linesReceived
        rb.detach()
        await Exec.with(env) { await RemoteHost.stop(id: "k1") }

        // 3. Work that finishes while nobody is connected, and is waiting when we come back.
        let (c, rc) = try await session(dir, env: env, key: "k2", attachOnly: false, from: 0, access: .fullAccess)
        rc.send(ClaudeWire.userMessage(text: "Run the shell command: sleep 4 && echo finished > away.txt   Then reply with only: done"))
        try await Task.sleep(for: .milliseconds(1500))
        let before = rc.linesReceived
        rc.detach()                                    // leave before it is finished
        try await Task.sleep(for: .seconds(14))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("away.txt").path), "the agent did not keep working while disconnected")
        let (d, rd) = try await session(dir, env: env, key: "k2", attachOnly: true, from: before, access: .fullAccess)
        try await waitEnded(d)
        XCTAssertTrue(d.ended, "the finished turn was not replayed after reattaching")
        rd.detach()
        await Exec.with(env) { await RemoteHost.stop(id: "k2") }
        _ = (c, seen2)
    }
}

/// A requirement typed by hand becomes a spec, a plan and a task list, with the real Claude command line, read only.
final class LiveSpecTests: XCTestCase {
    func testLiveRequirementToSpecPlanTasks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_LIVE"] == "1", "live test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spec-live-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try "export function listOrders(offset: number, limit: number) { return db.query('select * from orders offset ? limit ?', [offset, limit]) }\n".write(toFile: dir + "/src/orders.ts", atomically: true, encoding: .utf8)
        try "# Shop API\nA small orders API.\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()

        let requirement = "Large accounts time out when listing orders. Switch the orders list to cursor pagination, and keep old offset clients working for two releases."
        let reply = try await SpecStageRunner.run(prompt: SpecPrompts.specify(requirement: requirement, source: "Described by you", constitution: Specs.defaultConstitution, assume: true), cwd: dir, model: "haiku")
        let spec = SpecPrompts.extractDocument(reply)
        XCTAssertTrue(spec.hasPrefix("# "), "spec did not start with a title: \(spec.prefix(80))")
        XCTAssertTrue(spec.contains("R1"), "no requirements")
        XCTAssertTrue(Specs.openQuestions(spec).isEmpty, "assume mode should not leave questions")

        let planReply = try await SpecStageRunner.run(prompt: SpecPrompts.plan(spec: spec, constitution: nil), cwd: dir, model: "haiku")
        let plan = SpecPrompts.extractDocument(planReply)
        XCTAssertTrue(plan.contains("orders.ts"), "the plan did not look at the real code")

        let tasksReply = try await SpecStageRunner.run(prompt: SpecPrompts.tasks(spec: spec, plan: plan, constitution: nil), cwd: dir, model: "haiku")
        let tasks = Specs.parseTasks(SpecPrompts.extractDocument(tasksReply))
        XCTAssertGreaterThanOrEqual(tasks.count, 2, "expected several tasks")
        XCTAssertTrue(tasks.allSatisfy { $0.id.hasPrefix("T") && !$0.title.isEmpty })

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).sorted(), before, "a read-only stage changed the repository")
    }
}

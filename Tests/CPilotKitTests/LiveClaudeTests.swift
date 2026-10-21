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
        try r.start()
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
        try fr.start()
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

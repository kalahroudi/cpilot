// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SpecStageError: Error, LocalizedError {
    case timedOut, noReply, failed(String)
    public var errorDescription: String? {
        switch self { case .timedOut: "The agent took too long."; case .noReply: "The agent did not write a document."; case .failed(let m): m }
    }
}

/// Runs one document stage (a spec, a plan, a task list) with Claude in read-only mode and returns what it wrote.
/// The agent can read the repository but cannot change it or run commands: anything else it asks for is refused.
public enum SpecStageRunner {
    static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "ToolSearch"]

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var parser = ClaudeStreamParser()
        var reply = ""
        var ended = false
        var failure: String?
        var exited = false
        var runner: ClaudeRunner?
        var onProgress: (@Sendable (String) -> Void)?
        func flags() -> (ended: Bool, exited: Bool) { lock.lock(); defer { lock.unlock() }; return (ended, exited) }
        func markExited() { lock.lock(); exited = true; lock.unlock() }
        func outcome() -> (reply: String, failure: String?, ended: Bool, exited: Bool) { lock.lock(); defer { lock.unlock() }; return (reply, failure, ended, exited) }
        func feed(_ line: String) {
            lock.lock()
            var progress: String?
            for ev in parser.parse(line: line) {
                switch ev {
                case .item(let i):
                    if i.kind == .assistant, i.status == .done, !i.text.isEmpty { reply = i.text }
                    if i.kind == .tool, i.status == .running, let t = i.title { progress = "\(t) \(i.detail ?? "")".trimmingCharacters(in: .whitespaces) }
                case .permission(let p):
                    let ok = SpecStageRunner.readTools.contains(p.tool)
                    runner?.send(ok ? ClaudeWire.allow(requestId: p.id, updatedInput: p.input) : ClaudeWire.deny(requestId: p.id, message: "This stage is read only. Reply with the document."))
                case .turnEnded(let isError, let text, _):
                    ended = true
                    if isError { failure = text ?? "The agent stopped with an error." }
                case .initialized: break
                }
            }
            let cb = onProgress
            lock.unlock()
            if let progress { cb?(progress) }
        }
    }

    public static func run(prompt: String, cwd: String, environment: EnvironmentConfig? = nil, model: String? = nil, timeout: TimeInterval = 420,
                           images: [(mediaType: String, data: Data)] = [], onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let st = State(); st.onProgress = onProgress
        var cfg = ClaudeRunner.Config(cwd: cwd)
        cfg.model = model; cfg.access = .askFirst
        cfg.disallowedTools = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "Task", "Agent"]
        if let e = environment { cfg.transport = .ssh(e) }
        let r = ClaudeRunner(config: cfg, onLine: { st.feed($0) }, onExit: { _ in st.markExited() })
        st.runner = r
        try await r.start()
        r.send(ClaudeWire.userMessage(text: prompt, images: images))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let f = st.flags()
            if f.ended || f.exited { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        r.detach()
        let o = st.outcome()
        if let f = o.failure { throw SpecStageError.failed(f) }
        guard o.ended || !o.reply.isEmpty else { throw o.exited ? SpecStageError.failed(r.stderrTail.isEmpty ? "The agent stopped unexpectedly." : r.stderrTail) : SpecStageError.timedOut }
        guard !o.reply.isEmpty else { throw SpecStageError.noReply }
        return o.reply
    }
}

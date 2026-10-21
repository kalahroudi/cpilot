// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A coding agent that speaks the Agent Client Protocol over stdio.
public struct AcpAgentConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public init(id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.id = id; self.name = name; self.command = command; self.args = args; self.env = env
    }

    public static func load(from url: URL = AppPaths().agentsFile) -> [AcpAgentConfig] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([AcpAgentConfig].self, from: $0) } ?? []
    }
    public static func save(_ agents: [AcpAgentConfig], to url: URL = AppPaths().agentsFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(agents) { try? d.write(to: url, options: .atomic) }
    }
}

public struct AcpPermission: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable { public var id: String; public var name: String; public var kind: String }
    /// The agent's request id; pass it back to `AcpClient.answer`.
    public var id: String
    public var title: String
    public var detail: String
    public var path: String?
    public var options: [Option]
    public var allowOnce: Option? { options.first { $0.kind == "allow_once" } ?? options.first { $0.kind.hasPrefix("allow") } }
    public var allowAlways: Option? { options.first { $0.kind == "allow_always" } }
    public var rejectOnce: Option? { options.first { $0.kind == "reject_once" } ?? options.first { $0.kind.hasPrefix("reject") } }
}

public enum AcpEvent: Sendable, Equatable {
    case items([ChatItem])
    case permission(AcpPermission)
    case exited(Int32)
}

/// Turns `session/update` notifications into chat rows. Message chunks grow one row until a tool call interrupts them.
public struct AcpUpdateReducer: Sendable {
    private var turn = 0
    private var currentText: ChatItem?
    private var currentThought: ChatItem?
    private var tools: [String: ChatItem] = [:]
    public init() {}

    public mutating func endTurn() { turn += 1; currentText = nil; currentThought = nil }

    static func text(of content: Any?) -> String {
        guard let c = content as? [String: Any] else { return "" }
        if c["type"] as? String == "text" { return (c["text"] as? String) ?? "" }
        if c["type"] as? String == "resource_link" { return (c["uri"] as? String) ?? "" }
        return ""
    }

    static func toolText(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else { return "" }
        return arr.compactMap { block -> String? in
            if block["type"] as? String == "content" { return text(of: block["content"]) }
            if block["type"] as? String == "diff", let p = block["path"] as? String { return "Edited \(p)" }
            return nil
        }.joined(separator: "\n")
    }

    static func status(_ s: String?) -> ChatItem.Status {
        switch s { case "completed": .done; case "failed": .failed; default: .running }
    }

    public mutating func apply(update u: [String: Any]) -> [ChatItem] {
        switch u["sessionUpdate"] as? String {
        case "agent_message_chunk":
            let chunk = Self.text(of: u["content"])
            var item = currentText ?? ChatItem(id: "acp-\(turn)-m\(tools.count)", kind: .assistant, status: .running)
            item.text += chunk; currentText = item; return [item]
        case "agent_thought_chunk":
            let chunk = Self.text(of: u["content"])
            var item = currentThought ?? ChatItem(id: "acp-\(turn)-t\(tools.count)", kind: .thinking, status: .running)
            item.text += chunk; currentThought = item; return [item]
        case "tool_call":
            guard let id = u["toolCallId"] as? String else { return [] }
            var done: [ChatItem] = []
            if var t = currentText { t.status = .done; done.append(t); currentText = nil }
            if var t = currentThought { t.status = .done; done.append(t); currentThought = nil }
            var item = ChatItem(id: id, kind: .tool, title: (u["kind"] as? String).map { $0.capitalized } ?? "Tool",
                                detail: u["title"] as? String, status: Self.status(u["status"] as? String))
            item.text = Self.toolText(u["content"])
            tools[id] = item
            return done + [item]
        case "tool_call_update":
            guard let id = u["toolCallId"] as? String, var item = tools[id] else { return [] }
            if let s = u["status"] as? String { item.status = Self.status(s) }
            if let t = u["title"] as? String { item.detail = t }
            let body = Self.toolText(u["content"]); if !body.isEmpty { item.text = body }
            tools[id] = item; return [item]
        default: return []
        }
    }

    /// Close any streaming row when the turn is over.
    public mutating func finish() -> [ChatItem] {
        var out: [ChatItem] = []
        if var t = currentText { t.status = .done; out.append(t) }
        if var t = currentThought { t.status = .done; out.append(t) }
        endTurn()
        return out
    }
}

public enum AcpError: Error, LocalizedError {
    case notRunning, server(String), badResponse
    public var errorDescription: String? {
        switch self { case .notRunning: "The agent is not running."; case .server(let m): m; case .badResponse: "The agent sent an unexpected reply." }
    }
}

/// A small JSON-RPC client for ACP. The protocol is a handful of calls over newline-delimited JSON, so there is no reason
/// to pull in a package: initialize, session/new or load, session/prompt, session/cancel, and the agent's callbacks.
public final class AcpClient: @unchecked Sendable {
    private let config: AcpAgentConfig
    private let cwd: URL
    private let environment: EnvironmentConfig?
    private let onEvent: @Sendable (AcpEvent) -> Void
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "cpilot.acp.write")
    private var carry = ""
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var permissionIds: [String: Any] = [:]       // string key -> original JSON-RPC id
    private var reducer = AcpUpdateReducer()
    public private(set) var canLoadSession = false
    /// MCP servers handed to every session this client opens (for example the memory engine).
    public var mcpServers: [[String: Any]] = []

    public init(config: AcpAgentConfig, cwd: URL, environment: EnvironmentConfig? = nil, onEvent: @escaping @Sendable (AcpEvent) -> Void) {
        self.config = config; self.cwd = cwd; self.environment = environment; self.onEvent = onEvent
    }

    public var isRunning: Bool { process.isRunning }

    public func start() async throws {
        if let e = environment {
            // The agent runs on the server and reads its own files there, so CPilot offers no file access of its own.
            process.executableURL = URL(fileURLWithPath: SSH.executable)
            process.arguments = SSH.baseArgs(e) + [e.target, SSH.remoteCommand(config.command, config.args, cwd: cwd.path, env: config.env)]
            process.environment = Shell.environment
        } else {
            guard let path = Shell.find(config.command) else { throw ShellError.toolNotFound(config.command) }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = config.args
            process.currentDirectoryURL = cwd
            process.environment = Shell.environment.merging(config.env) { _, n in n }
        }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.ingest(d) }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.failAll(AcpError.notRunning)
            self.onEvent(.exited(p.terminationStatus))
        }
        try process.run()
        let res = try await request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": environment == nil, "writeTextFile": environment == nil], "terminal": false],
            "clientInfo": ["name": "CPilot", "version": BuildInfo.current.version],
        ])
        canLoadSession = ((res["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool) ?? false
    }

    // MARK: Calls

    public func newSession() async throws -> String {
        let r = try await request("session/new", ["cwd": cwd.path, "mcpServers": mcpServers])
        guard let id = r["sessionId"] as? String else { throw AcpError.badResponse }
        return id
    }

    /// Restores a session with its context. Falls back to a new session when the agent cannot load.
    public func loadSession(_ id: String) async throws -> String {
        guard canLoadSession else { return try await newSession() }
        _ = try await request("session/load", ["sessionId": id, "cwd": cwd.path, "mcpServers": mcpServers])
        return id
    }

    @discardableResult
    public func prompt(sessionId: String, text: String, images: [(mediaType: String, data: Data)] = []) async throws -> String {
        var blocks: [[String: Any]] = images.map { ["type": "image", "mimeType": $0.mediaType, "data": $0.data.base64EncodedString()] }
        blocks.append(["type": "text", "text": text])
        let r = try await request("session/prompt", ["sessionId": sessionId, "prompt": blocks])
        let rest = flushReducer()
        if !rest.isEmpty { onEvent(.items(rest)) }
        return (r["stopReason"] as? String) ?? "end_turn"
    }

    private func flushReducer() -> [ChatItem] { lock.lock(); defer { lock.unlock() }; return reducer.finish() }

    public func cancel(sessionId: String) { notify("session/cancel", ["sessionId": sessionId]) }

    public func answer(permission id: String, optionId: String?) {
        lock.lock(); let rpc = permissionIds.removeValue(forKey: id); lock.unlock()
        guard let rpc else { return }
        let outcome: [String: Any] = optionId.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        write(["jsonrpc": "2.0", "id": rpc, "result": ["outcome": outcome]])
    }

    public func stop() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        failAll(AcpError.notRunning)
    }

    // MARK: Transport

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard process.isRunning else { throw AcpError.notRunning }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); let id = nextId; nextId += 1; pending[id] = cont; lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) { write(["jsonrpc": "2.0", "method": method, "params": params]) }

    private func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        writeQueue.async { [stdin] in try? stdin.fileHandleForWriting.write(contentsOf: d + Data([0x0A])) }
    }

    private func failAll(_ error: Error) {
        lock.lock(); let all = pending; pending = [:]; lock.unlock()
        for (_, c) in all { c.resume(throwing: error) }
    }

    private func ingest(_ d: Data) {
        lock.lock()
        carry += String(decoding: d, as: UTF8.self)
        var lines: [String] = []
        while let nl = carry.firstIndex(of: "\n") { lines.append(String(carry[..<nl])); carry.removeSubrange(...nl) }
        lock.unlock()
        for l in lines where !l.isEmpty { handle(l) }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = msg["method"] as? String {
            let params = (msg["params"] as? [String: Any]) ?? [:]
            if let rpc = msg["id"] { handleRequest(method, params, id: rpc) } else { handleNotification(method, params) }
            return
        }
        guard let id = msg["id"] as? Int else { return }
        lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
        if let err = msg["error"] as? [String: Any] { cont?.resume(throwing: AcpError.server((err["message"] as? String) ?? "Agent error")) }
        else { cont?.resume(returning: (msg["result"] as? [String: Any]) ?? [:]) }
    }

    private func handleNotification(_ method: String, _ p: [String: Any]) {
        guard method == "session/update", let u = p["update"] as? [String: Any] else { return }
        lock.lock(); let items = reducer.apply(update: u); lock.unlock()
        if !items.isEmpty { onEvent(.items(items)) }
    }

    private func handleRequest(_ method: String, _ p: [String: Any], id: Any) {
        switch method {
        case "session/request_permission":
            let call = (p["toolCall"] as? [String: Any]) ?? [:]
            let opts = ((p["options"] as? [[String: Any]]) ?? []).map {
                AcpPermission.Option(id: ($0["optionId"] as? String) ?? "", name: ($0["name"] as? String) ?? "", kind: ($0["kind"] as? String) ?? "")
            }
            let key = UUID().uuidString
            lock.lock(); permissionIds[key] = id; lock.unlock()
            let loc = ((call["locations"] as? [[String: Any]])?.first?["path"] as? String)
            onEvent(.permission(AcpPermission(id: key, title: (call["title"] as? String) ?? "Use a tool", detail: (call["kind"] as? String) ?? "",
                                              path: loc, options: opts)))
        case "fs/read_text_file":
            guard let path = p["path"] as? String, AccessPolicy.isInside(path, folder: cwd.path),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { reply(id, error: "Cannot read that file."); return }
            var lines = text.components(separatedBy: "\n")
            if let start = p["line"] as? Int, start > 1 { lines = Array(lines.dropFirst(start - 1)) }
            if let limit = p["limit"] as? Int { lines = Array(lines.prefix(limit)) }
            write(["jsonrpc": "2.0", "id": id, "result": ["content": lines.joined(separator: "\n")]])
        case "fs/write_text_file":
            guard let path = p["path"] as? String, let content = p["content"] as? String, AccessPolicy.isInside(path, folder: cwd.path) else {
                reply(id, error: "Writing outside the project folder is not allowed."); return
            }
            do { try content.write(toFile: path, atomically: true, encoding: .utf8); write(["jsonrpc": "2.0", "id": id, "result": [String: Any]()]) }
            catch { reply(id, error: "Could not write the file.") }
        default:
            reply(id, error: "Method not supported", code: -32601)
        }
    }

    private func reply(_ id: Any, error: String, code: Int = -32000) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": error]])
    }
}

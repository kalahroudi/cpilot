// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the Claude command line tells us over its streaming JSON protocol, reduced to what the UI needs.
public enum ClaudeEvent: Sendable, Equatable {
    case initialized(sessionId: String, model: String?)
    /// Insert or replace a chat row.
    case item(ChatItem)
    /// The agent wants to use a tool and is waiting for an answer.
    case permission(PermissionRequest)
    case turnEnded(isError: Bool, text: String?, cost: Double?)
}

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public var id: String                // request id, echoed back in the answer
    public var tool: String
    public var summary: String           // the command, path or URL
    public var input: String             // raw JSON of the tool input
    public var path: String?
    public init(id: String, tool: String, summary: String, input: String, path: String? = nil) {
        self.id = id; self.tool = tool; self.summary = summary; self.input = input; self.path = path
    }
}

/// Turns stdout lines into events. Keeps just enough state to grow a streaming reply in place.
public struct ClaudeStreamParser: Sendable {
    private var streamedMessages: Set<String> = []
    private var texts: [String: ChatItem] = [:]       // "message:index" -> row being streamed
    private var tools: [String: ChatItem] = [:]       // tool_use id -> row
    private var toolJSON: [String: String] = [:]      // partial tool input while it streams
    private var ordinal: [String: Int] = [:]

    public init() {}

    public static func summary(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { input[k] as? String }
        switch tool {
        case "Bash", "PowerShell": return s("command") ?? ""
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": return s("file_path") ?? s("notebook_path") ?? ""
        case "Grep", "Glob": return s("pattern") ?? ""
        case "WebFetch": return s("url") ?? ""
        case "WebSearch": return s("query") ?? ""
        default:
            if let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), let str = String(data: d, encoding: .utf8) { return String(str.prefix(200)) }
            return ""
        }
    }

    public mutating func parse(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String {
                return [.initialized(sessionId: sid, model: obj["model"] as? String)]
            }
            return []
        case "stream_event": return parseStream(obj)
        case "assistant": return parseAssistant(obj)
        case "user": return parseToolResults(obj)
        case "control_request": return parseControl(obj)
        case "result":
            let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
            return [.turnEnded(isError: isError, text: obj["result"] as? String, cost: obj["total_cost_usd"] as? Double)]
        default: return []
        }
    }

    // MARK: Streaming deltas

    private mutating func parseStream(_ obj: [String: Any]) -> [ClaudeEvent] {
        guard let ev = obj["event"] as? [String: Any], let t = ev["type"] as? String else { return [] }
        let mid = (obj["api_message_id"] as? String) ?? "m"
        let idx = (ev["index"] as? Int) ?? 0
        let key = "\(mid):\(idx)"
        let sub = (obj["parent_tool_use_id"] as? String) != nil   // subagent chatter stays out of the main transcript
        switch t {
        case "content_block_start":
            guard !sub, let block = ev["content_block"] as? [String: Any], let bt = block["type"] as? String else { return [] }
            streamedMessages.insert(mid)
            switch bt {
            case "text":
                let item = ChatItem(id: key, kind: .assistant, text: (block["text"] as? String) ?? "", status: .running)
                texts[key] = item; return [.item(item)]
            case "thinking":
                let item = ChatItem(id: key, kind: .thinking, text: "", status: .running)
                texts[key] = item; return [.item(item)]
            case "tool_use":
                let id = (block["id"] as? String) ?? key
                let item = ChatItem(id: id, kind: .tool, title: block["name"] as? String, status: .running)
                tools[id] = item; toolJSON[id] = ""; toolKey[key] = id
                return [.item(item)]
            default: return []
            }
        case "content_block_delta":
            guard let d = ev["delta"] as? [String: Any], let dt = d["type"] as? String else { return [] }
            switch dt {
            case "text_delta", "thinking_delta":
                guard var item = texts[key] else { return [] }
                item.text += (d["text"] as? String) ?? (d["thinking"] as? String) ?? ""
                texts[key] = item; return [.item(item)]
            case "input_json_delta":
                if let id = toolKey[key] { toolJSON[id, default: ""] += (d["partial_json"] as? String) ?? "" }
                return []
            default: return []
            }
        case "content_block_stop":
            if var item = texts[key] { item.status = .done; texts[key] = nil; return [.item(item)] }
            return []
        default: return []
        }
    }
    private var toolKey: [String: String] = [:]

    // MARK: Whole messages

    private mutating func parseAssistant(_ obj: [String: Any]) -> [ClaudeEvent] {
        guard (obj["parent_tool_use_id"] as? String) == nil, let msg = obj["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]] else { return [] }
        let mid = (msg["id"] as? String) ?? UUID().uuidString
        var out: [ClaudeEvent] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if streamedMessages.contains(mid) { continue }   // already shown while it streamed
                let n = ordinal[mid, default: 0]; ordinal[mid] = n + 1
                out.append(.item(ChatItem(id: "\(mid):t\(n)", kind: .assistant, text: (b["text"] as? String) ?? "", status: .done)))
            case "tool_use":
                guard let id = b["id"] as? String else { continue }
                let name = (b["name"] as? String) ?? "Tool"
                let input = (b["input"] as? [String: Any]) ?? [:]
                var item = tools[id] ?? ChatItem(id: id, kind: .tool, title: name, status: .running)
                item.title = name
                item.detail = Self.summary(tool: name, input: input)
                tools[id] = item
                out.append(.item(item))
            default: continue
            }
        }
        return out
    }

    private mutating func parseToolResults(_ obj: [String: Any]) -> [ClaudeEvent] {
        guard let msg = obj["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [ClaudeEvent] = []
        for b in blocks where b["type"] as? String == "tool_result" {
            guard let id = b["tool_use_id"] as? String else { continue }
            var item = tools[id] ?? ChatItem(id: id, kind: .tool, title: "Tool")
            item.status = (b["is_error"] as? Bool) == true ? .failed : .done
            item.text = Self.resultText(b["content"])
            tools[id] = item
            out.append(.item(item))
        }
        return out
    }

    static func resultText(_ content: Any?) -> String {
        let s: String
        if let str = content as? String { s = str }
        else if let arr = content as? [[String: Any]] { s = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        else { s = "" }
        return s.count > 4000 ? String(s.prefix(4000)) + "\n…" : s
    }

    private func parseControl(_ obj: [String: Any]) -> [ClaudeEvent] {
        guard let id = obj["request_id"] as? String, let req = obj["request"] as? [String: Any],
              req["subtype"] as? String == "can_use_tool" else { return [] }
        let tool = (req["tool_name"] as? String) ?? "Tool"
        let input = (req["input"] as? [String: Any]) ?? [:]
        let raw = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let path = (req["blocked_path"] as? String) ?? (input["file_path"] as? String)
        return [.permission(PermissionRequest(id: id, tool: tool, summary: Self.summary(tool: tool, input: input), input: raw, path: path))]
    }
}

// MARK: Messages we send

public enum ClaudeWire {
    /// One user turn. Images go in as base64 blocks so the agent actually sees them.
    public static func userMessage(text: String, images: [(mediaType: String, data: Data)] = []) -> String {
        var content: [[String: Any]] = images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]] }
        content.append(["type": "text", "text": text])
        return json(["type": "user", "message": ["role": "user", "content": content]])
    }

    public static func allow(requestId: String, updatedInput: String) -> String {
        let input = (updatedInput.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [String: Any]()
        return json(["type": "control_response", "response": ["subtype": "success", "request_id": requestId,
                                                              "response": ["behavior": "allow", "updatedInput": input]]])
    }

    public static func deny(requestId: String, message: String) -> String {
        json(["type": "control_response", "response": ["subtype": "success", "request_id": requestId,
                                                       "response": ["behavior": "deny", "message": message]]])
    }

    public static func interrupt() -> String {
        json(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: Process

/// One running `claude` process. It stays alive between turns so replies are fast; the app stops it when the tab sleeps
/// and starts it again with `--resume`, which restores the full context.
public final class ClaudeRunner: @unchecked Sendable {
    public struct Config: Sendable {
        public var cwd: String
        public var resumeId: String?
        public var model: String?
        public var access: AccessLevel = .askFirst
        public var appendSystemPrompt: String?
        public var addDirs: [String] = []
        public var mcpConfigPath: String?
        public init(cwd: String) { self.cwd = cwd }
    }

    private let config: Config
    private let onLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "cpilot.claude.write")
    private let lock = NSLock()
    private var carry = ""
    private var errTail = ""

    public init(config: Config, onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        self.config = config; self.onLine = onLine; self.onExit = onExit
    }

    public static func arguments(_ c: Config) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--permission-prompt-tool", "stdio", "--permission-mode", c.access.claudeMode]
        if c.access == .fullAccess { a.append("--allow-dangerously-skip-permissions") }
        if let m = c.model, !m.isEmpty { a += ["--model", m] }
        if let r = c.resumeId { a += ["--resume", r] }
        if let s = c.appendSystemPrompt, !s.isEmpty { a += ["--append-system-prompt", s] }
        for d in c.addDirs { a += ["--add-dir", d] }
        if let m = c.mcpConfigPath { a += ["--mcp-config", m] }
        return a
    }

    public func start() throws {
        guard let path = Shell.find("claude") else { throw ShellError.toolNotFound("claude") }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Self.arguments(config)
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
        var env = Shell.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.ingest(d) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.lock.lock(); self.errTail = String((self.errTail + String(decoding: d, as: UTF8.self)).suffix(2000)); self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            self.ingest(self.stdout.fileHandleForReading.readDataToEndOfFile())
            self.onExit(p.terminationStatus)
        }
        try process.run()
    }

    private func ingest(_ d: Data) {
        lock.lock()
        carry += String(decoding: d, as: UTF8.self)
        var lines: [String] = []
        while let nl = carry.firstIndex(of: "\n") {
            lines.append(String(carry[..<nl])); carry.removeSubrange(...nl)
        }
        lock.unlock()
        for l in lines where !l.isEmpty { onLine(l) }
    }

    public var stderrTail: String { lock.lock(); defer { lock.unlock() }; return errTail }
    public var isRunning: Bool { process.isRunning }

    public func send(_ line: String) {
        writeQueue.async { [stdin] in
            try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    public func stop() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

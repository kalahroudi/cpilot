// SPDX-License-Identifier: MIT

import Foundation
import CPilotKit

// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
// Logs go to stderr; stdout carries protocol messages only.

let serverName = "cpilot"
let serverVersion = "0.1.0"
let toolsByName = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func reply(id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(id: Any, code: Int, message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

func handle(_ msg: [String: Any]) async {
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { return }   // notifications (e.g. notifications/initialized) get no reply
    switch method {
    case "initialize":
        let requested = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05"
        reply(id: id, result: [
            "protocolVersion": requested,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": "CPilot tools. Read-only tools are safe to call freely. Tools that change or delete things require an explicit confirm argument; ask the user before using them.",
        ])
    case "ping":
        reply(id: id, result: [:])
    case "tools/list":
        reply(id: id, result: ["tools": allTools.map(\.definition)])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let name = params["name"] as? String, let tool = toolsByName[name] else {
            fail(id: id, code: -32602, message: "Unknown tool"); return
        }
        do {
            let text = try await tool.handler(params["arguments"] as? [String: Any] ?? [:])
            reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            reply(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        fail(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

if CommandLine.arguments.contains("--version") { print("\(serverName) \(serverVersion)"); exit(0) }
FileHandle.standardError.write(Data("cpilot-mcp \(serverVersion) ready (stdio)\n".utf8))

while let line = readLine() {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    await handle(obj)
}

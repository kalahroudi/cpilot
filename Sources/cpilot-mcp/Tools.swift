// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

typealias Args = [String: Any]

struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let handler: @Sendable (Args) async throws -> String

    var definition: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func prop(_ type: String, _ desc: String, enumValues: [String]? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": type, "description": desc]
    if let e = enumValues { p["enum"] = e }
    return p
}

private func json<T: Encodable>(_ value: T) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try enc.encode(value), as: UTF8.self)
}

private func requireString(_ a: Args, _ key: String) throws -> String {
    guard let v = a[key] as? String, !v.isEmpty else { throw ToolError(message: "Missing required argument: \(key)") }
    return v
}

// Tool design rules:
//  - Names are verb_noun, read-only tools first. Every tool shares the app's Kit code; no logic is duplicated here.
//  - Output is compact JSON or short text. Transcripts take a `tail` argument so nothing is unbounded.
//  - Anything that changes the user's machine goes through the running app, which shows a native approval dialog.
//  - Deleting needs the session's exact title as `confirm_title`.

private let store = SessionStore()
private let memory = MemoryStore(index: MemoryIndex())

private func int(_ a: Args, _ k: String, _ d: Int) -> Int { (a[k] as? Int) ?? d }

/// Asks the running CPilot app to do something. The app asks the user first.
private func control(_ path: String, _ body: [String: Any]) async throws -> String {
    guard let data = try? Data(contentsOf: AppPaths().controlFile),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = info["port"] as? Int, let token = info["token"] as? String,
          (info["pid"] as? Int32).map({ kill($0, 0) == 0 }) ?? true else {
        throw ToolError(message: "CPilot is not running. Open CPilot and try again.")
    }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = "POST"; req.timeoutInterval = 120
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    guard let (out, resp) = try? await URLSession.shared.data(for: req) else { throw ToolError(message: "CPilot is not running. Open CPilot and try again.") }
    let text = String(decoding: out, as: UTF8.self)
    if (resp as? HTTPURLResponse)?.statusCode != 200 {
        let msg = (try? JSONSerialization.jsonObject(with: out) as? [String: Any])?["error"] as? String
        throw ToolError(message: msg ?? "CPilot refused the request.")
    }
    return text
}

let allTools: [Tool] = {
    var t: [Tool] = []

    t.append(Tool(name: "get_status", description: "Report CPilot's version, whether its prerequisites are installed and whether the app is running.", properties: [:], required: []) { _ in
        struct Out: Encodable { let version: String; let ready: Bool; let missing: [String]; let appRunning: Bool }
        let setup = SetupState.detect()
        let running = FileManager.default.fileExists(atPath: AppPaths().controlFile.path)
        return try json(Out(version: BuildInfo.current.version, ready: setup.ready, missing: setup.missing.map(\.title), appRunning: running))
    })

    t.append(Tool(name: "list_sessions", description: "List CPilot sessions, newest first.", properties: ["limit": prop("integer", "Maximum sessions to return. Default 20.")], required: []) { a in
        struct Row: Encodable { let id: String; let title: String; let folder: String; let branch: String?; let agent: String; let updated: String }
        let f = ISO8601DateFormatter()
        return try json(store.list().prefix(int(a, "limit", 20)).map {
            Row(id: $0.id, title: $0.title, folder: $0.cwd, branch: $0.branch, agent: $0.backend.kind == .claude ? "claude" : ($0.backend.acpAgent ?? "acp"), updated: f.string(from: $0.updatedAt))
        })
    })

    t.append(Tool(name: "get_session", description: "Read the last messages of a session.", properties: ["session_id": prop("string", "Session id from list_sessions."), "tail": prop("integer", "How many rows to return. Default 20.")], required: ["session_id"]) { a in
        let id = try requireString(a, "session_id")
        guard store.load(id) != nil else { throw ToolError(message: "No such session.") }
        struct Row: Encodable { let kind: String; let text: String; let title: String?; let status: String? }
        return try json(store.items(id, limit: int(a, "tail", 20)).map { Row(kind: $0.kind.rawValue, text: String($0.text.prefix(2000)), title: $0.title, status: $0.status?.rawValue) })
    })

    t.append(Tool(name: "search_memory", description: "Search what CPilot remembers: the user's saved notes and finished messages from earlier sessions, by words and by meaning.",
                  properties: ["query": prop("string", "What to look for."), "project_folder": prop("string", "Optional: only this project's memory plus global notes.")], required: ["query"]) { a in
        let q = try requireString(a, "query")
        let scopes = (a["project_folder"] as? String).map { [MemoryStore.scope(forProject: $0), MemoryStore.globalScope] }
        struct Row: Encodable { let source: String; let ref: String; let text: String }
        return try json(MemoryIndex().search(q, scopes: scopes, limit: 8).map { Row(source: $0.source, ref: $0.ref, text: String($0.text.prefix(800))) })
    })

    t.append(Tool(name: "save_memory", description: "Save a note to CPilot's memory so future sessions start with it. Use `project_folder` for a note about one project, or leave it empty for a note that applies everywhere.",
                  properties: ["name": prop("string", "Short title."), "body": prop("string", "The note, in Markdown."), "project_folder": prop("string", "Optional project folder.")], required: ["name", "body"]) { a in
        let scope = (a["project_folder"] as? String).map(MemoryStore.scope(forProject:)) ?? MemoryStore.globalScope
        guard let n = memory.save(scope: scope, name: try requireString(a, "name"), body: try requireString(a, "body")) else { throw ToolError(message: "Could not save the note.") }
        return "Saved \(n.scope)/\(n.name)."
    })

    t.append(Tool(name: "list_pull_requests", description: "List open pull requests for a repository folder, through the user's GitHub login.", properties: ["folder": prop("string", "Repository folder.")], required: ["folder"]) { a in
        struct Row: Encodable { let number: Int; let title: String; let branch: String; let autoMerge: Bool }
        return try json(try await GitHub.list(in: try requireString(a, "folder")).map { Row(number: $0.number, title: $0.title, branch: $0.headRefName, autoMerge: $0.autoMerge) })
    })

    t.append(Tool(name: "start_session", description: "Start a new CPilot session in a folder and optionally send a first message. The user is asked to approve it in CPilot. Access can be read_only, ask_first or edit_files; full access cannot be requested.",
                  properties: ["folder": prop("string", "Working folder."), "message": prop("string", "First message."), "access": prop("string", "Access level.", enumValues: ["readOnly", "askFirst", "editFiles"])],
                  required: ["folder"]) { a in try await control("/v1/start_session", a) })

    t.append(Tool(name: "send_message", description: "Send a message to an existing session. The user is asked to approve it in CPilot.",
                  properties: ["session_id": prop("string", "Session id."), "text": prop("string", "The message.")], required: ["session_id", "text"]) { a in try await control("/v1/send_message", a) })

    t.append(Tool(name: "delete_session", description: "DESTRUCTIVE. Permanently deletes a session and its transcript. `confirm_title` must equal the session's exact title. Ask the user before calling.",
                  properties: ["session_id": prop("string", "Session id."), "confirm_title": prop("string", "Repeat the session's title.")], required: ["session_id", "confirm_title"]) { a in
        let id = try requireString(a, "session_id")
        guard let m = store.load(id) else { throw ToolError(message: "No such session.") }
        guard try requireString(a, "confirm_title") == m.title else { throw ToolError(message: "confirm_title must equal the session title. Nothing was deleted.") }
        store.delete(id)
        return "Deleted \(m.title)."
    })

    return t
}()

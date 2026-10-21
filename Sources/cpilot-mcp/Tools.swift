// SPDX-License-Identifier: MIT

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

// Tool design rules (see references/mcp-agents.md):
//  - Names are verb_noun, read-only tools first. Every tool shares the app's Kit code; no logic is duplicated here.
//  - Output is compact JSON, or short plain text for actions. Never dump unbounded logs: take a `tail`/`limit` argument.
//  - Anything destructive requires an explicit argument that proves intent: `confirm_name` equal to the thing's name
//    for data loss, `confirm: true` for bulk deletes. A missing or wrong value throws; it never "defaults to yes".
let allTools: [Tool] = {
    var t: [Tool] = []

    t.append(Tool(name: "get_status", description: "Report the app's build, version and whether its prerequisites are installed.", properties: [:], required: []) { _ in
        struct Out: Encodable { let version: String; let ready: Bool; let missing: [String] }
        let setup = SetupState.detect()
        return try json(Out(version: BuildInfo.current.version, ready: setup.ready, missing: setup.missing.map(\.title)))
    })

    // Example of a destructive tool. Delete it, or copy the pattern.
    t.append(Tool(name: "delete_thing", description: "DESTRUCTIVE. Deletes a thing by name. `confirm_name` must equal `name`. Ask the user before calling.",
                  properties: ["name": prop("string", "Name of the thing."), "confirm_name": prop("string", "Repeat the name to confirm.")],
                  required: ["name", "confirm_name"]) { a in
        let name = try requireString(a, "name")
        guard try requireString(a, "confirm_name") == name else { throw ToolError(message: "confirm_name must equal name. Nothing was deleted.") }
        return "Deleted \(name)."
    })

    return t
}()

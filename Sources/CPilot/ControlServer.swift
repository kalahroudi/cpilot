// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import AppKit
import CPilotKit

/// A loopback-only control API so the MCP server can ask the running app to start a session or send a message.
/// It listens on 127.0.0.1 with a random port and a random bearer token kept in a file only you can read.
/// Every request that changes anything shows a native approval dialog first and is denied if you do not answer.
@MainActor
final class ControlServer {
    static let shared = ControlServer()
    private var listener: NWListener?
    private var token = ""

    func start() {
        guard listener == nil else { return }
        token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return }
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = l.port?.rawValue { Task { @MainActor in self?.writeControlFile(port: Int(port)) } }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        try? FileManager.default.removeItem(at: AppPaths().controlFile)
    }

    private func writeControlFile(port: Int) {
        let url = AppPaths().controlFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"port":\#(port),"token":"\#(token)","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
        try? json.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                Task { @MainActor in
                    let (code, body) = await self.handle(req)
                    self.respond(conn, code, body)
                }
            } else if done || err != nil || buf.count > 1_000_000 { conn.cancel() }
            else { Task { @MainActor in self.receive(conn, buffer: buf) } }
        }
    }

    struct Request { var path: String; var token: String; var body: [String: Any] }

    nonisolated static func parse(_ data: Data) -> Request? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var length = 0, auth = ""
        for l in lines.dropFirst() {
            let low = l.lowercased()
            if low.hasPrefix("content-length:") { length = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if low.hasPrefix("authorization:") { auth = l.dropFirst(14).trimmingCharacters(in: .whitespaces) }
        }
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        let obj = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] ?? [:]
        return Request(path: String(first[1]), token: auth.replacingOccurrences(of: "Bearer ", with: ""), body: obj)
    }

    private func respond(_ conn: NWConnection, _ code: Int, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let status = code == 200 ? "200 OK" : code == 401 ? "401 Unauthorized" : code == 403 ? "403 Forbidden" : "400 Bad Request"
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Actions

    private func handle(_ r: Request) async -> (Int, [String: Any]) {
        guard !r.token.isEmpty, r.token == token else { return (401, ["error": "Bad token."]) }
        let ws = Workspace.shared
        switch r.path {
        case "/v1/start_session":
            guard let folder = r.body["folder"] as? String, FileManager.default.fileExists(atPath: folder) else { return (400, ["error": "folder is required and must exist."]) }
            let message = (r.body["message"] as? String) ?? ""
            let requested = (r.body["access"] as? String).flatMap(AccessLevel.init(rawValue:)) ?? ws.policy.defaultLevel
            let access: AccessLevel = requested == .fullAccess ? .askFirst : requested      // an outside tool can never switch off approvals
            guard await approve("Another app wants to start a CPilot session", detail: "Folder: \(folder)\nAccess: \(access.label)\n\(message.isEmpty ? "" : "First message: \(message.prefix(200))")") else {
                return (403, ["error": "The user declined."])
            }
            do {
                let c = try await ws.create(.init(folder: folder, access: access, firstMessage: message))
                return (200, ["session_id": c.id, "title": c.meta.title])
            } catch { return (400, ["error": error.localizedDescription]) }
        case "/v1/send_message":
            guard let id = r.body["session_id"] as? String, let text = r.body["text"] as? String, let c = ws.controller(id) else { return (400, ["error": "session_id and text are required."]) }
            guard await approve("Another app wants to send a message", detail: "To: \(c.meta.title)\n\(text.prefix(300))") else { return (403, ["error": "The user declined."]) }
            c.loadIfNeeded(); c.draft = text; c.send()
            return (200, ["ok": true])
        default: return (400, ["error": "Unknown action."])
        }
    }

    /// A native dialog that denies if nobody answers within 90 seconds.
    private func approve(_ title: String, detail: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Deny")
        let timeout = Task { try? await Task.sleep(for: .seconds(90)); if !Task.isCancelled { NSApp.abortModal() } }
        let result = alert.runModal()
        timeout.cancel()
        return result == .alertFirstButtonReturn
    }
}

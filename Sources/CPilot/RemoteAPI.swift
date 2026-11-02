// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// What a paired phone may ask for. Narrower than the Mac on purpose:
/// - sessions it starts are capped at Edit files, run in a worktree of their own, and only in repositories CPilot already knows;
/// - a tool permission can be allowed once, never "always" or for the session, and Full access cannot be switched on;
/// - pushing and merging can be approved only from a device you allowed to, at the Mac;
/// - every start, message and approval is written to the audit log with the device's name.
@MainActor
enum RemoteAPI {
    enum Output { case response(HTTPResponse), events }

    private static func ok(_ o: Any = ["ok": true]) -> Output { .response(.json(200, o)) }
    private static func fail(_ code: Int, _ m: String) -> Output { .response(.error(code, m)) }

    static func route(_ r: HTTPRequest, server: RemoteServer) async -> Output {
        let ws = Workspace.shared
        let parts = r.path.split(separator: "/").map(String.init)

        if r.method == "GET", r.path == "/" { return .response(.html(RemotePage.html)) }
        if r.method == "GET", r.path == "/sw.js" {
            return .response(HTTPResponse(status: 200, contentType: "text/javascript; charset=utf-8", body: Data(RemotePage.serviceWorker.utf8)))
        }
        if r.method == "GET", r.path == "/manifest.json" { return .response(HTTPResponse(status: 200, contentType: "application/manifest+json", body: Data(RemotePage.manifest.utf8))) }
        if r.method == "POST", r.path == "/v1/pair" {
            guard r.headers["x-cpilot"] != nil else { return fail(403, "Missing header.") }
            let body = r.json
            switch server.devices.pair(code: (body["code"] as? String) ?? "", name: (body["name"] as? String) ?? "") {
            case .failure(.locked): return fail(429, "Too many wrong codes. Wait a minute.")
            case .failure(.badCode): return fail(403, "That code is wrong or has expired. Make a new one on the Mac.")
            case .success(let paired):
                ws.audit.record(AuditEntry(session: "remote", tool: "pair", summary: "Paired \(paired.device.name)", outcome: "allowed"))
                AppModel.shared.notify("A phone was paired", body: paired.device.name)
                var resp = HTTPResponse.json(200, ["name": paired.device.name])
                resp.headers["Set-Cookie"] = "cpilot_token=\(paired.token); Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Strict"
                return .response(resp)
            }
        }

        guard let device = server.devices.device(for: r.token) else { return fail(401, "Pair this device first.") }
        if r.method != "GET", r.headers["x-cpilot"] == nil { return fail(403, "Missing header.") }

        func audit(_ session: String, _ what: String) { ws.audit.record(AuditEntry(session: session, tool: "remote", summary: "\(device.name): \(what)", outcome: "allowed")) }

        // "POST /v1/sessions/:id/permissions/:pid": the session and request ids stand in for their segments.
        let id = parts.count > 2 ? parts[2] : "", pid = parts.count > 4 ? parts[4] : ""
        let shape = r.method + " /" + parts.enumerated().map { i, seg in
            (i == 2 && parts.count > 1 && (parts[1] == "sessions" || parts[1] == "approvals")) ? ":id" : (i == 4 ? ":pid" : seg)
        }.joined(separator: "/")

        switch shape {
        case "GET /v1/me":
            let fresh = server.devices.device(id: device.id) ?? device
            var me: [String: Any] = ["name": fresh.name, "canApprove": fresh.canApprove, "push": fresh.push != nil,
                                     "alerts": ["needs": fresh.alertPrefs.needs, "failed": fresh.alertPrefs.failed, "finished": fresh.alertPrefs.finished]]
            if let l = AlertCenter.shared.last[device.id] { me["lastAlert"] = "\(l.result) at \(l.at.formatted(date: .omitted, time: .shortened))" }
            return ok(me)

        case "GET /v1/push/key":
            return ok(["key": server.vapid.publicKey])

        case "POST /v1/push/subscribe":
            let body = r.json, keys = body["keys"] as? [String: Any]
            let sub = PushSubscription(endpoint: (body["endpoint"] as? String) ?? "", p256dh: (keys?["p256dh"] as? String) ?? "", auth: (keys?["auth"] as? String) ?? "")
            guard sub.isAcceptable(allowLoopback: ProcessInfo.processInfo.environment["CPILOT_REMOTE_LOCAL"] != nil) else { return fail(400, "That is not a push subscription CPilot can use.") }
            server.devices.setPush(device.id, sub)
            audit("push", "turned on alerts")
            return ok()

        case "POST /v1/push/unsubscribe":
            server.devices.setPush(device.id, nil)
            audit("push", "turned off alerts")
            return ok()

        case "POST /v1/push/prefs":
            let b = r.json
            let old = (server.devices.device(id: device.id) ?? device).alertPrefs
            server.devices.setAlerts(device.id, AlertPrefs(needs: (b["needs"] as? Bool) ?? old.needs, failed: (b["failed"] as? Bool) ?? old.failed, finished: (b["finished"] as? Bool) ?? old.finished))
            return ok()

        case "POST /v1/presence":
            server.devices.setPresent(device.id, (r.json["visible"] as? Bool) == true)
            return ok()

        case "POST /v1/push/test":
            guard let base = server.url, let d = server.devices.device(id: device.id), d.push != nil else { return fail(400, "Alerts are not turned on for this device.") }
            // After a few seconds, so there is time to lock the phone or switch to another app: a page that is open may not show a banner.
            let message = AlertCenter.payload(title: "CPilot test", body: "Alerts work on this device.", tag: "test-\(UUID().uuidString.prefix(6))", url: "/")
            Task { try? await Task.sleep(for: .seconds(5)); await AlertCenter.shared.send(message, to: d, subject: base.absoluteString) }
            return ok(["inSeconds": 5])
        case "GET /v1/state":
            return .response(HTTPResponse(status: 200, contentType: "application/json", body: Data(stateJSON().utf8)))
        case "GET /v1/events":
            return .events
        case "POST /v1/logout":
            server.devices.revoke(device.id)
            return ok()

        case "GET /v1/sessions/:id/messages":
            guard ws.sessions.contains(where: { $0.id == id }), let c = ws.controller(id) else { return fail(404, "No such session.") }
            let after = Int(r.query["after"] ?? "") ?? 0
            let rows = c.loaded ? c.items : ws.store.items(id, limit: 300)
            return ok(["total": rows.count, "items": rows.enumerated().filter { $0.offset >= after && $0.element.kind != ChatItem.Kind.thinking }.map { row($0.offset, $0.element) }])

        case "POST /v1/sessions":
            return await startSession(r.json, device: device, server: server)

        case "POST /v1/sessions/:id/messages":
            guard let c = ws.controller(id), ws.sessions.contains(where: { $0.id == id }) else { return fail(404, "No such session.") }
            let text = ((r.json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail(400, "text is required.") }
            c.loadIfNeeded(); c.draft = String(text.prefix(20_000)); c.send()
            audit(id, "message to \(c.meta.title)")
            return ok()

        case "POST /v1/sessions/:id/stop":
            guard let c = ws.controller(id), ws.sessions.contains(where: { $0.id == id }) else { return fail(404, "No such session.") }
            c.interrupt()
            audit(id, "stopped \(c.meta.title)")
            return ok()

        case "POST /v1/sessions/:id/permissions/:pid":
            guard let c = ws.controller(id), c.pending.contains(where: { $0.id == pid }) else { return fail(404, "That request is already answered.") }
            let allow = (r.json["allow"] as? Bool) == true
            c.resolve(pid, allow: allow, scope: .once)      // once only: "always" and "this session" stay at the Mac
            audit(id, "\(allow ? "allowed" : "denied") a tool request in \(c.meta.title)")
            return ok()

        case "POST /v1/approvals/:id":
            guard let req = ApprovalBroker.shared.pending.first(where: { $0.id == id }) else { return fail(404, "That request is already answered.") }
            let allow = (r.json["allow"] as? Bool) == true
            if allow, req.high, !device.canApprove { return fail(403, "This device may not approve pushes and merges. Allow it in CPilot, Settings, Remote.") }
            ApprovalBroker.shared.answer(id, allow: allow)
            audit("approval", "\(allow ? "allowed" : "denied"): \(req.title)")
            return ok()

        case "POST /v1/chief":
            let body = r.json
            guard let dir = body["repo"] as? String, repos().contains(where: { $0.dir == dir }) else { return fail(400, "Unknown repository.") }
            let text = ((body["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let c = try await ws.openChief(repo: dir, environment: nil)
                if !text.isEmpty { c.loadIfNeeded(); c.draft = String(text.prefix(20_000)); c.send() }
                audit(c.id, "chief pilot: \(text.prefix(80))")
                return ok(["session_id": c.id])
            } catch { return fail(400, error.localizedDescription) }

        default:
            return fail(404, "Not found.")
        }
    }

    // MARK: Starting a session

    private static func startSession(_ body: [String: Any], device: RemoteDevice, server: RemoteServer) async -> Output {
        let ws = Workspace.shared
        guard let dir = body["repo"] as? String, repos().contains(where: { $0.dir == dir }) else { return fail(400, "Pick one of the repositories CPilot knows.") }
        let prompt = ((body["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return fail(400, "prompt is required.") }
        guard server.devices.allowStart(device: device.id) else { return fail(429, "This device started too many sessions this hour.") }
        let agent = (body["agent"] as? String) ?? "claude"
        let backend: Backend = agent == "claude" ? .claude : (ws.acpAgents.contains { $0.id == agent } ? .acp(agent) : .claude)
        let wanted = (body["access"] as? String).flatMap(AccessLevel.init(rawValue:)) ?? .editFiles
        let access: AccessLevel = wanted == .fullAccess ? .editFiles : wanted
        let title = String(prompt.split(separator: "\n").first?.prefix(60) ?? "Phone session")
        do {
            let c = try await ws.create(.init(folder: dir, backend: backend, access: access, branch: "phone/" + slug(title), useWorktree: true, firstMessage: prompt, title: title))
            ws.audit.record(AuditEntry(session: c.id, tool: "remote", summary: "\(device.name): started \(title)", outcome: "allowed"))
            AppModel.shared.notify("\(device.name) started a session", body: title)
            return ok(["session_id": c.id])
        } catch { return fail(400, error.localizedDescription) }
    }

    static func slug(_ s: String) -> String {
        let t = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(t).split(separator: "-").prefix(6).joined(separator: "-")
        return joined.isEmpty ? "session" : joined
    }

    /// Repositories on this Mac that CPilot already knows. A phone cannot name a folder CPilot has not seen.
    static func repos() -> [PRCenter.Repo] { Project.shared.repos().filter { $0.environment == nil } }

    // MARK: State

    private static func row(_ i: Int, _ it: ChatItem) -> [String: Any] {
        var o: [String: Any] = ["i": i, "id": it.id, "kind": it.kind.rawValue, "text": String(it.text.prefix(8000))]
        if let t = it.title { o["title"] = t }
        if let d = it.detail { o["detail"] = String(d.prefix(300)) }
        if let s = it.status { o["status"] = s.rawValue }
        return o
    }

    static func stateJSON() -> String {
        let ws = Workspace.shared
        let sessions: [[String: Any]] = ws.sessions.filter { !$0.archived && $0.environment == nil }.sorted { $0.updatedAt > $1.updatedAt }.prefix(40).map { m in
            let c = ws.controller(m.id)
            var group = "idle"
            if let c {
                if !c.pending.isEmpty { group = "approval" }
                else if case .failed = c.state { group = "failed" }
                else if c.isBusy { group = "working" }
            }
            var o: [String: Any] = ["id": m.id, "title": m.title, "repo": URL(fileURLWithPath: m.cwd).lastPathComponent, "group": group,
                                    "updated": Int(m.updatedAt.timeIntervalSince1970), "chief": m.chief == true, "access": m.access.label]
            if let b = m.branch { o["branch"] = b }
            if let n = m.reviewOf { o["review"] = n }
            // Changes while an answer streams in, so an open session on a phone refreshes as the text grows.
            if let c, c.loaded { o["rev"] = (c.items.count << 20) ^ (c.items.last?.text.count ?? 0) }
            if let c, !c.pending.isEmpty {
                o["permissions"] = c.pending.map { ["id": $0.id, "tool": $0.request.tool, "summary": String($0.request.summary.prefix(300)), "path": $0.request.path ?? ""] }
            }
            return o
        }
        let state: [String: Any] = [
            "approvals": ApprovalBroker.shared.pending.map { ["id": $0.id, "title": $0.title, "detail": $0.detail, "high": $0.high] },
            "sessions": sessions,
            "repos": repos().map { ["dir": $0.dir, "name": URL(fileURLWithPath: $0.dir).lastPathComponent] },
            "agents": [["id": "claude", "name": "Claude"]] + ws.acpAgents.map { ["id": $0.id, "name": $0.name] },
            "chiefMode": Prefs.shared.chiefAutonomy,
        ]
        return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

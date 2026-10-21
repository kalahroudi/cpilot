// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit
@preconcurrency import UserNotifications

/// One open session: its chat rows, the running agent process (if any) and any approvals waiting for the user.
/// A tab that is not selected keeps no rows in memory, and an idle tab stops its process; both come back on demand.
@MainActor @Observable
final class SessionController: Identifiable {
    enum RunState: Equatable { case asleep, idle, running, waiting, failed(String) }
    enum GrantScope { case once, session, project }
    struct Pending: Identifiable {
        enum Source { case claude(PermissionRequest), acp(AcpPermission) }
        let id: String
        let source: Source
        var request: PermissionRequest
    }

    let id: String
    var meta: SessionMeta
    var items: [ChatItem] = []
    var draft = ""
    var attachments: [Attachment] = []
    var state: RunState = .asleep
    var pending: [Pending] = []
    var cost: Double = 0
    var loaded = false

    private let ws: Workspace
    private var runner: ClaudeRunner?
    private var parser = ClaudeStreamParser()
    private var acp: AcpClient?
    private var acpSession: String?
    private var sessionGrants: Set<String> = []
    private var sleepTask: Task<Void, Never>?
    private var stoppedOnPurpose = false

    init(meta: SessionMeta, workspace: Workspace) { self.meta = meta; self.id = meta.id; self.ws = workspace }

    var isBusy: Bool { state == .running || state == .waiting }
    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        var rows = ws.store.items(id)
        // After a crash or a quit mid-reply, rows can be left "running" or waiting for an approval that no longer exists.
        var repaired = false
        for i in rows.indices {
            if rows[i].status == .running { rows[i].status = rows[i].kind == .tool ? .failed : .done; repaired = true; ws.store.append(rows[i], to: id) }
            else if rows[i].kind == .permission, rows[i].status == .pending { rows[i].status = .denied; rows[i].detail = "interrupted"; repaired = true; ws.store.append(rows[i], to: id) }
        }
        if repaired { rows.append(ChatItem(kind: .notice, text: "CPilot was closed while this was running. The conversation is intact; send a message to continue.", status: .done)) }
        items = rows; loaded = true
        if draft.isEmpty, let d = meta.draft { draft = d }
    }

    // MARK: Crash safety. Final rows are appended to disk as they complete; a reply that is still streaming is checkpointed
    // every couple of seconds; the draft is saved as you type. Claude keeps its own copy of the conversation, so resuming by id
    // restores the agent's context even if CPilot's copy of the last few seconds is lost.
    private var lastCheckpoint = Date.distantPast
    private var draftTask: Task<Void, Never>?

    private func checkpoint(_ item: ChatItem) {
        guard Date().timeIntervalSince(lastCheckpoint) > 2 else { return }
        lastCheckpoint = .now
        ws.store.append(item, to: id)
    }

    func saveDraftSoon() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.flush() }
        }
    }

    /// Writes everything that is only in memory: the draft and the session record.
    func flush() {
        let text = draft.isEmpty ? nil : draft
        if meta.draft != text { meta.draft = text; ws.save(meta) }
    }

    /// Frees the rows of a tab nobody is looking at.
    func unloadIfIdle() {
        guard !isBusy, loaded, ws.selected != id else { return }
        items = []; loaded = false
    }

    // MARK: Sending

    func send() {
        guard canSend, !isBusy else { return }
        loadIfNeeded()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        draft = ""; attachments = []; meta.draft = nil
        let composed = Capture.compose(message: text, attachments: atts)
        let row = ChatItem(kind: .user, text: text, attachments: atts, ts: .now)
        items.append(row); ws.store.append(row, to: id)
        if meta.title == "New session" { meta.title = String(text.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines) }
        meta.updatedAt = .now; ws.save(meta)
        state = .running
        sleepTask?.cancel()
        switch meta.backend.kind {
        case .claude: sendClaude(composed.text, composed.images)
        case .acp: sendAcp(composed.text, composed.images)
        }
    }

    func interrupt() {
        switch meta.backend.kind {
        case .claude: runner?.send(ClaudeWire.interrupt())
        case .acp: if let s = acpSession { acp?.cancel(sessionId: s) }
        }
        for p in pending { resolve(p.id, allow: false, scope: .once, note: "Stopped") }
    }

    // MARK: Claude

    private func ensureRunner() throws -> ClaudeRunner {
        if let r = runner, r.isRunning { return r }
        var c = ClaudeRunner.Config(cwd: meta.workingDirectory)
        c.resumeId = meta.remoteId
        c.model = meta.model
        c.access = ws.policy.level(for: meta)
        c.appendSystemPrompt = ws.memory.context(forProject: meta.cwd)
        if Prefs.shared.memoryEngine == "engine" { c.mcpConfigPath = MemoryEngine.claudeConfig(base: Prefs.shared.memoryEngineURL, bank: MemoryEngine.bank(forProject: meta.cwd)) }
        let r = ClaudeRunner(config: c, onLine: { [weak self] line in
            Task { @MainActor in self?.handle(line: line) }
        }, onExit: { [weak self] status in
            Task { @MainActor in self?.runnerExited(status) }
        })
        parser = ClaudeStreamParser()
        stoppedOnPurpose = false
        try r.start()
        runner = r
        return r
    }

    private func sendClaude(_ text: String, _ images: [(mediaType: String, data: Data)]) {
        do {
            let r = try ensureRunner()
            r.send(ClaudeWire.userMessage(text: text, images: images))
        } catch {
            fail(UserError.message(for: error, action: "Start Claude"))
        }
    }

    private func handle(line: String) {
        for ev in parser.parse(line: line) {
            switch ev {
            case .initialized(let sid, _):
                if meta.remoteId != sid { meta.remoteId = sid; ws.save(meta) }
            case .item(let item):
                items.upsert(item)
                if item.status != .running { ws.store.append(item, to: id) } else { checkpoint(item) }
            case .permission(let req):
                handlePermission(PermissionRequestEnvelope(source: .claude(req), request: req))
            case .turnEnded(let isError, let text, let cost):
                if let c = cost { self.cost += c }
                if isError, let t = text, !t.isEmpty { addNotice(t, error: true) }
                finishTurn()
            }
        }
    }

    private func runnerExited(_ status: Int32) {
        let tail = runner?.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        runner = nil
        if stoppedOnPurpose { state = .asleep; return }
        if state == .running || state == .waiting {
            fail(tail.isEmpty ? "Claude stopped unexpectedly (status \(status))." : tail)
        } else { state = .asleep }
        pending.removeAll()
    }

    // MARK: ACP

    private func sendAcp(_ text: String, _ images: [(mediaType: String, data: Data)]) {
        Task { @MainActor in
            do {
                let (client, session) = try await ensureAcp()
                _ = try await client.prompt(sessionId: session, text: text, images: images)
                finishTurn()
            } catch {
                fail(UserError.message(for: error, action: "Talk to the agent"))
            }
        }
    }

    private func ensureAcp() async throws -> (AcpClient, String) {
        if let c = acp, c.isRunning, let s = acpSession { return (c, s) }
        guard let id = meta.backend.acpAgent, let cfg = ws.acpAgents.first(where: { $0.id == id }) else {
            throw ShellError.failed(command: "agent", status: 1, stderr: "This agent is no longer configured. Add it again in Settings → Agents.")
        }
        let client = AcpClient(config: cfg, cwd: URL(fileURLWithPath: meta.workingDirectory)) { [weak self] ev in
            Task { @MainActor in self?.handle(acp: ev) }
        }
        if Prefs.shared.memoryEngine == "engine" { client.mcpServers = MemoryEngine.acpServers(base: Prefs.shared.memoryEngineURL, bank: MemoryEngine.bank(forProject: meta.cwd)) }
        try await client.start()
        let session: String
        if let rid = meta.remoteId { session = try await client.loadSession(rid) } else { session = try await client.newSession() }
        acp = client; acpSession = session
        if meta.remoteId != session { meta.remoteId = session; ws.save(meta) }
        return (client, session)
    }

    private func handle(acp ev: AcpEvent) {
        switch ev {
        case .items(let list):
            for item in list { items.upsert(item); if item.status != .running { ws.store.append(item, to: id) } else { checkpoint(item) } }
        case .permission(let p):
            let tool: String = switch p.detail { case "read", "search", "fetch", "think": "Read"; case "edit", "delete", "move": "Edit"; default: "Bash" }
            let req = PermissionRequest(id: p.id, tool: tool, summary: p.title, input: "{}", path: p.path)
            handlePermission(PermissionRequestEnvelope(source: .acp(p), request: req))
        case .exited:
            acp = nil; acpSession = nil
            if state == .running || state == .waiting { fail("The agent stopped unexpectedly.") } else { state = .asleep }
        }
    }

    // MARK: Approvals

    struct PermissionRequestEnvelope { let source: Pending.Source; let request: PermissionRequest }

    private func handlePermission(_ e: PermissionRequestEnvelope) {
        let decision = ws.policy.decide(e.request, session: meta, sessionGrants: sessionGrants)
        switch decision {
        case .allow(let reason):
            answer(e, allow: true, always: false)
            ws.audit.record(AuditEntry(session: id, tool: e.request.tool, summary: e.request.summary, outcome: "allowed (\(reason))"))
        case .deny(let reason):
            answer(e, allow: false, always: false, message: reason)
            ws.audit.record(AuditEntry(session: id, tool: e.request.tool, summary: e.request.summary, outcome: "denied (\(reason))"))
        case .ask:
            let row = ChatItem(id: "perm-" + e.request.id, kind: .permission, text: e.request.summary, title: e.request.tool,
                               detail: e.request.path, status: .pending)
            items.upsert(row)
            pending.append(Pending(id: e.request.id, source: e.source, request: e.request))
            state = .waiting
            ws.notifyApproval(session: meta.title, summary: e.request.summary)
        }
    }

    func resolve(_ requestId: String, allow: Bool, scope: GrantScope, note: String? = nil) {
        guard let p = pending.first(where: { $0.id == requestId }) else { return }
        pending.removeAll { $0.id == requestId }
        let env = PermissionRequestEnvelope(source: p.source, request: p.request)
        answer(env, allow: allow, always: allow && scope != .once, message: note ?? "The user declined this action.")
        if allow {
            if scope == .session { sessionGrants.insert(AccessPolicy.grantKey(p.request)) }
            if scope == .project, p.request.tool == "Bash" {
                let prefix = p.request.summary.split(separator: " ").prefix(2).joined(separator: " ")
                ws.addProjectCommand(prefix, for: meta.cwd)
            }
        }
        let outcome = !allow ? "denied" : scope == .once ? "allowed once" : scope == .session ? "allowed for session" : "allowed for project"
        ws.audit.record(AuditEntry(session: id, tool: p.request.tool, summary: p.request.summary, outcome: outcome))
        if var row = items.last(where: { $0.id == "perm-" + requestId }) {
            row.status = allow ? .allowed : .denied; row.detail = outcome
            items.upsert(row); ws.store.append(row, to: id)
        }
        if pending.isEmpty, state == .waiting { state = .running }
    }

    private func answer(_ e: PermissionRequestEnvelope, allow: Bool, always: Bool, message: String = "Denied.") {
        switch e.source {
        case .claude(let req):
            runner?.send(allow ? ClaudeWire.allow(requestId: req.id, updatedInput: req.input) : ClaudeWire.deny(requestId: req.id, message: message))
        case .acp(let p):
            let opt = allow ? (always ? (p.allowAlways ?? p.allowOnce) : p.allowOnce) : p.rejectOnce
            acp?.answer(permission: p.id, optionId: opt?.id)
        }
    }

    // MARK: Life cycle

    private func finishTurn() {
        if case .failed = state {} else { state = pending.isEmpty ? .idle : .waiting }
        meta.updatedAt = .now; ws.save(meta)
        ws.turnFinished(self)
        scheduleSleep()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        addNotice(message, error: true)
    }

    func addNotice(_ text: String, error: Bool = false) {
        let row = ChatItem(kind: error ? .error : .notice, text: text, status: error ? .failed : .done)
        items.append(row); ws.store.append(row, to: id)
    }

    private func scheduleSleep() {
        sleepTask?.cancel()
        let minutes = max(1, Prefs.shared.sleepMinutes)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            if !Task.isCancelled { self?.sleep() }
        }
    }

    /// Stops the agent process. The session keeps its id, so the next message resumes it with full context.
    func sleep() {
        guard !isBusy else { return }
        stoppedOnPurpose = true
        runner?.stop(); runner = nil
        acp?.stop(); acp = nil; acpSession = nil
        sleepTask?.cancel()
        state = .asleep
        unloadIfIdle()
    }

    /// Changing access restarts the agent with the new permission mode; the conversation continues.
    func setAccess(_ level: AccessLevel) {
        meta.access = level; ws.save(meta)
        if !isBusy { sleep() } else { addNotice("Access changes after the current turn.") }
    }

    /// Hands the session to Terminal: the same session id, so the conversation continues there with full context.
    func openInTerminal() {
        guard meta.backend.kind == .claude, let rid = meta.remoteId else { return }
        let cmd = "cd \(shellQuote(meta.workingDirectory)) && claude --resume \(rid)"
        sleep()
        let script = "tell application \"Terminal\" to do script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\ntell application \"Terminal\" to activate"
        Task { _ = try? await Shell.run("/usr/bin/osascript", ["-e", script]) }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func close() {
        flush()
        stoppedOnPurpose = true
        runner?.stop(); acp?.stop(); sleepTask?.cancel()
    }
}

/// App-wide state for sessions: the list, the open tabs, the policy. Idle costs nothing: there are no timers here.
@MainActor @Observable
final class Workspace {
    static let shared = Workspace()

    let store = SessionStore()
    let memory = MemoryStore()
    let audit = AuditLog()
    var policy = AccessPolicy.load()
    var acpAgents = AcpAgentConfig.load()
    var sessions: [SessionMeta] = []
    var tabs: [String] = []
    var selected: String?
    private var controllers: [String: SessionController] = [:]

    private init() {
        sessions = store.list()
        let saved = UserDefaults.standard.stringArray(forKey: "openTabs") ?? []
        tabs = saved.filter { id in sessions.contains { $0.id == id } }
        selected = UserDefaults.standard.string(forKey: "selectedTab").flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
    }

    /// Screenshots only: registers controllers for made-up sessions.
    func demoControllers(_ metas: [SessionMeta]) { for m in metas { controllers[m.id] = SessionController(meta: m, workspace: self) } }

    func controller(_ id: String) -> SessionController? {
        if let c = controllers[id] { return c }
        guard let m = sessions.first(where: { $0.id == id }) ?? store.load(id) else { return nil }
        let c = SessionController(meta: m, workspace: self)
        controllers[id] = c
        return c
    }

    var current: SessionController? { selected.flatMap(controller) }
    var attention: Int { controllers.values.filter { !$0.pending.isEmpty }.count }
    var runningCount: Int { controllers.values.filter(\.isBusy).count }
    var live: [SessionController] { controllers.values.sorted { $0.meta.updatedAt > $1.meta.updatedAt } }

    func save(_ m: SessionMeta) {
        store.save(m)
        if let i = sessions.firstIndex(where: { $0.id == m.id }) { sessions[i] = m } else { sessions.insert(m, at: 0) }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    func select(_ id: String) {
        let previous = selected
        selected = id
        if !tabs.contains(id) { tabs.append(id) }
        controller(id)?.loadIfNeeded()
        if let p = previous, p != id { controllers[p]?.unloadIfIdle() }
        persistTabs()
    }

    func closeTab(_ id: String) {
        controllers[id]?.close(); controllers[id] = nil
        tabs.removeAll { $0 == id }
        if selected == id { selected = tabs.last; if let s = selected { controller(s)?.loadIfNeeded() } }
        persistTabs()
    }

    func delete(_ id: String) {
        closeTab(id)
        if let m = sessions.first(where: { $0.id == id }), let wt = m.worktree { Task { await Git.removeWorktree(repo: m.cwd, path: wt) } }
        store.delete(id)
        sessions.removeAll { $0.id == id }
    }

    /// Called when CPilot quits: saves every draft and stops every agent, so nothing is left running or unsaved.
    func flushAll() {
        for c in controllers.values { c.flush(); c.close() }
        persistTabs()
    }

    private func persistTabs() {
        UserDefaults.standard.set(tabs, forKey: "openTabs")
        UserDefaults.standard.set(selected, forKey: "selectedTab")
    }

    // MARK: Creating sessions

    struct NewSession {
        var folder: String
        var backend: Backend = .claude
        var model: String?
        var access: AccessLevel
        var branch: String?
        var useWorktree = false
        var firstMessage = ""
    }

    @discardableResult
    func create(_ n: NewSession) async throws -> SessionController {
        var meta = SessionMeta(title: "New session", cwd: n.folder, backend: n.backend, model: n.model, access: n.access)
        if let branch = n.branch, !branch.isEmpty, await Git.isRepo(n.folder) {
            if n.useWorktree {
                let path = AppPaths().root.appendingPathComponent("worktrees/\(meta.id)").path
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try await Git.addWorktree(repo: n.folder, branch: branch, base: await Git.defaultBranch(n.folder), to: path)
                meta.worktree = path
            } else {
                let current = await Git.info(n.folder)?.branch
                if current != branch { _ = try? await Shell.run("git", ["checkout", "-b", branch], cwd: URL(fileURLWithPath: n.folder)) }
            }
            meta.branch = branch
        }
        save(meta)
        let c = controller(meta.id)!
        c.loaded = true
        select(meta.id)
        if !n.firstMessage.isEmpty { c.draft = n.firstMessage; c.send() }
        return c
    }

    // MARK: Policy and agents

    func savePolicy() { policy.save() }

    func addProjectCommand(_ prefix: String, for folder: String) {
        if let i = policy.rules.firstIndex(where: { $0.path == folder }) {
            if !policy.rules[i].allowCommands.contains(prefix) { policy.rules[i].allowCommands.append(prefix) }
        } else { policy.rules.append(AccessRule(path: folder, allowCommands: [prefix])) }
        savePolicy()
    }

    func saveAgents() { AcpAgentConfig.save(acpAgents) }

    // MARK: Notifications

    func notifyApproval(session: String, summary: String) {
        guard Prefs.shared.notify, Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent(); c.title = "\(session) needs approval"; c.body = summary
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    func turnFinished(_ c: SessionController) {
        AppModel.shared.updateStatusIcon()
        guard Prefs.shared.notify, Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        AppModel.shared.notify("\(c.meta.title) finished")
    }
}

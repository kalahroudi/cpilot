// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit
@preconcurrency import UserNotifications

/// One open session: its chat rows, the running agent process (if any) and any approvals waiting for the user.
/// A tab that is not selected keeps no rows in memory, and an idle tab stops its process; both come back on demand.
@MainActor @Observable
final class SessionController: Identifiable {
    enum RunState: Equatable { case asleep, idle, running, waiting, reconnecting, failed(String) }
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
    /// Called after each finished turn; spec tasks use it to know when their agent is done.
    var onTurnEnd: ((SessionController) -> Void)?
    /// The "while you were away" card is showing.
    var recapVisible = false
    var recapBusy = false

    private let ws: Workspace
    private var runner: ClaudeRunner?
    private var parser = ClaudeStreamParser()
    private var acp: AcpClient?
    private var acpSession: String?
    private var sessionGrants: Set<String> = []
    private var sleepTask: Task<Void, Never>?
    private var stoppedOnPurpose = false

    init(meta: SessionMeta, workspace: Workspace) { self.meta = meta; self.id = meta.id; self.ws = workspace }

    var isBusy: Bool { state == .running || state == .waiting || state == .reconnecting }
    /// The server this session runs on, or nil for this Mac.
    var env: EnvironmentConfig? { ws.environment(meta.environment) }
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
        let lines = runner?.linesReceived
        if meta.draft != text || (lines != nil && meta.remoteLines != lines) { meta.draft = text; if let lines { meta.remoteLines = lines }; ws.save(meta) }
    }

    /// Frees the rows of a tab nobody is looking at.
    func unloadIfIdle() {
        guard !isBusy, loaded, ws.selected != id else { return }
        items = []; loaded = false
    }

    // MARK: Recap. A short "where things stand" for when you come back: built instantly from the transcript,
    // then rewritten by Claude in a few friendlier lines. It is prepared when a tab falls asleep, so it is ready when you return.

    func refreshRecap(force: Bool = false) {
        loadIfNeeded()
        let parts = Recap.parts(items)
        guard !parts.isEmpty else { return }
        if !force, meta.recapRows == items.count, meta.recap != nil { return }
        meta.recap = Recap.text(parts); meta.recapHeadline = Recap.headline(parts); meta.recapRows = items.count
        ws.save(meta)
        guard Prefs.shared.recapWithClaude, Shell.find("claude") != nil else { return }
        recapBusy = true
        let digest = ContextDigest.build(items: items, budget: 8000), dir = env == nil ? meta.workingDirectory : NSHomeDirectory(), rows = items.count
        Task { @MainActor in
            let out = await ClaudeOneShot.run(Recap.prompt(digest: digest), in: dir)
            recapBusy = false
            if let out, meta.recapRows == rows { meta.recap = out; ws.save(meta) }
        }
    }

    /// Called when you open a session: if you have been away a while, show the recap.
    func showRecapIfAway() {
        guard Prefs.shared.recapAuto, !isBusy, !items.isEmpty, Recap.isDue(lastActivity: meta.updatedAt), meta.recapSeenAt.map({ $0 < meta.updatedAt }) ?? true else { return }
        refreshRecap(); recapVisible = true
    }

    func dismissRecap() { recapVisible = false; meta.recapSeenAt = .now; ws.save(meta) }

    // MARK: Sending

    func send() {
        guard canSend, !isBusy else { return }
        loadIfNeeded()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        draft = ""; attachments = []; meta.draft = nil; recapVisible = false
        let composed = Capture.compose(message: text, attachments: atts)
        let isFirst = !items.contains { $0.kind == .user }
        let row = ChatItem(kind: .user, text: text, attachments: atts, ts: .now)
        items.append(row); ws.store.append(row, to: id); ws.retain(row, in: meta)
        if meta.title == "New session" { meta.title = String(text.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines) }
        meta.updatedAt = .now; ws.save(meta)
        state = .running
        sleepTask?.cancel()
        Task { @MainActor in
            var body = composed.text
            if isFirst, !text.isEmpty, let r = await ws.recall(for: text, in: meta) {
                body = r.prefix + body
                let note = ChatItem(kind: .notice, text: "Recalled earlier context from \(r.sources.joined(separator: ", ")).", status: .done)
                items.append(note); ws.store.append(note, to: id)
            }
            switch meta.backend.kind {
            case .claude: await sendClaude(body, composed.images)
            case .acp: sendAcp(body, composed.images)
            }
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

    private func ensureRunner(attachFrom: Int? = nil) async throws -> ClaudeRunner {
        if let r = runner, r.isRunning { return r }
        var c = ClaudeRunner.Config(cwd: meta.workingDirectory)
        c.resumeId = meta.remoteId
        c.fork = meta.forkPending == true
        c.model = meta.model
        c.access = ws.policy.level(for: meta)
        c.appendSystemPrompt = ws.memory.context(forProject: meta.cwd)
        if Prefs.shared.memoryEngine == "engine", env == nil { c.mcpConfigPath = MemoryEngine.claudeConfig(base: Prefs.shared.memoryEngineURL, bank: MemoryEngine.bank(forProject: meta.cwd)) }
        if let env {
            // On a server. A server-held agent that is still running is joined, not started again.
            if env.persistent {
                var attach = attachFrom != nil, from = attachFrom ?? 0
                if attachFrom == nil, await Exec.with(env, { await RemoteHost.status(id: meta.id) })?.running == true { attach = true; from = meta.remoteLines ?? 0 }
                if !attach { meta.remoteLines = 0 }
                c.transport = .daemon(env, key: meta.id, attachOnly: attach, fromLine: from)
            } else { c.transport = .ssh(env) }
        }
        let r = ClaudeRunner(config: c, onLine: { [weak self] line in
            Task { @MainActor in self?.handle(line: line) }
        }, onExit: { [weak self] status in
            Task { @MainActor in self?.runnerExited(status) }
        })
        parser = ClaudeStreamParser()
        stoppedOnPurpose = false
        try await r.start()
        runner = r
        return r
    }

    private func sendClaude(_ text: String, _ images: [(mediaType: String, data: Data)]) async {
        do {
            let r = try await ensureRunner()
            r.send(ClaudeWire.userMessage(text: takeHandoff() + text, images: images))
        } catch {
            fail(AppModel.shared.capture(error, action: "Start Claude"))
        }
    }

    private func handle(line: String) {
        for ev in parser.parse(line: line) {
            switch ev {
            case .initialized(let sid, _):
                if meta.remoteId != sid || meta.forkPending == true { meta.remoteId = sid; meta.forkPending = nil; ws.save(meta) }
            case .item(let item):
                items.upsert(item)
                if item.status != .running { ws.store.append(item, to: id); ws.retain(item, in: meta) } else { checkpoint(item) }
            case .permission(let req):
                handlePermission(PermissionRequestEnvelope(source: .claude(req), request: req))
            case .turnEnded(let isError, let text, let cost):
                if let c = cost { self.cost += c }
                if let n = runner?.linesReceived { meta.remoteLines = n }
                if isError, let t = text, !t.isEmpty { addNotice(t, error: true) }
                finishTurn()
            }
        }
    }

    private func runnerExited(_ status: Int32) {
        let tail = runner?.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seen = runner?.linesReceived ?? meta.remoteLines ?? 0
        runner = nil
        if stoppedOnPurpose { state = .asleep; return }
        // A server-held agent outlives the connection: find out whether it is still there and join it again.
        if let env, env.persistent { Task { await reconnect(env, seen: seen) }; return }
        if state == .running || state == .waiting {
            let hint = env != nil ? " The session is saved; send a message to resume it." : ""
            fail((tail.isEmpty ? "Claude stopped unexpectedly (status \(status))." : tail) + hint)
        } else { state = .asleep }
        pending.removeAll()
    }

    private var announcedReconnect = false

    /// Joins the agent on the server again, with backoff, and catches up on anything it did while we were away.
    private func reconnect(_ env: EnvironmentConfig, seen: Int) async {
        meta.remoteLines = seen
        var delay = 2.0
        for _ in 0..<14 {
            if stoppedOnPurpose { return }
            let st = await Exec.with(env) { await RemoteHost.status(id: meta.id) }
            if let st {
                if st.running || (st.lines ?? 0) > (meta.remoteLines ?? 0) {
                    if state != .reconnecting, st.running { state = .reconnecting }
                    if !announcedReconnect, st.running { announcedReconnect = true; addNotice("The connection dropped. Reconnecting to the agent on \(env.name)…") }
                    do {
                        _ = try await ensureRunner(attachFrom: meta.remoteLines ?? 0)
                        announcedReconnect = false
                        if st.running { state = pending.isEmpty ? .running : .waiting }
                        return
                    } catch { /* try again below */ }
                } else {
                    // Finished while we were away and everything was already replayed.
                    pending.removeAll()
                    if st.exit == nil || st.exit == 0, st.error == nil { state = .asleep } else { fail(st.error ?? "The agent stopped on \(env.name) (exit \(st.exit ?? -1)).") }
                    return
                }
            }
            state = .reconnecting
            try? await Task.sleep(for: .seconds(delay)); delay = min(delay * 2, 60)
        }
        fail("Lost the connection to \(env.name). Your session is safe; send a message to reconnect.")
    }

    /// The summary of earlier work, used once, before the first message of a session that continues something.
    private func takeHandoff() -> String {
        guard let h = meta.handoff else { return "" }
        meta.handoff = nil; ws.save(meta)
        return h + "\n\n---\n\n"
    }

    // MARK: ACP

    private func sendAcp(_ text: String, _ images: [(mediaType: String, data: Data)]) {
        Task { @MainActor in
            do {
                let fresh = meta.remoteId == nil
                let (client, session) = try await ensureAcp()
                // ACP has no system prompt, so a new session's notes ride along with its first message.
                var prefix = takeHandoff()
                if fresh, let notes = ws.memory.context(forProject: meta.cwd) { prefix += notes + "\n\n---\n\n" }
                _ = try await client.prompt(sessionId: session, text: prefix + text, images: images)
                finishTurn()
            } catch {
                fail(AppModel.shared.capture(error, action: "Talk to the agent"))
            }
        }
    }

    private func ensureAcp() async throws -> (AcpClient, String) {
        if let c = acp, c.isRunning, let s = acpSession { return (c, s) }
        guard let id = meta.backend.acpAgent, let cfg = ws.acpAgents.first(where: { $0.id == id }) else {
            throw ShellError.failed(command: "agent", status: 1, stderr: "This agent is no longer configured. Add it again in Settings → Agents.")
        }
        let client = AcpClient(config: cfg, cwd: URL(fileURLWithPath: meta.workingDirectory), environment: env) { [weak self] ev in
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
            for item in list { items.upsert(item); if item.status != .running { ws.store.append(item, to: id); ws.retain(item, in: meta) } else { checkpoint(item) } }
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
            let preview = EditPreview.lines(tool: e.request.tool, inputJSON: e.request.input)
            let row = ChatItem(id: "perm-" + e.request.id, kind: .permission, text: e.request.summary, title: e.request.tool,
                               detail: e.request.path, status: .pending, preview: preview.isEmpty ? nil : EditPreview.encode(preview))
            items.upsert(row)
            pending.append(Pending(id: e.request.id, source: e.source, request: e.request))
            state = .waiting
            ws.notifyApproval(session: meta.title, repo: URL(fileURLWithPath: meta.cwd).lastPathComponent)
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
        onTurnEnd?(self)
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
        if loaded, Prefs.shared.recapAuto { refreshRecap() }
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
        var cmd = "cd \(shellQuote(meta.workingDirectory)) && claude --resume \(rid)"
        if let e = env {
            cmd = "ssh -t " + (e.port.map { "-p \($0) " } ?? "") + e.target + " " + shellQuote("cd \(shellQuote(meta.workingDirectory)) && claude --resume \(rid)")
            if e.persistent { Task { await Exec.with(e) { await RemoteHost.stop(id: meta.id) } } }   // two Claudes on one session would clash
        }
        sleep()
        let script = "tell application \"Terminal\" to do script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\ntell application \"Terminal\" to activate"
        Task { _ = try? await Shell.run("/usr/bin/osascript", ["-e", script]) }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Closing a tab stops an idle agent. An agent that is busy on a server is left running, so the work is not lost.
    func close() {
        flush()
        stoppedOnPurpose = true
        if isBusy, env?.persistent == true { runner?.detach() } else { runner?.stop() }
        acp?.stop(); sleepTask?.cancel()
    }
}

/// App-wide state for sessions: the list, the open tabs, the policy. Idle costs nothing: there are no timers here.
@MainActor @Observable
final class Workspace {
    static let shared = Workspace()

    let store = SessionStore()
    let index = MemoryIndex()
    let memory: MemoryStore
    let audit = AuditLog()
    var policy = AccessPolicy.load()
    var acpAgents = AcpAgentConfig.load()
    var environments = EnvironmentConfig.load()
    var sessions: [SessionMeta] = []
    var tabs: [String] = []
    var selected: String?
    private var controllers: [String: SessionController] = [:]

    private init() {
        memory = MemoryStore(index: index)
        sessions = store.list()
        let saved = UserDefaults.standard.stringArray(forKey: "openTabs") ?? []
        tabs = saved.filter { id in sessions.contains { $0.id == id } }
        selected = UserDefaults.standard.string(forKey: "selectedTab").flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
        if !UserDefaults.standard.bool(forKey: "memoryBackfilled") { UserDefaults.standard.set(true, forKey: "memoryBackfilled"); rebuildIndex() }
    }

    /// Indexes existing notes and the latest sessions once, in the background, so recall works on day one.
    func rebuildIndex() {
        let index = index, memory = memory, store = store, sessions = sessions
        DispatchQueue.global(qos: .utility).async {
            for n in memory.allNotes() { index.replace(scope: n.scope, source: "note", ref: n.name, text: n.name + "\n\n" + n.body) }
            for m in sessions.prefix(60) {
                let scope = MemoryStore.scope(forProject: m.cwd)
                for row in store.items(m.id, limit: 300) where row.status != .running && (row.kind == .user || row.kind == .assistant) {
                    index.add(scope: scope, source: "chat", ref: m.id, text: row.text, ts: row.ts)
                }
            }
        }
    }

    /// Keeps a finished user or assistant message for recall. Tool output and thinking are never indexed.
    func retain(_ item: ChatItem, in meta: SessionMeta) {
        guard Prefs.shared.recall, item.status != .running, item.kind == .user || item.kind == .assistant, !item.text.isEmpty else { return }
        let index = index, scope = MemoryStore.scope(forProject: meta.cwd), ref = meta.id, text = item.text, ts = item.ts
        DispatchQueue.global(qos: .utility).async { index.add(scope: scope, source: "chat", ref: ref, text: text, ts: ts) }
    }

    /// The best earlier context for a new session's first message, and what it was drawn from.
    func recall(for text: String, in meta: SessionMeta) async -> (prefix: String, sources: [String])? {
        guard Prefs.shared.recall, index.isOpen else { return nil }
        let titles = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.title) })
        let scopes = [MemoryStore.scope(forProject: meta.cwd), MemoryStore.globalScope]
        let index = index, id = meta.id
        let hits = await Task.detached { index.search(text, scopes: scopes, limit: 4, excludingRef: id) }.value
        guard let ctx = Recall.context(hits, titles: titles) else { return nil }
        let sources = hits.map { $0.source == "note" ? "note \"\($0.ref)\"" : "session \"\(titles[$0.ref] ?? "untitled")\"" }
        return (ctx + "\n---\n\n", Array(Set(sources)).sorted())
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
        controller(id)?.showRecapIfAway()
        if let p = previous, p != id { controllers[p]?.unloadIfIdle() }
        persistTabs()
    }

    var archived: [SessionMeta] { store.list(includeArchived: true).filter(\.archived) }

    func restore(_ id: String) {
        guard var m = store.load(id) else { return }
        m.archived = false; save(m); select(id)
    }

    func closeTab(_ id: String) {
        controllers[id]?.close(); controllers[id] = nil
        tabs.removeAll { $0 == id }
        if selected == id { selected = tabs.last; if let s = selected { controller(s)?.loadIfNeeded() } }
        persistTabs()
    }

    /// Why a delete is waiting for a yes: the session's worktree holds work that exists nowhere else.
    struct DeleteRisk: Identifiable { let id: String; let message: String }
    var deleteRisk: DeleteRisk?

    /// Deletes a session, but first asks when its worktree holds uncommitted changes or commits that were never pushed.
    func requestDelete(_ id: String) {
        guard let m = sessions.first(where: { $0.id == id }), let wt = m.worktree else { delete(id); return }
        Task {
            let w = await Exec.with(environment(m.environment)) { await Git.unsavedWork(wt) }
            var parts: [String] = []
            if w.uncommitted > 0 { parts.append("\(w.uncommitted) uncommitted change\(w.uncommitted == 1 ? "" : "s")") }
            if w.unpushed > 0 { parts.append("\(w.unpushed) commit\(w.unpushed == 1 ? "" : "s") that \(w.unpushed == 1 ? "was" : "were") never pushed") }
            if parts.isEmpty { delete(id) }
            else { deleteRisk = DeleteRisk(id: id, message: "This session's branch has \(parts.joined(separator: " and ")). Deleting the session removes that copy of the files for good.") }
        }
    }

    /// Removes the session. Its worktree always goes; its local branch goes too when everything on it is already on a remote.
    func delete(_ id: String, force: Bool = false) {
        closeTab(id)
        if let m = sessions.first(where: { $0.id == id }), let wt = m.worktree {
            let e = environment(m.environment)
            Task { await Exec.with(e) {
                let safe = await Git.unsavedWork(wt) == (0, 0)
                await Git.removeWorktree(repo: m.cwd, path: wt)
                if safe, let b = m.branch { await Git.deleteBranch(repo: m.cwd, branch: b) }
            } }
        }
        store.delete(id); index.remove(ref: id)
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
        var parentId: String?
        var handoff: String?
        var environment: String?
    }

    @discardableResult
    func create(_ n: NewSession) async throws -> SessionController {
        var meta = SessionMeta(title: "New session", cwd: n.folder, backend: n.backend, model: n.model, access: n.access)
        meta.parentId = n.parentId; meta.handoff = n.handoff; meta.environment = n.environment
        let remote = environment(n.environment)
        let isRepo = await Exec.with(remote) { await Git.isRepo(n.folder) }
        if let branch = n.branch, !branch.isEmpty, isRepo {
            if n.useWorktree {
                let path = remote.map { "\($0.remoteHome)/.cpilot/worktrees/\(meta.id)" } ?? AppPaths().root.appendingPathComponent("worktrees/\(meta.id)").path
                try await Exec.with(remote) {
                    _ = try await Shell.check("mkdir", ["-p", (path as NSString).deletingLastPathComponent])
                    try await Git.addWorktree(repo: n.folder, branch: branch, base: await Git.defaultBranch(n.folder), to: path)
                }
                meta.worktree = path
            } else {
                let current = await Exec.with(remote) { await Git.info(n.folder)?.branch }
                if current != branch { _ = try? await Exec.with(remote) { try await Shell.run("git", ["checkout", "-b", branch], cwd: URL(fileURLWithPath: n.folder)) } }
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

    // MARK: Fork, switch agent, remember

    /// Continues a session as a new one. With the same Claude agent it forks the agent's own conversation, so the context is
    /// complete; with another agent it hands over a short summary instead, which is all that can be carried across.
    @discardableResult
    func fork(_ source: SessionController, to backend: Backend? = nil) -> SessionController? {
        source.loadIfNeeded()
        let target = backend ?? source.meta.backend
        var m = SessionMeta(title: (backend == nil ? "Fork of " : "") + source.meta.title, cwd: source.meta.cwd, backend: target,
                            model: target == source.meta.backend ? source.meta.model : nil, access: source.meta.access,
                            branch: source.meta.branch, worktree: source.meta.worktree)
        let native = target.kind == .claude && source.meta.backend.kind == .claude && source.meta.remoteId != nil
        if native { m.remoteId = source.meta.remoteId; m.forkPending = true }
        else { m.handoff = ContextDigest.handoff(ContextDigest.build(items: source.items), from: source.meta.title) }
        save(m)
        for row in source.items where row.kind != .permission { store.append(row, to: m.id) }
        guard let c = controller(m.id) else { return nil }
        c.loaded = false; c.loadIfNeeded()
        c.addNotice(native ? "Forked from \"\(source.meta.title)\". The agent keeps the full conversation." : "Continuing from \"\(source.meta.title)\" with a summary of it. The new agent has not seen the full conversation.")
        select(m.id)
        return c
    }

    /// Spins a piece of work off into its own task: a new session that starts with a summary of this one, in its own copy of the
    /// files by default, so both can run at the same time. Its result can be brought back into this conversation.
    @discardableResult
    func delegate(from parent: SessionController, prompt: String, backend: Backend, worktree: Bool) async throws -> SessionController {
        parent.loadIfNeeded()
        let isRepo = await Git.isRepo(parent.meta.cwd)
        let n = NewSession(folder: parent.meta.cwd, backend: backend, access: parent.meta.access == .fullAccess ? .editFiles : parent.meta.access,
                           branch: isRepo && worktree ? "task-" + Git.slugify(prompt) + "-" + String(Int(Date().timeIntervalSince1970) % 10000) : nil,
                           useWorktree: isRepo && worktree, firstMessage: prompt, parentId: parent.id,
                           handoff: ContextDigest.handoff(ContextDigest.build(items: parent.items), from: parent.meta.title))
        return try await create(n)
    }

    func session(forBranch branch: String, repo: String, environment: String?) -> SessionMeta? {
        sessions.first { $0.branch == branch && $0.cwd == repo && $0.environment == environment }
    }

    /// Opens (or creates) a session working on a branch that already exists, in its own worktree when git allows it.
    @discardableResult
    func startSession(onBranch branch: String, repo: String, environment: String?, prompt: String = "") async throws -> SessionController {
        if let m = session(forBranch: branch, repo: repo, environment: environment), let c = controller(m.id) { select(m.id); if !prompt.isEmpty { c.draft = prompt; c.send() }; return c }
        let remote = self.environment(environment)
        var meta = SessionMeta(title: branch, cwd: repo, access: policy.defaultLevel, branch: branch)
        meta.environment = environment
        let path = remote.map { "\($0.remoteHome)/.cpilot/worktrees/\(meta.id)" } ?? AppPaths().root.appendingPathComponent("worktrees/\(meta.id)").path
        let made: Bool = await Exec.with(remote) {
            _ = try? await Shell.run("mkdir", ["-p", (path as NSString).deletingLastPathComponent])
            return ((try? await Shell.run("git", ["worktree", "add", path, branch], cwd: URL(fileURLWithPath: repo)))?.ok) ?? false
        }
        if made { meta.worktree = path } else { _ = try? await Exec.with(remote) { try await Shell.run("git", ["checkout", branch], cwd: URL(fileURLWithPath: repo)) } }
        save(meta)
        let c = controller(meta.id)!
        c.loaded = true
        select(meta.id)
        if !prompt.isEmpty { c.draft = prompt; c.send() }
        return c
    }

    /// A new branch on top of this session's branch, with its own session and copy of the files, so the stack grows as you work.
    @discardableResult
    func stackOn(_ source: SessionController, name: String) async throws -> SessionController {
        let remote = source.env
        let slug = Git.slugify(name)
        guard let parent = source.meta.branch else { throw StackError.message("This session is not on a branch yet.") }
        var meta = SessionMeta(title: slug, cwd: source.meta.cwd, backend: source.meta.backend, model: source.meta.model, access: source.meta.access, branch: slug)
        meta.environment = source.meta.environment
        let path = remote.map { "\($0.remoteHome)/.cpilot/worktrees/\(meta.id)" } ?? AppPaths().root.appendingPathComponent("worktrees/\(meta.id)").path
        try await Exec.with(remote) {
            _ = try await Shell.check("mkdir", ["-p", (path as NSString).deletingLastPathComponent])
            let tip = try await Shell.check("git", ["rev-parse", parent], cwd: URL(fileURLWithPath: source.meta.cwd)).trimmingCharacters(in: .whitespacesAndNewlines)
            try await Git.addWorktree(repo: source.meta.cwd, branch: slug, base: parent, to: path)
            try await Stacks.setParent(slug, to: parent, base: tip, in: source.meta.cwd)
        }
        meta.worktree = path
        meta.handoff = ContextDigest.handoff(ContextDigest.build(items: source.items), from: source.meta.title)
        save(meta)
        let c = controller(meta.id)!
        c.loaded = true
        select(meta.id)
        return c
    }

    /// A session for one spec task: its own branch on top of `parent`, in its own copy of the files.
    @discardableResult
    func startTask(repo: String, environment: String?, branch: String, parent: String, title: String, prompt: String, focus: Bool,
                   onTurnEnd: @escaping (SessionController) -> Void) async throws -> SessionController {
        let remote = self.environment(environment)
        let level: AccessLevel = policy.defaultLevel == .readOnly ? .editFiles : (policy.defaultLevel == .fullAccess ? .editFiles : policy.defaultLevel)
        var meta = SessionMeta(title: title, cwd: repo, access: level, branch: branch)
        meta.environment = environment
        let path = remote.map { "\($0.remoteHome)/.cpilot/worktrees/\(meta.id)" } ?? AppPaths().root.appendingPathComponent("worktrees/\(meta.id)").path
        try await Exec.with(remote) {
            _ = try await Shell.check("mkdir", ["-p", (path as NSString).deletingLastPathComponent])
            let tip = try await Shell.check("git", ["rev-parse", parent], cwd: URL(fileURLWithPath: repo)).trimmingCharacters(in: .whitespacesAndNewlines)
            try await Git.addWorktree(repo: repo, branch: branch, base: parent, to: path)
            try await Stacks.setParent(branch, to: parent, base: tip, in: repo)
        }
        meta.worktree = path
        save(meta)
        let c = controller(meta.id)!
        c.loaded = true
        c.onTurnEnd = onTurnEnd
        if focus { select(meta.id) }
        c.draft = prompt; c.send()
        return c
    }

    /// Lets commands starting with these words run without asking in this project (the user chose this when starting a hands-off run).
    func allowCommands(_ prefixes: [String], for folder: String) { for p in prefixes { addProjectCommand(p, for: folder) } }

    func children(of id: String) -> [SessionMeta] { sessions.filter { $0.parentId == id } }

    /// Puts a task's result into the parent's message box, for you to read and send.
    func bringBack(_ child: SessionMeta, into parent: SessionController) {
        guard let c = controller(child.id) else { return }
        c.loadIfNeeded()
        let result = c.items.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text ?? child.recap ?? "(no result yet)"
        parent.draft += (parent.draft.isEmpty ? "" : "\n\n") + "Result from the task \"\(child.title)\":\n\(result)"
        c.unloadIfIdle()
        select(parent.id)
    }

    func remember(_ text: String, project: String?, name: String? = nil) {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Note"
        let title = name ?? String(first.prefix(48))
        memory.save(scope: project.map(MemoryStore.scope(forProject:)) ?? MemoryStore.globalScope, name: title, body: text)
        AppModel.shared.show("Saved to memory")
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

    func environment(_ id: String?) -> EnvironmentConfig? { id.flatMap { id in environments.first { $0.id == id } } }
    func saveEnvironments() { EnvironmentConfig.save(environments) }

    // MARK: Notifications

    func notifyApproval(session: String, repo: String) {
        guard Prefs.shared.notify, Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent(); c.title = repo.isEmpty ? session : repo; c.subtitle = repo.isEmpty ? "" : session; c.body = "Needs your approval"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    func turnFinished(_ c: SessionController) {
        AppModel.shared.updateStatusIcon()
        guard Prefs.shared.notify, Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        AppModel.shared.notify("\(c.meta.title) finished")
    }
}

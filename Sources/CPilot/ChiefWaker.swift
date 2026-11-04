// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// The chief pilot is an agent session, and an agent's turn ends when it stops calling tools. Work it started (task sessions, reviewers, a spec being written,
/// a pull request waiting for checks) finishes later, with nobody to tell it. This wakes the chief pilot with a message when that work is done, and now and
/// then while it waits, until it says it is done or blocked, so it carries on by itself the way a person leading the work would. When to wake is decided
/// by `ChiefWake` (tested); this gathers what it needs and sends the message. What it waits for is kept on disk, so a restart does not lose it.
@MainActor
final class ChiefWaker {
    static let shared = ChiefWaker()

    private(set) var entries: [String: WakeState]
    private let store = WakeStore()
    private var loop: Task<Void, Never>?

    private init() { entries = store.all() }

    /// Picks up what was being waited for before the app was last closed.
    func resume() {
        if entries.values.contains(where: \.expecting), loop == nil { loop = Task { [weak self] in await self?.run() } }
    }

    /// The chief pilot of `repo` started something, or ended a step with work in flight.
    func expect(repo: String) {
        var e = entries[repo] ?? WakeState()
        ChiefWake.started(&e)
        set(e, repo)
        resume()
    }

    /// A task session or reviewer of `repo` ended a turn: the chief pilot, if it is waiting, has something to look at.
    func workFinished(repo: String) {
        guard var e = entries[repo], e.expecting else { return }
        e.sawFinish = true
        set(e, repo)
    }

    /// Any session ended a turn. A chief pilot that says it is waiting (or has work in flight) is expected even when its last tool call did not start anything.
    func turnEnded(_ c: SessionController) {
        guard c.meta.environment == nil else { return }
        let repo = c.meta.cwd
        guard c.meta.chief == true else { workFinished(repo: repo); return }
        let said = c.items.last(where: { $0.kind == .assistant && $0.status == .done }).flatMap { ChiefStatus.parse($0.text) }
        if case .waiting? = said { expect(repo: repo) }
        else if said == nil, Self.workInFlight(repo: repo, chiefId: c.id) { expect(repo: repo) }
    }

    private func set(_ e: WakeState, _ repo: String) { entries[repo] = e; store.set(e, for: repo) }

    private func run() async {
        // Entries stay after a wake so the count of "just looking" wakes survives; the loop only runs while something is expected.
        while !Task.isCancelled, entries.values.contains(where: \.expecting) {
            try? await Task.sleep(nanoseconds: ChiefWake.tickSeconds * 1_000_000_000)
            tick()
        }
        loop = nil
    }

    private func tick(now: Date = .now) {
        let ws = Workspace.shared
        for (repo, var e) in entries where e.expecting {
            defer { set(e, repo) }
            guard let meta = ws.chiefSession(repo: repo, environment: nil), let chief = ws.controller(meta.id) else { e.expecting = false; continue }
            let inputs = WakeInputs(chiefBusy: chief.isBusy, hasPending: !chief.pending.isEmpty, hasAttachments: !chief.attachments.isEmpty,
                                    quietFor: now.timeIntervalSince(meta.updatedAt), workInFlight: Self.workInFlight(repo: repo, chiefId: meta.id),
                                    hold: ws.unattendedHold(), runningAgents: ws.runningAgents, status: Self.status(of: meta))
            let name = URL(fileURLWithPath: repo).lastPathComponent
            switch ChiefWake.decide(&e, inputs, now: now) {
            case .wait, .finish: break
            case .wake(let finished): wake(chief, repo: repo, ChiefWake.message(finished: finished))
            case .stalled:
                AlertCenter.shared.alert(.needs, title: "The chief pilot is still waiting", body: name + ": nothing has changed for a long while.", tag: "stall-\(repo)", session: meta.id)
                AppModel.shared.notify("The chief pilot is still waiting", body: "\(name): nothing has changed for a long while. Open the chief pilot to see what it waits for.")
            case .blocked(let why):
                AlertCenter.shared.alert(.needs, title: "The chief pilot needs you", body: name + (why.isEmpty ? "" : ": " + why), tag: "blocked-\(repo)", session: meta.id)
            case .held(let why):
                AlertCenter.shared.alert(.needs, title: "The chief pilot is held back", body: name + ": " + why, tag: "held-\(repo)", session: meta.id)
            }
        }
    }

    /// What the chief pilot's last finished message says about itself.
    private static func status(of meta: SessionMeta) -> ChiefStatus? {
        let last = Workspace.shared.store.items(meta.id, limit: 40).last(where: { $0.kind == .assistant && $0.status == .done })
        return last.flatMap { ChiefStatus.parse($0.text) }
    }

    /// True while a session in the repository (other than the chief pilot) is working, or a spec stage is being written.
    static func workInFlight(repo: String, chiefId: String) -> Bool {
        let ws = Workspace.shared
        if ws.sessions.contains(where: { $0.cwd == repo && $0.id != chiefId && ws.controller($0.id)?.isBusy == true }) { return true }
        let center = SpecHub.shared.center(for: PRCenter.Repo(dir: repo, environment: nil))
        return center.jobs.values.contains { $0.running } || !center.gating.isEmpty
    }

    /// True for a chief pilot that has nothing in flight and is not waiting to be woken: its run is over.
    static func isDone(_ c: SessionController) -> Bool {
        c.meta.chief == true && !(shared.entries[c.meta.cwd]?.expecting ?? false) && !workInFlight(repo: c.meta.cwd, chiefId: c.id)
    }

    private func wake(_ chief: SessionController, repo: String, _ text: String) {
        chief.loadIfNeeded()
        // Whatever the user was typing to the chief pilot stays in the box.
        let typing = chief.draft
        chief.draft = text
        chief.send()
        chief.draft = typing
        Workspace.shared.audit.record(AuditEntry(session: chief.id, tool: "chief wake", summary: String(text.dropFirst(8).prefix(80)), outcome: "sent"))
    }
}

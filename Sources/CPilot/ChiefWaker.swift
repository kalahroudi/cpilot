// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// The chief pilot is an agent session, and an agent's turn ends when it stops calling tools. Work it started (task sessions, reviewers, a spec being written,
/// a pull request waiting for checks) finishes later, with nobody to tell it. This wakes the chief pilot with a message when that work is done, and now and
/// then while it waits, so it carries on by itself the way a person leading the work would.
@MainActor
final class ChiefWaker {
    static let shared = ChiefWaker()

    /// How long the chief pilot must have been quiet before it is woken, and how often it is woken just to look at checks.
    static let settle: TimeInterval = 10
    static let lookEvery: TimeInterval = 180
    static let maxLooks = 12
    static let tickSeconds: UInt64 = 15

    struct Entry {
        var expecting = true
        var sawBusy = false
        var lastWake = Date()
        var looks = 0
    }

    private(set) var entries: [String: Entry] = [:]
    private var loop: Task<Void, Never>?

    /// The chief pilot of `repo` ended a step with work in flight.
    func expect(repo: String) {
        var e = entries[repo] ?? Entry()
        e.expecting = true
        entries[repo] = e
        if loop == nil { loop = Task { [weak self] in await self?.run() } }
    }

    private func run() async {
        // Entries stay after a wake so the count of "just looking" wakes survives; the loop only runs while something is expected.
        while !Task.isCancelled, entries.values.contains(where: \.expecting) {
            try? await Task.sleep(nanoseconds: Self.tickSeconds * 1_000_000_000)
            tick()
        }
        loop = nil
    }

    private func tick(now: Date = .now) {
        let ws = Workspace.shared
        for (repo, var e) in entries where e.expecting {
            defer { entries[repo] = e }
            guard let meta = ws.chiefSession(repo: repo, environment: nil), let chief = ws.controller(meta.id) else { e.expecting = false; continue }
            let busy = Self.workInFlight(repo: repo, chiefId: meta.id)
            if busy { e.sawBusy = true }
            // Wait for the chief pilot's own turn to end, and for the user to finish typing to it.
            guard !chief.isBusy, chief.pending.isEmpty, chief.draft.isEmpty, now.timeIntervalSince(meta.updatedAt) >= Self.settle, !busy else { continue }

            if e.sawBusy {
                e.sawBusy = false; e.looks = 0
                wake(chief, repo: repo, "CPilot: the sessions and jobs you started have finished. Look at where things stand (list_specs, list_sessions, pr_reviews, list_pull_requests, list_stacks) and carry on with the next step. If everything is merged, say so in one line.")
                e.expecting = false; e.lastWake = now
            } else if now.timeIntervalSince(e.lastWake) >= Self.lookEvery {
                if e.looks >= Self.maxLooks {
                    e.expecting = false
                    AlertCenter.shared.alert(.needs, title: "The chief pilot is still waiting", body: URL(fileURLWithPath: repo).lastPathComponent + ": nothing has changed for a long while.", tag: "stall-\(repo)", session: meta.id)
                    AppModel.shared.notify("The chief pilot is still waiting", body: "\(URL(fileURLWithPath: repo).lastPathComponent): nothing has changed for a long while. Open the chief pilot to see what it waits for.")
                } else {
                    e.looks += 1; e.lastWake = now
                    wake(chief, repo: repo, "CPilot: it has been a while. Check whether what you are waiting for (checks, reviewers, a merge) is ready, and carry on if it is. If it is not, end your turn with one line saying what you wait for.")
                    e.expecting = false
                }
            }
        }
    }

    /// True while a session in the repository (other than the chief pilot) is working, or a spec stage is being written.
    static func workInFlight(repo: String, chiefId: String) -> Bool {
        let ws = Workspace.shared
        if ws.sessions.contains(where: { $0.cwd == repo && $0.id != chiefId && ws.controller($0.id)?.isBusy == true }) { return true }
        return SpecHub.shared.center(for: PRCenter.Repo(dir: repo, environment: nil)).jobs.values.contains { $0.running }
    }

    private func wake(_ chief: SessionController, repo: String, _ text: String) {
        chief.loadIfNeeded()
        chief.draft = text
        chief.send()
        Workspace.shared.audit.record(AuditEntry(session: chief.id, tool: "chief wake", summary: String(text.dropFirst(8).prefix(80)), outcome: "sent"))
    }
}

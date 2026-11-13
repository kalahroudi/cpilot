// SPDX-License-Identifier: Apache-2.0

import Foundation
import AppKit
import CPilotKit

/// Starts work by itself, from the triggers you set in Settings: a schedule, an issue of yours that gets a label, or a pull request of yours that fails its checks.
/// It looks once a minute. Looking at GitHub costs one `gh` call per trigger every five minutes. Whatever it starts goes through the same rules as anything else:
/// the chief pilot's approvals, the merge gate, and the access level your Specs setting gives a repository's task sessions.
@MainActor @Observable
final class TriggerEngine {
    static let shared = TriggerEngine()
    static let pollEvery: TimeInterval = 300

    enum Outcome: Equatable {
        case started(String), nothing(String), deferred(String), failed(String)
        var message: String { switch self { case .started(let m), .nothing(let m), .deferred(let m), .failed(let m): m } }
    }

    let store = TriggerStore()
    /// Bumped whenever something a view shows has changed.
    private(set) var version = 0
    private(set) var firing: Set<String> = []
    /// The last thing worth telling about each trigger ("Nothing new", "GitHub could not be read", ...).
    private(set) var notes: [String: String] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPoll: [String: Date] = [:]
    @ObservationIgnored private var account: (login: String?, at: Date)?

    private enum TriggerError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } } }

    func start() {
        guard loop == nil else { return }
        // A Mac that slept through a moment looks as soon as it wakes, not up to a minute later.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.tick() } }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))                 // let the app finish starting
            while !Task.isCancelled { await self?.tick(); try? await Task.sleep(for: .seconds(60)) }
        }
    }

    // MARK: Editing

    func save(_ t: Trigger) { store.upsert(t); version += 1 }
    func remove(_ id: String) { store.remove(id); notes[id] = nil; version += 1 }

    // MARK: Looking

    private func tick() async {
        guard !AppModel.shared.demo else { return }
        for t in store.triggers where t.enabled && t.problem == nil && !firing.contains(t.id) {
            guard FileManager.default.fileExists(atPath: t.repo) else { notes[t.id] = "The folder is gone."; continue }
            let o = await evaluate(t, manual: false)
            if case .nothing(let m) = o, m.isEmpty { continue }
            notes[t.id] = o.message
        }
        version += 1
    }

    /// "Run now" from Settings: look straight away, ignore the schedule and the five-minute wait, and say what happened.
    @discardableResult
    func runNow(_ id: String) async -> Outcome {
        guard let t = store.trigger(id), !firing.contains(id) else { return .nothing("It is already running.") }
        if let p = t.problem { return .failed(p) }
        let o = await evaluate(t, manual: true)
        notes[id] = o.message
        version += 1
        return o
    }

    private func pollDue(_ t: Trigger) -> Bool {
        if let last = lastPoll[t.id], Date().timeIntervalSince(last) < Self.pollEvery { return false }
        lastPoll[t.id] = Date()
        return true
    }

    private func myLogin() async -> String? {
        if let a = account, Date().timeIntervalSince(a.at) < 600 { return a.login }
        let login = await GitHub.account()?.login
        account = (login, Date())
        return login
    }

    private func evaluate(_ t: Trigger, manual: Bool) async -> Outcome {
        firing.insert(t.id); defer { firing.remove(t.id) }
        switch t.kind {
        case .schedule:
            if !manual, !t.schedule.isDue(lastRun: t.lastRun, createdAt: t.createdAt) { return .nothing("") }
            return await start(t, prompt: TriggerPolicy.scheduledPrompt(t), what: "Scheduled run", key: nil, manual: manual)

        case .issueLabel:
            if !manual, !pollDue(t) { return .nothing("") }
            guard let me = await myLogin() else { return .failed("CPilot cannot tell who you are on GitHub. Run `gh auth login`.") }
            do {
                let issues = try await GitHub.issues(in: t.repo, label: t.label)
                guard let first = TriggerPolicy.issueCandidates(issues, label: t.label, handled: store.handled(t.id), me: me).first else {
                    return .nothing("Nothing new. It looks for open issues you wrote with the label \"\(t.label)\".")
                }
                let full = try await GitHub.issue(first.number, in: t.repo)
                return await start(t, prompt: TriggerPolicy.issuePrompt(full, extra: t.prompt), what: "Issue #\(first.number): \(first.title)", key: String(first.number), manual: manual)
            } catch { return .failed("GitHub could not be read: \(error.localizedDescription)") }

        case .failingChecks:
            if !manual, !pollDue(t) { return .nothing("") }
            do {
                let ws = Workspace.shared
                let chief = ws.chiefSession(repo: t.repo, environment: nil)
                let prs = try await GitHub.mineWithChecks(in: t.repo)
                // A pull request somebody is already working on (a reviewer, a session on its branch) is left alone, and so are all of them while the chief pilot is busy.
                let cands = TriggerPolicy.failingCandidates(prs, handled: store.handled(t.id)).filter { c in
                    !ws.sessions.contains { ($0.reviewOf == c.pr.number || ($0.branch != nil && $0.branch == c.pr.headRefName)) && ws.controller($0.id)?.isBusy == true }
                }
                guard let first = cands.first else { return .nothing("Nothing to fix. It looks at your open pull requests whose checks fail.") }
                if let chief, ChiefWaker.workInFlight(repo: t.repo, chiefId: chief.id) { return .deferred("The chief pilot is working on this repository. It looks again later.") }
                return await start(t, prompt: "", what: "#\(first.pr.number) \(first.pr.title): \(first.failed.prefix(3).joined(separator: ", ")) failed", key: first.key, manual: manual, pr: first)
            } catch { return .failed("GitHub could not be read: \(error.localizedDescription)") }
        }
    }

    // MARK: Starting

    private func start(_ t: Trigger, prompt: String, what: String, key: String?, manual: Bool, pr: (pr: CIPullRequest, failed: [String], key: String)? = nil) async -> Outcome {
        guard store.mayStart(t, manual: manual) else { return .deferred("Held back by the limit of \(TriggerStore.hourlyLimit) runs an hour (and ten minutes between runs of one trigger).") }
        let ws = Workspace.shared
        if !manual, let why = ws.unattendedHold() { return .deferred(why) }
        var sessionId = ""
        do {
            // Scheduled for a session you were already working with: it carries on there, in the same conversation.
            if let sid = t.sessionId {
                guard let m = ws.sessions.first(where: { $0.id == sid && !$0.archived }), let c = ws.controller(m.id) else { throw TriggerError.message("That session is gone.") }
                guard manual || !c.isBusy else { return .deferred("The session is working. The message goes when it is free.") }
                c.loadIfNeeded(); c.draft = prompt; c.send(byUser: manual)
                sessionId = sid
            } else {
            switch t.action {
            case .chief:
                let chief = try await ws.openChief(repo: t.repo, environment: nil, show: false)
                guard chiefFree(chief, repo: t.repo) else { return .deferred("The chief pilot is busy. It runs when the chief pilot is free.") }
                chief.loadIfNeeded(); chief.draft = chiefMessage(t, prompt: prompt, pr: pr); chief.send(byUser: false)
                sessionId = chief.id
            case .session:
                if let pr, t.kind == .failingChecks {
                    let full = try await GitHub.view(pr.pr.number, in: t.repo)
                    let c = try await PRCenter.shared.startSession(on: full, dir: t.repo, prompt: TriggerPolicy.failingChecksPrompt(number: pr.pr.number, title: pr.pr.title, failed: pr.failed, extra: t.prompt),
                                                                   title: "Fix checks #\(pr.pr.number)", readOnly: false, show: false)
                    sessionId = c.id
                } else {
                    let c = try await ws.create(.init(folder: t.repo, access: sessionAccess(for: t.repo), branch: TriggerPolicy.branch(for: t, suffix: String(UUID().uuidString.prefix(4)).lowercased()),
                                                       useWorktree: true, firstMessage: prompt, title: t.name, select: false))
                    sessionId = c.id
                }
            }
            }
        } catch {
            // Not tried again by itself: a failure that repeats every few minutes would only fill the log. "Run now" tries once more.
            store.record(TriggerRun(triggerId: t.id, name: t.name, what: what, outcome: .failed, detail: error.localizedDescription))
            store.ran(t.id)
            if let key { store.markHandled(t.id, key: key) }
            AlertCenter.shared.alert(.failed, title: "A trigger could not start", body: "\(t.name): \(error.localizedDescription)", tag: "trigger-\(t.id)", project: URL(fileURLWithPath: t.repo).lastPathComponent)
            return .failed("Could not start: \(error.localizedDescription)")
        }
        store.record(TriggerRun(triggerId: t.id, name: t.name, what: what, outcome: .started))
        store.ran(t.id)
        if let key { store.markHandled(t.id, key: key) }
        ws.audit.record(AuditEntry(session: sessionId, tool: "trigger", summary: "\(t.name): \(what)", outcome: "allowed (trigger)"))
        AppModel.shared.notify("Trigger started: \(t.name)", body: what, project: URL(fileURLWithPath: t.repo).lastPathComponent)
        return .started(what)
    }

    /// The access a trigger's one-off session starts with: the same as a spec task in that repository (Full access unless you turned that off for it).
    private func sessionAccess(for repo: String) -> AccessLevel {
        let ws = Workspace.shared
        if ws.policy.specSessionsHaveFullAccess(repo) { return .fullAccess }
        return ws.policy.defaultLevel == .readOnly || ws.policy.defaultLevel == .fullAccess ? .editFiles : ws.policy.defaultLevel
    }

    private func chiefFree(_ c: SessionController, repo: String) -> Bool {
        !c.isBusy && c.pending.isEmpty && c.draft.isEmpty && !(ChiefWaker.shared.entries[repo]?.expecting ?? false) && !ChiefWaker.workInFlight(repo: repo, chiefId: c.id)
    }

    private func chiefMessage(_ t: Trigger, prompt: String, pr: (pr: CIPullRequest, failed: [String], key: String)?) -> String {
        let head = "CPilot trigger \"\(t.name)\" (\(t.summary())) started this. Nobody is waiting at the keyboard: carry it through yourself."
        if let pr {
            let extra = t.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(head)\n\nPull request #\(pr.pr.number) (\(pr.pr.title)) is the user's own and its checks failed: \(pr.failed.prefix(8).joined(separator: ", ")). Assign a reviewer with pr_review {pr: \(pr.pr.number), focus: \"Fix the failing checks (\(pr.failed.prefix(4).joined(separator: ", "))): find the cause in the logs, fix it with the smallest change, make the tests pass, push to the branch.\"}, follow it until the checks pass, and merge only through the usual rules.\(extra.isEmpty ? "" : "\n\nAlso: \(extra)")"
        }
        return "\(head)\n\n\(prompt)"
    }
}

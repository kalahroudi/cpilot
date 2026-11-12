// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Runs dreams (see `Dream`) and acts on the proposals they leave. After a few sessions in a repository have finished, and not more than once every six hours, Claude is asked once
/// (no tools) to look over what they did and propose changes to the repository's notes. What is checked and allowed is decided in `Dream`; this decides when to look and who to tell.
@MainActor
final class Dreamer {
    static let shared = Dreamer()
    static let changed = Notification.Name("CPilotDreamsChanged")

    enum Outcome: Equatable {
        case proposed(applied: Int, waiting: Int), nothing(String), failed(String)
        var message: String {
            switch self {
            case .proposed(let a, let w): "Dream: \(a) change\(a == 1 ? "" : "s") made, \(w) waiting for you."
            case .nothing(let m), .failed(let m): m
            }
        }
    }

    /// Sessions that must have finished in a repository since the last dream.
    static let minSessions = 3
    /// At most one look every six hours per repository.
    static let gap: TimeInterval = 6 * 3600
    private static let sinceKey = "dreamSince"

    private var running: Set<String> = []
    private var lastAttempt: [String: Date] = [:]
    private var lastCheck: [String: Date] = [:]

    private func since(_ repo: String) -> Date {
        let d = UserDefaults.standard.dictionary(forKey: Self.sinceKey) as? [String: Double]
        return d?[repo].map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(-7 * 86400)
    }

    private func setSince(_ repo: String, _ date: Date) {
        var d = (UserDefaults.standard.dictionary(forKey: Self.sinceKey) as? [String: Double]) ?? [:]
        d[repo] = date.timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: Self.sinceKey)
    }

    /// A session ended a turn: dream if enough has happened in its repository. Nothing polls; this runs only because something happened.
    func sessionEnded(_ c: SessionController) {
        guard Prefs.shared.dream, c.meta.environment == nil else { return }
        let repo = c.meta.cwd
        if let t = lastAttempt[repo], Date().timeIntervalSince(t) < Self.gap { return }
        // Counting sessions reads them from disk, so look at most every ten minutes however many turns end.
        if let t = lastCheck[repo], Date().timeIntervalSince(t) < 600 { return }
        lastCheck[repo] = Date()
        let finished = Workspace.shared.store.list(includeArchived: true).filter { $0.cwd == repo && $0.environment == nil && $0.updatedAt > since(repo) }
        guard finished.count >= Self.minSessions else { return }
        Task { _ = await dream(repo: repo, manual: false) }
    }

    /// What the repository's recent sessions said and did, as the model sees it: user and assistant messages, secrets removed, each cut short.
    func gather(repo: String, since: Date) -> [Dream.Source] {
        let ws = Workspace.shared
        let mine = ws.store.list(includeArchived: true).filter { $0.cwd == repo && $0.environment == nil && $0.updatedAt > since }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)
        var out: [Dream.Source] = []
        for s in mine {
            let rows = ws.store.items(s.id, limit: 80).filter { ($0.kind == .user || $0.kind == .assistant) && !$0.text.isEmpty && $0.status != .running }
            let messages = rows.suffix(12).map { (($0.kind == .user ? "User: " : "Assistant: ") + String(MemoryIndex.redact($0.text).prefix(600))) }
            if !messages.isEmpty { out.append(Dream.Source(session: String(s.id.prefix(8)), title: s.title, messages: Array(messages))) }
        }
        return out
    }

    @discardableResult
    func dream(repo: String, manual: Bool) async -> Outcome {
        guard !running.contains(repo) else { return .nothing("Already looking.") }
        running.insert(repo); defer { running.remove(repo) }
        lastAttempt[repo] = Date()
        let started = Date(), ws = Workspace.shared, scope = MemoryStore.scope(forProject: repo)
        let sources = gather(repo: repo, since: since(repo))
        guard sources.map({ $0.messages.joined().count }).reduce(0, +) >= 300 else { return .nothing("Nothing to dream about yet: not enough has happened since the last look.") }
        let notes = ws.memory.notes(scope: scope)
        let model = Prefs.shared.dreamModel.isEmpty ? "sonnet" : Prefs.shared.dreamModel
        guard let answer = await ClaudeOneShot.run(Dream.prompt(repo: repo, notes: notes, sources: sources), in: repo, model: model, timeout: 240) else {
            return .failed("Claude could not be reached. It will try again after a later session.")
        }
        setSince(repo, started)
        let personOwned = Set(notes.filter { ws.memory.isPersonOwned(scope: scope, name: $0.name) }.map(\.name))
        let plan = Dream.plan(Dream.parse(answer), notes: notes, personOwned: personOwned, sources: sources)
        guard !plan.planned.isEmpty else { return .nothing(plan.rejected.isEmpty ? "Nothing to change in the notes." : "Nothing usable: \(plan.rejected.count) idea\(plan.rejected.count == 1 ? " was" : "s were") dropped because \(plan.rejected[0]).") }
        var applied = 0, waiting = 0
        for p in plan.planned {
            let card = Dream.card(for: p, scope: scope, sources: sources)
            ws.proposals.add(card)
            if !p.needsApproval, Prefs.shared.dreamAuto, await approve(card.id, by: "auto") == nil { applied += 1 } else { waiting += 1 }
        }
        ws.audit.record(AuditEntry(session: "dream", tool: "dream", summary: "\(URL(fileURLWithPath: repo).lastPathComponent): \(plan.planned.count) proposed, \(applied) made", outcome: "saved"))
        if waiting > 0 { AppModel.shared.notify("Notes for \(URL(fileURLWithPath: repo).lastPathComponent) need you", body: "\(waiting) proposed change\(waiting == 1 ? "" : "s") from a dream. Open Memory to look.") }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return .proposed(applied: applied, waiting: waiting)
    }

    /// Makes an open proposal's change. Returns nil when it was made, or the reason it was not.
    @discardableResult
    func approve(_ id: String, by who: String) async -> String? {
        let ws = Workspace.shared
        guard let p = ws.proposals.proposal(id), p.isOpen, var planned = Dream.planned(from: p) else { return "That proposal is no longer open." }
        switch Dream.apply(planned, in: ws.memory, scope: p.scope) {
        case .applied(let touched):
            planned.touched = touched
            let payload = (try? JSONEncoder().encode(planned)).flatMap { String(data: $0, encoding: .utf8) } ?? p.payload
            ws.proposals.update(id) { q in guard q.isOpen else { return false }; q.status = .applied; q.decidedBy = who; q.decidedAt = .now; q.payload = payload; return true }
            ws.audit.record(AuditEntry(session: "dream", tool: "dream", summary: p.what, outcome: who == "auto" ? "allowed by rule" : "allowed once"))
            NotificationCenter.default.post(name: Self.changed, object: nil)
            return nil
        case .stale(let why):
            ws.proposals.decide(id, .stale, by: who, outcome: why)
            NotificationCenter.default.post(name: Self.changed, object: nil)
            return why + " The proposal was dropped."
        case .rejected(let why):
            ws.proposals.decide(id, .stale, by: who, outcome: "Not made: " + why.joined(separator: ", "))
            NotificationCenter.default.post(name: Self.changed, object: nil)
            return "Not made: the text " + why.joined(separator: ", ") + "."
        case .failed:
            return "Could not write the note."
        }
    }

    func decline(_ id: String) {
        Workspace.shared.proposals.decide(id, .declined, by: "you")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Takes a made change back. Returns nil when it was undone, or the reason it was not.
    func undo(_ id: String) -> String? {
        let ws = Workspace.shared
        guard let p = ws.proposals.proposal(id), p.status == .applied, let touched = Dream.planned(from: p)?.touched else { return "That change cannot be undone." }
        if let why = Dream.undo(touched, in: ws.memory, scope: p.scope) { return why }
        ws.proposals.update(id) { q in q.status = .undone; q.outcome = "Undone by you"; return true }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return nil
    }
}

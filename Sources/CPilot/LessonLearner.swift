// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// When a chief pilot run is over, reads what reviewers caught and what failed, asks Claude (once, no tools) for the few lessons worth keeping, and adds them to
/// the repository's "lessons from past runs" note. Every later session in that repository starts with that note, so the same problem is not met twice.
/// A clean run with nothing to learn from costs nothing: no reviewer report and no failure means no call.
@MainActor
final class LessonLearner {
    static let shared = LessonLearner()

    enum Outcome: Equatable {
        case saved([String]), nothing(String), failed(String)
        var message: String {
            switch self {
            case .saved(let l): "Saved \(l.count) lesson\(l.count == 1 ? "" : "s"): " + l.joined(separator: " ")
            case .nothing(let m), .failed(let m): m
            }
        }
    }

    private var running: Set<String> = []
    private var lastAttempt: [String: Date] = [:]
    /// At most one look every five minutes per repository, so a chief pilot that ends many turns does not cost a call each.
    static let gap: TimeInterval = 300
    private static let sinceKey = "lessonsSince"

    private func since(_ repo: String) -> Date {
        let d = UserDefaults.standard.dictionary(forKey: Self.sinceKey) as? [String: Double]
        return d?[repo].map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(-86400)
    }

    private func setSince(_ repo: String, _ date: Date) {
        var d = (UserDefaults.standard.dictionary(forKey: Self.sinceKey) as? [String: Double]) ?? [:]
        d[repo] = date.timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: Self.sinceKey)
    }

    /// Called when any session ends a turn; acts only for a chief pilot that has finished its work.
    func chiefTurnEnded(_ c: SessionController) {
        guard Prefs.shared.learnLessons, c.meta.environment == nil, ChiefWaker.isDone(c) else { return }
        let repo = c.meta.cwd
        if let t = lastAttempt[repo], Date().timeIntervalSince(t) < Self.gap { return }
        Task { _ = await learn(repo: repo, manual: false) }
    }

    /// Look at what happened in the repository since the last time and keep what is worth keeping. `manual` ignores the five-minute gap and says why when there is nothing.
    @discardableResult
    func learn(repo: String, manual: Bool) async -> Outcome {
        guard !running.contains(repo) else { return .nothing("Already looking.") }
        running.insert(repo); defer { running.remove(repo) }
        lastAttempt[repo] = Date()
        let started = Date()
        let evidence = gather(repo: repo, since: since(repo))
        guard evidence.contains(where: { $0.label != Self.summaryLabel }), evidence.map(\.text.count).reduce(0, +) >= 150 else {
            return .nothing("Nothing to learn from yet: no reviewer report or failure since the last look.")
        }
        let ws = Workspace.shared, scope = MemoryStore.scope(forProject: repo)
        let existing = Lessons.read(ws.memory.notes(scope: scope).first { $0.name == Lessons.noteName }?.body ?? "")
        guard let answer = await ClaudeOneShot.run(Lessons.prompt(repo: repo, evidence: evidence, existing: existing), in: repo, timeout: 120) else {
            return .failed("Claude could not be reached. It will try again after the next run.")
        }
        setSince(repo, started)
        let merged = Lessons.merge(existing: existing, new: Lessons.parse(answer))
        guard !merged.added.isEmpty else { return .nothing("Nothing new to keep.") }
        ws.memory.save(scope: scope, name: Lessons.noteName, body: Lessons.render(merged.lessons))
        ws.audit.record(AuditEntry(session: "lessons", tool: "lessons", summary: "\(URL(fileURLWithPath: repo).lastPathComponent): " + merged.added.joined(separator: " | "), outcome: "saved"))
        AppModel.shared.notify("Learned \(merged.added.count) lesson\(merged.added.count == 1 ? "" : "s") for \(URL(fileURLWithPath: repo).lastPathComponent)", body: merged.added[0])
        return .saved(merged.added)
    }

    static let summaryLabel = "The lead's closing summary"

    /// Reviewers' reports, failed sessions and failed triggers since `since`, and the chief pilot's closing summary for context.
    func gather(repo: String, since: Date) -> [Lessons.Evidence] {
        let ws = Workspace.shared
        func lastText(_ id: String, _ kind: ChatItem.Kind, after: Date) -> String? {
            ws.store.items(id, limit: 80).last { $0.kind == kind && $0.ts > after && !$0.text.isEmpty && ($0.kind != .assistant || $0.status != .running) }?.text
        }
        var out: [Lessons.Evidence] = []
        let mine = ws.sessions.filter { $0.cwd == repo && $0.environment == nil && $0.updatedAt > since }
        for s in mine where s.reviewOf != nil {
            if let t = lastText(s.id, .assistant, after: since), t.count >= 60 { out.append(.init(label: "A reviewer's report on a pull request", text: t)) }
        }
        for s in mine where s.reviewOf == nil && s.chief != true {
            if let t = lastText(s.id, .error, after: since) { out.append(.init(label: "A session that failed (\(s.title))", text: t)) }
        }
        for r in TriggerEngine.shared.store.runs where r.outcome == .failed && r.ts > since && TriggerEngine.shared.store.trigger(r.triggerId)?.repo == repo {
            out.append(.init(label: "A trigger that could not start", text: "\(r.what): \(r.detail)"))
        }
        if let chief = ws.chiefSession(repo: repo, environment: nil), let t = lastText(chief.id, .assistant, after: since) {
            out.append(.init(label: Self.summaryLabel, text: t))
        }
        return out
    }
}

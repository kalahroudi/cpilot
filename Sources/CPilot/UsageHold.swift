// SPDX-License-Identifier: Apache-2.0

import Foundation
import AppKit
import CPilotKit

/// When Claude says the usage limit is reached ("resets 2am (Europe/London)"), every message sent before then fails the same way at once. Work that starts by itself (the chief pilot's wakes,
/// gate retries, triggers) would only ask again and again, so it waits. Messages CPilot would have sent are kept, sessions the limit stopped mid-work are noted, and at the reset they carry on.
/// Your own messages are never held: the limit may be lifted early, or be a different one. Kept across a restart.
@MainActor @Observable
final class UsageHold {
    static let shared = UsageHold()

    /// When to try again, and Claude's own words about the limit.
    private(set) var until: Date?
    private(set) var message: String?
    /// Sessions the limit stopped that should carry on by themselves (the chief pilot and CPilot's own workers).
    @ObservationIgnored private var resume: Set<String> = []
    /// Everything that was stopped by it, for telling you.
    @ObservationIgnored private var affected: Set<String> = []
    /// Messages CPilot would have sent while the limit held, per session, in order.
    @ObservationIgnored private var parked: [String: [String]] = [:]
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    private static let key = "usageHold"

    static let resumeText = "CPilot: your usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete. \(ChiefStatus.instructions)"

    /// When the limit lifts, or nil when nothing is held.
    var active: Date? { until.flatMap { $0 > .now ? $0 : nil } }

    private init() { restore() }

    // MARK: Hitting the limit

    /// A session's turn ended with Claude's usage-limit message.
    func engage(_ hit: UsageLimit.Hit, session: SessionController) {
        let first = active == nil
        let at = hit.resumeAt()
        if until == nil || until! <= .now || at > until! { until = at; message = hit.message }
        affected.insert(session.id)
        if Prefs.shared.resumeAfterLimit, session.meta.chief == true || session.meta.isWorker { resume.insert(session.id) }
        persist(); startWaiting()
        if first { AppModel.shared.notify("Claude's usage limit is reached", body: "Automated work is paused and carries on at \(Self.clock(at)).") }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Sessions the limit stopped while CPilot was closed, or before it knew about limits, still wait for a message. Found by their transcripts, at launch and after a sleep.
    func recover() {
        guard Prefs.shared.resumeAfterLimit else { return }
        let ws = Workspace.shared
        for m in ws.sessions where m.backend.kind == .claude && m.environment == nil && !m.archived && (m.chief == true || m.isWorker) {
            guard ws.controller(m.id)?.isBusy != true, let hit = UsageLimit.stoppedBy(ws.store.items(m.id, limit: 12)) else { continue }
            guard !affected.contains(m.id) else { continue }
            // Already past the reset: carry on now, not in two minutes.
            let at = hit.resets.map { $0.addingTimeInterval(UsageLimit.margin) <= .now ? Date.now : hit.resumeAt() } ?? hit.resumeAt()
            if until == nil || until! <= .now || at > until! { until = at; message = hit.message }
            affected.insert(m.id); resume.insert(m.id)
        }
        guard !affected.isEmpty else { return }
        persist()
        if until.map({ $0 <= .now }) == true { release() } else { startWaiting() }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("CPilotUsageHoldChanged")

    /// A message CPilot would have sent: kept for the reset. The session carries on by itself then.
    func park(_ text: String, for session: SessionController) {
        parked[session.id, default: []].append(text)
        affected.insert(session.id)
        resume.insert(session.id)
        persist(); startWaiting()
    }

    var parkedCount: Int { parked.values.reduce(0) { $0 + $1.count } }

    // MARK: The reset

    private func startWaiting() {
        guard waiter == nil else { return }
        // Short sleeps, so a Mac that slept through the reset notices when it wakes, and the clock can be corrected.
        waiter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let u = self.until else { break }
                let left = u.timeIntervalSinceNow
                if left <= 0 { self.release(); break }
                try? await Task.sleep(for: .seconds(min(left, 120)))
            }
            self?.waiter = nil
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self, let u = self.until, u <= .now { self.release() } }
            }
        }
    }

    /// Looks at the clock now, as at launch and when asked to carry on early.
    func checkNow() { if let u = until, u <= .now { release() } else if until != nil { startWaiting() }; recover() }

    /// The limit is over (or you say it is): parked messages go out, and the sessions it stopped carry on.
    func release() {
        guard until != nil else { return }
        waiter?.cancel(); waiter = nil
        let ws = Workspace.shared
        let sessions = resume.union(parked.keys)
        var resumed = 0
        for id in sessions.sorted() {
            guard let c = ws.controller(id), !c.isBusy || parked[id] != nil else { continue }
            let texts = parked[id] ?? []
            // A chief pilot that was waiting for work is woken by its own waker now that nothing holds it; a second message would only repeat it.
            if texts.isEmpty, c.meta.chief == true, ChiefWaker.shared.entries[c.meta.cwd]?.expecting == true { continue }
            c.loadIfNeeded()
            let typing = c.draft
            if texts.isEmpty { c.draft = Self.resumeText; c.send(byUser: true) }
            else { for t in texts { c.draft = t; c.send(byUser: true) } }
            c.draft = typing
            resumed += 1
            ws.audit.record(AuditEntry(session: id, tool: "usage limit", summary: "Carried on after the limit reset", outcome: "sent"))
        }
        let others = affected.subtracting(sessions).count
        until = nil; message = nil; resume = []; affected = []; parked = [:]
        persist()
        AppModel.shared.notify("Claude's usage limit has reset", body: resumed > 0 ? "\(resumed) session\(resumed == 1 ? "" : "s") carry on by themselves." + (others > 0 ? " \(others) of yours stopped; send a message to continue." : "") : others > 0 ? "\(others) of your sessions stopped; send a message to continue." : "Work can start again.")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Words

    static func clock(_ d: Date) -> String { d.formatted(date: Calendar.current.isDateInToday(d) ? .omitted : .abbreviated, time: .shortened) }

    /// "resumes at 2:01 AM (in 2 hours, 36 minutes)".
    func summary(now: Date = .now) -> String? {
        guard let u = active else { return nil }
        let f = DateComponentsFormatter(); f.allowedUnits = u.timeIntervalSince(now) >= 3600 ? [.hour, .minute] : [.minute]; f.unitsStyle = .full; f.maximumUnitCount = 2
        return "Resumes at \(Self.clock(u)) (in \(f.string(from: max(60, u.timeIntervalSince(now))) ?? "a while"))"
    }

    // MARK: Kept across a restart

    private struct Saved: Codable { var until: Double; var message: String; var resume: [String]; var affected: [String]; var parked: [String: [String]] }

    private func persist() {
        guard let u = until else { UserDefaults.standard.removeObject(forKey: Self.key); return }
        let s = Saved(until: u.timeIntervalSince1970, message: message ?? "", resume: Array(resume), affected: Array(affected), parked: parked)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        until = Date(timeIntervalSince1970: s.until); message = s.message; resume = Set(s.resume); affected = Set(s.affected); parked = s.parked
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One finished turn of one session: what it cost and how long it took.
public struct LedgerEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var session: String
    public var title: String
    public var repo: String
    /// Who started the work: chief, reviewer, task, trigger, phone or you.
    public var source: String
    public var cost: Double
    public var seconds: Double

    public init(date: Date = .now, session: String, title: String, repo: String, source: String, cost: Double, seconds: Double) {
        self.date = date; self.session = session; self.title = title; self.repo = repo; self.source = source; self.cost = cost; self.seconds = seconds
    }
}

/// What the agents have cost, turn by turn, kept for a month so the daily budget and the Settings totals have something to add up. Thread safe.
public final class Ledger: @unchecked Sendable {
    public static let keepDays = 31
    private let url: URL?
    private let lock = NSLock()
    private var rows: [LedgerEntry]

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL? = AppPaths().root.appendingPathComponent("ledger.json")) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        rows = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? dec.decode([LedgerEntry].self, from: $0) } ?? []
    }

    public func add(_ e: LedgerEntry) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = e.date.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        rows = rows.filter { $0.date >= cutoff } + [e]
        save()
    }

    public func entries(since: Date) -> [LedgerEntry] { lock.lock(); defer { lock.unlock() }; return rows.filter { $0.date >= since } }
    public func spent(since: Date) -> Double { entries(since: since).reduce(0) { $0 + $1.cost } }

    public struct Total: Equatable, Sendable { public var source: String; public var cost: Double; public var seconds: Double; public var turns: Int }

    /// Cost, time and turns per source, the most expensive first.
    public func totals(since: Date) -> [Total] {
        var by: [String: Total] = [:]
        for e in entries(since: since) {
            var t = by[e.source] ?? Total(source: e.source, cost: 0, seconds: 0, turns: 0)
            t.cost += e.cost; t.seconds += e.seconds; t.turns += 1
            by[e.source] = t
        }
        return by.values.sorted { $0.cost == $1.cost ? $0.source < $1.source : $0.cost > $1.cost }
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? enc.encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The limits on work that starts without you: how many agents may work at once, and a budget for the day.
public enum Guardrails {
    /// Who started a session, from what is known about it.
    public static func source(of m: SessionMeta) -> String {
        let branch = m.branch ?? ""
        if m.chief == true { return "chief" }
        if m.reviewOf != nil { return "reviewer" }
        if branch.hasPrefix("trigger/") { return "trigger" }
        if branch.hasPrefix("phone/") { return "phone" }
        if branch.hasPrefix("spec-") { return "task" }
        return "you"
    }

    /// Why unattended work should not start now, or nil when it may. A limit of 0 is no limit.
    public static func hold(running: Int, limit: Int, spentToday: Double, budget: Double) -> String? {
        if budget > 0, spentToday >= budget {
            return String(format: "Today's budget of $%.2f is spent ($%.2f). Work that starts by itself waits until tomorrow, or raise the budget in Settings, Limits.", budget, spentToday)
        }
        if limit > 0, running >= limit {
            return "\(running) agent\(running == 1 ? " is" : "s are") working, which is the limit of \(limit). It starts when one finishes."
        }
        return nil
    }

    /// How many more agents may start before the limit.
    public static func slots(running: Int, limit: Int) -> Int { limit > 0 ? max(0, limit - running) : .max }

    public static func startOfDay(_ now: Date = .now, calendar: Calendar = .current) -> Date { calendar.startOfDay(for: now) }
}

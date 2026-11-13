// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Something about a session's usage worth acting on now, with what to do about it.
public struct LensAlert: Equatable, Sendable {
    public enum Kind: String, Sendable { case contextHigh, cacheCold, lowCacheHit, bigResult }
    public var kind: Kind
    public var message: String
}

public enum LensAlerts {
    /// A single tool result above this many characters (about 30k tokens) is flagged: it stays in the conversation and is re-read by every call after it.
    public static let bigResultChars = 120_000
    /// An idle session is only worth warning about when what it would have to write again is large.
    public static let coldMinContext = 50_000

    public static func tokens(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    /// The alerts for one session, most useful first. `largestResultChars` is the biggest single tool result in it.
    public static func alerts(for u: SessionUsage, largestResultChars: Int = 0, now: Date = .now) -> [LensAlert] {
        var out: [LensAlert] = []
        if u.lastContext >= UsageMetrics.forkThreshold {
            out.append(LensAlert(kind: .contextHigh, message: "The conversation is \(tokens(u.lastContext)) tokens. Every call re-reads all of it; continuing in a fresh session from a summary costs a fraction."))
        }
        let idle = now.timeIntervalSince(u.last)
        if idle > u.cacheLife, u.lastContext >= coldMinContext {
            let price = ModelPrice.forModel(u.model).map { " (about \(String(format: "$%.2f", Double(u.lastContext) * $0.write5m / 1_000_000)))" } ?? ""
            out.append(LensAlert(kind: .cacheCold, message: "Idle for \(Int(idle / 60)) minutes, longer than this session's cache lives (\(Int(u.cacheLife / 60)) minutes), so the cache has expired: the next message writes \(tokens(u.lastContext)) tokens again\(price). A short summary in a new session avoids that."))
        }
        if u.calls >= 10, let hit = u.cacheHitRate, hit < 0.8 {
            out.append(LensAlert(kind: .lowCacheHit, message: "Only \(Int(hit * 100))% of what was sent came from the cache. Something near the start of the conversation keeps changing, or pauses keep letting it expire."))
        }
        if largestResultChars >= bigResultChars {
            out.append(LensAlert(kind: .bigResult, message: "One tool result was about \(tokens(largestResultChars / 4)) tokens and is re-read on every call. Ask for less output (a range, a filter, the failures only)."))
        }
        return out
    }
}

/// Who started a piece of work, for splitting usage by source.
public enum UsageOrigin {
    public static let outside = "Claude Code outside CPilot"

    public static func label(_ m: SessionMeta?) -> String {
        guard let m else { return outside }
        if m.chief == true { return "Chief pilot" }
        if m.reviewOf != nil { return "Reviewers" }
        if m.role == "tester" { return "Testers" }
        if m.isWorker { return "Spec tasks" }
        return "You, in CPilot"
    }

    /// Cost and calls added up per origin, largest first. `owner` finds the CPilot session a Claude session id belongs to.
    public static func split(_ usage: [SessionUsage], owner: (String) -> SessionMeta?) -> [(origin: String, calls: Int, cost: Double, sessions: Int)] {
        var by: [String: (Int, Double, Int)] = [:]
        for u in usage { let k = label(owner(u.session)); let o = by[k] ?? (0, 0, 0); by[k] = (o.0 + u.calls, o.1 + (u.cost ?? 0), o.2 + 1) }
        return by.map { (origin: $0.key, calls: $0.value.0, cost: $0.value.1, sessions: $0.value.2) }.sorted { $0.cost > $1.cost }
    }
}

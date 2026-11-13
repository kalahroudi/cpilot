// SPDX-License-Identifier: Apache-2.0

import Foundation

/// When a setting that changes usage was turned on or changed, so its effect can be measured from that day. Thread safe, kept in one small file.
public final class ChangeLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable { public var key: String; public var value: Int; public var date: Date }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [Entry]

    public init(url: URL? = AppPaths().root.appendingPathComponent("lens-changes.json")) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? dec.decode([Entry].self, from: $0) } ?? []
    }

    /// Notes a value for a setting; nothing is written when it is the value already in effect.
    @discardableResult
    public func record(_ key: String, _ value: Int, at date: Date = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entries.last(where: { $0.key == key })?.value == value { return false }
        entries.append(Entry(key: key, value: value, date: date))
        if let url {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? enc.encode(entries).write(to: url, options: .atomic)
        }
        return true
    }

    /// The change that put the setting at its present value.
    public func latest(_ key: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries.last { $0.key == key } }
}

/// Sessions that started before a change against those that started after it. It says "not enough data" rather than a percentage from a handful of sessions.
public enum BeforeAfter {
    public static let minimumSessions = 10

    public struct Side: Equatable, Sendable {
        public var sessions: Int
        public var medianPeakContext: Int
        public var shareAbove: Double
        public var meanCost: Double?
        public var meanCacheHit: Double?
    }

    public struct Result: Equatable, Sendable {
        public var before: Side
        public var after: Side
        public var enough: Bool
        /// Change in the median peak context as a fraction (negative is smaller), only when there is enough data.
        public var peakChange: Double? { enough && before.medianPeakContext > 0 ? Double(after.medianPeakContext - before.medianPeakContext) / Double(before.medianPeakContext) : nil }
        public var costChange: Double? {
            guard enough, let b = before.meanCost, let a = after.meanCost, b > 0 else { return nil }
            return (a - b) / b
        }
    }

    static func side(_ list: [SessionUsage], threshold: Int) -> Side {
        let peaks = list.map(\.peakContext).sorted()
        let costs = list.compactMap(\.cost), hits = list.compactMap(\.cacheHitRate)
        return Side(sessions: list.count, medianPeakContext: peaks.isEmpty ? 0 : peaks[peaks.count / 2],
                    shareAbove: list.isEmpty ? 0 : Double(peaks.filter { $0 >= threshold }.count) / Double(list.count),
                    meanCost: costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count), meanCacheHit: hits.isEmpty ? nil : hits.reduce(0, +) / Double(hits.count))
    }

    /// Sessions with fewer than `minCalls` calls are left out of both sides: a one-off question says nothing about a long-running task.
    public static func compare(_ usage: [SessionUsage], since change: Date, minCalls: Int = 20, threshold: Int = UsageMetrics.forkThreshold) -> Result {
        let long = usage.filter { $0.calls >= minCalls }
        let before = side(long.filter { $0.first < change }, threshold: threshold), after = side(long.filter { $0.first >= change }, threshold: threshold)
        return Result(before: before, after: after, enough: before.sessions >= minimumSessions && after.sessions >= minimumSessions)
    }
}

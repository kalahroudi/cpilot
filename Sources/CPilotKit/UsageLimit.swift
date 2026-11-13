// SPDX-License-Identifier: Apache-2.0

import Foundation

/// "You've hit your session limit · resets 2am (Europe/London)": Claude's own message when the plan's usage is spent. Every message sent before the reset fails the same way at once,
/// so work that starts by itself should wait for the reset instead of asking again. This reads the message and the time it names.
public enum UsageLimit {
    public struct Hit: Equatable, Sendable {
        public var message: String
        /// When the limit lifts, if the message says. Nil when it only says the limit was hit.
        public var resets: Date?
        /// A weekly limit, which can be days away.
        public var weekly: Bool

        /// When to try again: a minute after the reset (so the reset has surely happened), or in half an hour when no time is given. Never in the past.
        public func resumeAt(now: Date = .now) -> Date {
            guard let r = resets else { return now.addingTimeInterval(UsageLimit.unknownWait) }
            return max(r.addingTimeInterval(UsageLimit.margin), now.addingTimeInterval(UsageLimit.minimumWait))
        }
    }

    /// The limit a session's transcript ends with: its last row (notices aside) is Claude's limit message. A session that stopped this way before CPilot was watching,
    /// or while it was closed, is found by this. Anything after the message (you wrote again, the agent worked) means it already carried on.
    public static func stoppedBy(_ items: [ChatItem], now: Date = .now) -> Hit? {
        guard let last = items.last(where: { $0.kind != .notice }), last.kind == .error || last.kind == .assistant else { return nil }
        // Read the time as it was when the message was written: "resets 2am" then means the 2am after it.
        guard let hit = detect(last.text, now: last.ts) else { return nil }
        // Long over and long ago: that work was finished or dropped since, and a message now would only confuse it.
        if (hit.resets ?? last.ts) < now, last.ts < now.addingTimeInterval(-12 * 3600) { return nil }
        return hit
    }

    public static let margin: TimeInterval = 60
    public static let unknownWait: TimeInterval = 30 * 60
    public static let minimumWait: TimeInterval = 120
    static let maxLength = 400

    /// The limit in an error message, or nil for anything else. Only short messages count, so an agent that merely writes about limits is not mistaken for one that hit it.
    public static func detect(_ text: String, now: Date = .now, timeZone: TimeZone = .current) -> Hit? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        guard !t.isEmpty, t.count <= maxLength else { return nil }
        let hit = (l.contains("hit your") && l.contains("limit")) || (l.hasPrefix("claude") && l.contains("usage limit reached")) || (l.contains("limit reached") && l.contains("reset"))
        guard hit else { return nil }
        return Hit(message: t, resets: resetTime(in: t, now: now, timeZone: timeZone), weekly: l.contains("weekly") || l.contains("week"))
    }

    // MARK: The time

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    static func resetTime(in text: String, now: Date, timeZone fallback: TimeZone) -> Date? {
        // Older messages end with an epoch: "Claude AI usage limit reached|1760000000".
        if let e = firstMatch(#"\|\s*(\d{10})\b"#, in: text), let secs = Double(e[1]) { return Date(timeIntervalSince1970: secs) }
        guard let m = firstMatch(#"resets?\s*(?:at|on)?\s*[:\-]?\s*(.+)$"#, in: text) else { return nil }
        var rest = m[1].trimmingCharacters(in: CharacterSet(charactersIn: " .·\n"))
        var tz = fallback
        if let z = firstMatch(#"\(([A-Za-z_]+(?:/[A-Za-z_\-+0-9]+){0,2}|UTC|GMT)\)"#, in: rest) {
            if let found = TimeZone(identifier: z[1]) ?? (z[1].uppercased() == "UTC" || z[1].uppercased() == "GMT" ? TimeZone(identifier: "UTC") : nil) { tz = found }
            rest = rest.replacingOccurrences(of: z[0], with: "")
        }
        // The time of day: "2am", "2:30 pm" or "14:00".
        var hour: Int, minute = 0
        if let t = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: rest) {
            guard var h = Int(t[1]), (1...12).contains(h) else { return nil }
            minute = Int(t[2]) ?? 0
            if t[3].lowercased() == "pm", h != 12 { h += 12 } else if t[3].lowercased() == "am", h == 12 { h = 0 }
            hour = h; rest = rest.replacingOccurrences(of: t[0], with: " ")
        } else if let t = firstMatch(#"\b(\d{1,2}):(\d{2})\b"#, in: rest), let h = Int(t[1]), let mi = Int(t[2]), h < 24, mi < 60 {
            hour = h; minute = mi; rest = rest.replacingOccurrences(of: t[0], with: " ")
        } else { return nil }

        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let today = cal.dateComponents([.year, .month, .day], from: now)
        func date(_ y: Int, _ mo: Int, _ d: Int) -> Date? { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: hour, minute: minute)) }
        let lower = rest.lowercased()

        // "Nov 14", "14 Nov"
        if let d = firstMatch(#"\b([a-z]{3,9})\.?\s+(\d{1,2})\b"#, in: lower) ?? firstMatch(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})\b"#, in: lower).map({ [$0[0], $0[2], $0[1]] }),
           let mo = months.firstIndex(of: String(d[1].prefix(3))), let day = Int(d[2]), let y = today.year, var r = date(y, mo + 1, day) {
            if r < now.addingTimeInterval(-86400) { r = date(y + 1, mo + 1, day) ?? r }
            return r
        }
        if lower.contains("tomorrow"), let y = today.year, let mo = today.month, let d = today.day, let r = date(y, mo, d + 1) { return r }
        if let w = weekdays.firstIndex(where: { lower.range(of: "\\b" + $0, options: .regularExpression) != nil }), let y = today.year, let mo = today.month, let d = today.day {
            let nowWeekday = cal.component(.weekday, from: now) - 1
            var ahead = (w - nowWeekday + 7) % 7
            if ahead == 0, let r = date(y, mo, d), r <= now { ahead = 7 }
            return date(y, mo, d + ahead)
        }
        // Just a time: the next time the clock shows it.
        guard let y = today.year, let mo = today.month, let d = today.day, let r = date(y, mo, d) else { return nil }
        return r > now ? r : date(y, mo, d + 1)
    }
}

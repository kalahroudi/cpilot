// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the chief pilot says on the last line of a turn, in a form CPilot can read without guessing from prose:
/// `STATUS: DONE`, `STATUS: WAITING <what for>`, or `STATUS: BLOCKED <what it needs from the user>`.
public enum ChiefStatus: Equatable, Sendable {
    case done
    case waiting(String)
    case blocked(String)

    /// The last status line in a turn's text, or nil when it has none (an older chief pilot, or one that ignored the format).
    public static func parse(_ text: String) -> ChiefStatus? {
        guard let re = try? NSRegularExpression(pattern: #"^\W*STATUS\W*:?\s*(DONE|WAITING|BLOCKED)\b\W*(.*)$"#, options: .caseInsensitive) else { return nil }
        for raw in text.components(separatedBy: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let w = Range(m.range(at: 1), in: line), let r = Range(m.range(at: 2), in: line) else { continue }
            let why = line[r].trimmingCharacters(in: CharacterSet(charactersIn: "*_` ").union(.whitespaces))
            switch line[w].uppercased() {
            case "DONE": return .done
            case "BLOCKED": return .blocked(why)
            default: return .waiting(why)
            }
        }
        return nil
    }

    /// The format the chief pilot is asked to end every turn with.
    public static let instructions = "End every turn with a last line that is exactly one of `STATUS: DONE` (everything you were asked for is merged, or there is nothing left to do), `STATUS: WAITING <what you wait for>` (CPilot wakes you again), or `STATUS: BLOCKED <what you need from the user>` (only when you cannot unblock yourself). Nothing comes after it."
}

/// Where one repository's chief pilot stands in being woken: the part that must survive a restart.
public struct WakeState: Codable, Equatable, Sendable {
    /// The chief pilot ended a step with work in flight, or has not said it is done.
    public var expecting = true
    /// Work it started has finished since it was last woken.
    public var sawFinish = false
    public var lastWake: Date
    /// Wakes "just to look" since the chief pilot last did something.
    public var looks = 0
    /// The user was told the work is held by a limit, and has not yet been told it is free again.
    public var holdAnnounced = false

    public init(now: Date = .now) { lastWake = now }
}

/// What the waker sees of a repository at one tick.
public struct WakeInputs: Equatable, Sendable {
    public var chiefBusy: Bool
    public var hasPending: Bool
    public var hasAttachments: Bool
    /// Seconds since the chief pilot's session last changed.
    public var quietFor: TimeInterval
    /// A task session, reviewer or spec stage of the repository is working.
    public var workInFlight: Bool
    /// Why unattended work may not start now (the agent cap or the day's budget), if so.
    public var hold: String?
    /// How many agents are working anywhere, so a hold that nothing will lift by itself can be told from one a finishing agent lifts.
    public var runningAgents: Int
    public var status: ChiefStatus?

    public init(chiefBusy: Bool = false, hasPending: Bool = false, hasAttachments: Bool = false, quietFor: TimeInterval = 3600, workInFlight: Bool = false,
                hold: String? = nil, runningAgents: Int = 0, status: ChiefStatus? = nil) {
        self.chiefBusy = chiefBusy; self.hasPending = hasPending; self.hasAttachments = hasAttachments; self.quietFor = quietFor
        self.workInFlight = workInFlight; self.hold = hold; self.runningAgents = runningAgents; self.status = status
    }
}

public enum WakeDecision: Equatable, Sendable {
    /// Nothing to do yet.
    case wait
    /// Send the chief pilot a message: the work it waited for is done, or it is time to look.
    case wake(finished: Bool)
    /// The chief pilot said it is done, so it is left alone.
    case finish
    /// It has waited a long while and nothing changed: tell the user.
    case stalled
    /// It said it cannot go on without the user: tell the user.
    case blocked(String)
    /// A limit keeps work from starting; the user is told once.
    case held(String)
}

/// When the chief pilot is woken. An agent's turn ends when it stops calling tools, and what it started finishes later, so someone has to speak
/// to it again. It is woken when the work it waited for finishes, and otherwise now and then (less often each time) until it says `STATUS: DONE`,
/// says it is blocked on the user, or has waited `maxLooks` times with nothing changing.
public enum ChiefWake {
    /// How long the chief pilot must have been quiet before it is woken.
    public static let settle: TimeInterval = 10
    public static let maxLooks = 12
    public static let tickSeconds: UInt64 = 15

    /// The wait before look number `looks` + 1: three minutes, then longer, never more than ten.
    public static func lookEvery(after looks: Int) -> TimeInterval { min(600, 180 * Double(looks + 1)) }

    public static func decide(_ s: inout WakeState, _ i: WakeInputs, now: Date = .now) -> WakeDecision {
        guard s.expecting else { return .wait }
        // Work finishing is noticed even while the chief pilot is busy, so a short task is not missed between two ticks.
        if i.workInFlight { s.sawFinish = true }
        // Wait for the chief pilot's own turn to end, and for the user to finish with it.
        guard !i.chiefBusy, !i.hasPending, !i.hasAttachments, i.quietFor >= settle, !i.workInFlight else { return .wait }

        switch i.status {
        case .done?:
            s.expecting = false
            return .finish
        case .blocked(let why)?:
            s.expecting = false
            return .blocked(why)
        default: break
        }

        // A limit keeps its work from starting: waking it only gets "held" again. Tell the user once; wake when the limit lifts.
        if let why = i.hold {
            if !s.holdAnnounced { s.holdAnnounced = true; return .held(why) }
            return .wait
        }
        s.holdAnnounced = false

        if s.sawFinish {
            s.sawFinish = false; s.looks = 0; s.lastWake = now
            return .wake(finished: true)
        }
        guard now.timeIntervalSince(s.lastWake) >= lookEvery(after: s.looks) else { return .wait }
        if s.looks >= maxLooks { s.expecting = false; return .stalled }
        s.looks += 1; s.lastWake = now
        return .wake(finished: false)
    }

    /// The chief pilot started something: it is not stalled, and the clock for looking starts again.
    public static func started(_ s: inout WakeState, now: Date = .now) {
        s.expecting = true; s.looks = 0; s.lastWake = now; s.holdAnnounced = false
    }

    public static func message(finished: Bool) -> String {
        if finished {
            return "CPilot: the sessions and jobs you started have finished. Look at where things stand (list_specs, list_sessions, pr_reviews, list_pull_requests, list_stacks) and carry on with the next step. \(ChiefStatus.instructions)"
        }
        return "CPilot: it has been a while. Check whether what you are waiting for (checks, reviewers, a merge) is ready, and carry on if it is. If it is not, say so in one line. \(ChiefStatus.instructions)"
    }
}

/// The wake state of every repository's chief pilot, in a file next to the other app data, so a restart does not leave it waiting for nobody.
/// Thread safe. Entries not touched for a week are dropped.
public final class WakeStore: @unchecked Sendable {
    public static let keepDays = 7
    private let url: URL?
    private let lock = NSLock()
    private var rows: [String: WakeState]

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL? = AppPaths().root.appendingPathComponent("chief-wake.json")) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        rows = (url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? dec.decode([String: WakeState].self, from: $0) } ?? [:]).filter { $0.value.lastWake >= cutoff }
    }

    public func all() -> [String: WakeState] { lock.lock(); defer { lock.unlock() }; return rows }

    public func set(_ s: WakeState?, for repo: String) {
        lock.lock(); defer { lock.unlock() }
        guard rows[repo] != s else { return }
        rows[repo] = s
        save()
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? enc.encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

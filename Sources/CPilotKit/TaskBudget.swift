// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What one session has used, added up from the ledger.
public struct TaskUsage: Codable, Equatable, Sendable {
    public var cost: Double
    public var turns: Int
    /// Seconds an agent spent working (the time between asking and answering), not the time the session stayed open.
    public var seconds: Double
    public init(cost: Double = 0, turns: Int = 0, seconds: Double = 0) { self.cost = cost; self.turns = turns; self.seconds = seconds }

    public static func - (a: TaskUsage, b: TaskUsage) -> TaskUsage { TaskUsage(cost: a.cost - b.cost, turns: a.turns - b.turns, seconds: a.seconds - b.seconds) }
}

extension Ledger {
    public func usage(session: String) -> TaskUsage {
        entries(since: .distantPast).filter { $0.session == session }.reduce(TaskUsage()) { TaskUsage(cost: $0.cost + $1.cost, turns: $0.turns + 1, seconds: $0.seconds + $1.seconds) }
    }
}

/// How much one task may use before it stops and asks the user. An agent that is never told to stop will keep going: the gate sends it back, it
/// is nudged, it is woken. These limits are what ends that. A limit of 0 is off. Cost is what the agent reports; one that reports none is limited by turns and time.
public struct TaskBudget: Equatable, Sendable {
    public var dollars: Int
    public var turns: Int
    public var minutes: Int
    public init(dollars: Int, turns: Int, minutes: Int) { self.dollars = dollars; self.turns = turns; self.minutes = minutes }

    /// Why the task has used too much, or nil. `since` is where the count started: 0 for a new task, or the use at the moment the user last stepped in.
    public func exceeded(used: TaskUsage, since: TaskUsage? = nil) -> String? {
        let u = since.map { used - $0 } ?? used
        if dollars > 0, u.cost >= Double(dollars) { return String(format: "It has spent $%.2f, which is the limit of $%d for one task.", u.cost, dollars) }
        if turns > 0, u.turns >= turns { return "It has taken \(u.turns) turns, which is the limit of \(turns) for one task." }
        if minutes > 0, u.seconds >= Double(minutes) * 60 { return "It has worked for \(Int(u.seconds / 60)) minutes, which is the limit of \(minutes) for one task." }
        return nil
    }
}

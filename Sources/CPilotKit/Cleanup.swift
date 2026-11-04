// SPDX-License-Identifier: Apache-2.0

import Foundation

/// When work the chief pilot drove is delivered, what is left of it goes: first the checkout (the disk), then the session (the list), and in the end
/// the record. Only sessions CPilot started on its own are touched; yours never are. Nothing is removed that holds work that exists nowhere else.
public enum CleanupPolicy {
    /// How long a session with no pull request may sit untouched before it counts as abandoned.
    public static let staleDays = 14
    /// A session used in the last hour is left alone, whatever its state.
    public static let minIdle: TimeInterval = 3600
    /// How long an archived folder that no session owns is kept before it is removed.
    public static let orphanDays = 7

    public enum PRState: String, Sendable { case none, open, merged, closed }

    public struct Facts: Equatable, Sendable {
        /// Started by the chief pilot, a trigger or a combine, not by you.
        public var automatic: Bool
        public var busy: Bool
        public var archived: Bool
        /// The session's checkout still exists on disk.
        public var hasWorktree: Bool
        public var uncommitted: Int
        /// Every commit on the branch is on a remote or in its pull request.
        public var onRemote: Bool
        public var pr: PRState
        /// Since the session was last used.
        public var idle: TimeInterval
        /// Since it was archived, when that is known.
        public var archivedFor: TimeInterval?
        public init(automatic: Bool, busy: Bool = false, archived: Bool = false, hasWorktree: Bool = true, uncommitted: Int = 0, onRemote: Bool = true,
                    pr: PRState = .none, idle: TimeInterval = 0, archivedFor: TimeInterval? = nil) {
            self.automatic = automatic; self.busy = busy; self.archived = archived; self.hasWorktree = hasWorktree; self.uncommitted = uncommitted
            self.onRemote = onRemote; self.pr = pr; self.idle = idle; self.archivedFor = archivedFor
        }
    }

    public enum Action: Equatable, Sendable {
        /// Leave it, for this reason.
        case keep(String)
        /// Its work is delivered: remove the checkout when `release` (there is one), then put the session away.
        case finish(release: Bool)
        /// Remove the session for good.
        case delete
    }

    /// `keepArchivedDays` is how long a put-away session is kept before it is deleted; 0 keeps them for ever.
    public static func decide(_ f: Facts, keepArchivedDays: Int) -> Action {
        guard f.automatic else { return .keep("started by you") }
        if f.busy { return .keep("working now") }
        if f.idle < minIdle { return .keep("used in the last hour") }

        if f.archived, !f.hasWorktree {
            guard keepArchivedDays > 0 else { return .keep("kept for ever by your setting") }
            let age = f.archivedFor ?? f.idle
            return age >= Double(keepArchivedDays) * 86_400 ? .delete : .keep("kept \(keepArchivedDays) days after it was put away")
        }

        switch f.pr {
        case .open: return .keep("its pull request is open")
        case .none where f.idle < Double(staleDays) * 86_400: return .keep("no pull request yet and used in the last \(staleDays) days")
        default: break
        }
        if f.hasWorktree {
            if f.uncommitted > 0 { return .keep("its checkout has changes that are not committed") }
            if !f.onRemote { return .keep("its checkout has commits that are on no remote") }
        }
        if f.archived, !f.hasWorktree { return .keep("already put away") }
        return .finish(release: f.hasWorktree)
    }

    /// Folders under the worktrees root that no session owns and git no longer lists, untouched for a week. `entries` are (folder name, last change).
    public static func orphans(entries: [(name: String, modified: Date)], owned: Set<String>, now: Date = .now) -> [String] {
        entries.filter { !owned.contains($0.name) && now.timeIntervalSince($0.modified) >= Double(orphanDays) * 86_400 }.map(\.name)
    }

    /// Sessions CPilot started on its own: the chief pilot's tasks and reviewers, triggers, and the sessions that combine stacks.
    public static func isAutomatic(_ m: SessionMeta) -> Bool {
        if m.chief == true { return false }
        if ["task", "reviewer", "trigger"].contains(Guardrails.source(of: m)) { return true }
        return (m.branch ?? "").hasPrefix("collapse-")
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import CPilotKit

/// Clears away what the chief pilot's work leaves behind once it is delivered: the checkout of each task and reviewer whose pull request is merged or
/// closed (the disk), then the session itself (the list), and in the end its record. What to do with each session is decided by `CleanupPolicy`; this
/// gathers the facts, does it, and says what it did. Only this Mac's sessions, and only the ones CPilot started on its own.
@MainActor @Observable
final class CleanupCenter {
    static let shared = CleanupCenter()

    struct Report: Equatable {
        var date = Date()
        var released = 0, archived = 0, deleted = 0, folders = 0
        var bytes: Int64 = 0
        var kept: [String: Int] = [:]

        var headline: String {
            var parts: [String] = []
            if released > 0 { parts.append("removed \(released) checkout\(released == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))") }
            if folders > 0 { parts.append("\(folders) leftover folder\(folders == 1 ? "" : "s")") }
            if archived > 0 { parts.append("put away \(archived) session\(archived == 1 ? "" : "s")") }
            if deleted > 0 { parts.append("deleted \(deleted)") }
            return parts.isEmpty ? "nothing to clean" : parts.joined(separator: ", ")
        }

        /// Why some were left, most common first, so "nothing happened" is explained.
        var detail: String {
            let why = kept.filter { $0.key != "started by you" }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4)
            return why.isEmpty ? "Everything it looked at was dealt with." : "Left alone: " + why.map { "\($0.value) (\($0.key))" }.joined(separator: ", ") + "."
        }
    }

    private(set) var last: Report?
    private(set) var running = false
    private var lastRun = Date.distantPast
    /// A look every few hours, and no closer than ten minutes after a chief pilot run ends.
    static let every: TimeInterval = 6 * 3600, gap: TimeInterval = 600

    func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            while true {
                _ = await sweep(manual: false)
                try? await Task.sleep(for: .seconds(Self.every))
            }
        }
    }

    func chiefTurnEnded(_ c: SessionController) {
        guard Prefs.shared.cleanUp, c.meta.environment == nil, ChiefWaker.isDone(c), Date().timeIntervalSince(lastRun) > Self.gap else { return }
        Task { _ = await sweep(manual: false) }
    }

    /// What GitHub knows about a repository's pull requests, by branch and by number.
    private struct PRIndex {
        var byHead: [String: PullRequest] = [:]
        var byNumber: [Int: PullRequest] = [:]
        /// The newest open one wins, then a merged one, then a closed one: a branch can have had several.
        init(_ list: [PullRequest]) {
            func rank(_ p: PullRequest) -> Int { p.state == "OPEN" ? 2 : p.state == "MERGED" ? 1 : 0 }
            for p in list {
                byNumber[p.number] = p
                if let cur = byHead[p.headRefName], rank(cur) >= rank(p) { continue }
                byHead[p.headRefName] = p
            }
        }
    }

    @discardableResult
    func sweep(manual: Bool) async -> Report {
        guard !running, manual || Prefs.shared.cleanUp else { return last ?? Report() }
        running = true; lastRun = .now
        defer { running = false }
        let ws = Workspace.shared
        var report = Report()
        let everyone = ws.store.list(includeArchived: true)
        let mine = everyone.filter { $0.environment == nil && CleanupPolicy.isAutomatic($0) }

        var indexes: [String: PRIndex?] = [:]
        var lookups = 15          // single pull request lookups for reviewers that fell off the list, per sweep
        for m in mine {
            guard FileManager.default.fileExists(atPath: m.cwd) else { continue }
            if indexes[m.cwd] == nil { indexes[m.cwd] = (try? await GitHub.list(in: m.cwd, state: "all", limit: 200)).map(PRIndex.init) }
            let index = indexes[m.cwd] ?? nil

            var pr = m.reviewOf.flatMap { index?.byNumber[$0] } ?? m.branch.flatMap { index?.byHead[$0] }
            if pr == nil, index != nil, let n = m.reviewOf, lookups > 0 { lookups -= 1; pr = try? await GitHub.view(n, in: m.cwd) }
            let state: CleanupPolicy.PRState = index == nil ? .open : pr.map { $0.state == "OPEN" ? .open : $0.state == "MERGED" ? .merged : .closed } ?? .none   // no answer from GitHub keeps everything

            let has = m.worktree.map { FileManager.default.fileExists(atPath: $0) } ?? false
            var uncommitted = 0, onRemote = true
            if has, let wt = m.worktree, !m.archived || state != .open {
                let w = await Git.unsavedWork(wt)
                uncommitted = w.uncommitted
                onRemote = w.unpushed == 0
                if !onRemote, let oid = pr?.headRefOid { onRemote = await Git.isReachable(wt, from: oid) }
            }
            // Only checkouts this app made are ever removed; a session pointing anywhere else is left as if you had started it.
            let inRoot = m.worktree.map { $0.hasPrefix(Self.worktreesRoot + "/") } ?? true
            let facts = CleanupPolicy.Facts(automatic: inRoot, busy: ws.isActive(m.id) || ws.selected == m.id, archived: m.archived, hasWorktree: has,
                                            uncommitted: uncommitted, onRemote: onRemote, pr: state, idle: Date().timeIntervalSince(m.updatedAt),
                                            archivedFor: m.archivedAt.map { Date().timeIntervalSince($0) })
            switch CleanupPolicy.decide(facts, keepArchivedDays: Prefs.shared.keepArchivedDays) {
            case .keep(let why):
                report.kept[why, default: 0] += 1
            case .finish(let release):
                let why = state == .merged ? "its pull request merged" : state == .closed ? "its pull request closed" : "no activity for \(CleanupPolicy.staleDays) days"
                if release, let wt = m.worktree {
                    let size = await Self.size(of: wt)
                    await Self.release(m, at: wt)
                    report.released += 1; report.bytes += size
                    ws.audit.record(AuditEntry(session: m.id, tool: "cleanup", summary: "Removed the checkout of \(m.title) (\(why), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", outcome: "done"))
                }
                if !m.archived {
                    ws.archive(m.id); report.archived += 1
                    ws.audit.record(AuditEntry(session: m.id, tool: "cleanup", summary: "Put away \(m.title) (\(why))", outcome: "done"))
                }
            case .delete:
                ws.forget(m.id); report.deleted += 1
                ws.audit.record(AuditEntry(session: m.id, tool: "cleanup", summary: "Deleted \(m.title), put away \(Prefs.shared.keepArchivedDays) days ago or more", outcome: "done"))
            }
        }

        let (folders, bytes) = await removeOrphans(everyone: everyone)
        report.folders = folders; report.bytes += bytes
        last = report
        return report
    }

    /// Removes a session's checkout. Its scratch branch (a reviewer's `review-…`) goes with it; a task's own branch stays, as the stacks may still use its name.
    private static func release(_ m: SessionMeta, at wt: String) async {
        let branch = await Git.currentBranch(wt)
        await Git.removeWorktree(repo: m.cwd, path: wt)
        // Git refuses to remove some checkouts (a lock, a missing repository); the folder is this app's own, so what is left of it can go.
        if FileManager.default.fileExists(atPath: wt) { try? FileManager.default.removeItem(atPath: wt) }
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: URL(fileURLWithPath: m.cwd))
        if let b = branch, b.hasPrefix("review-") { await Git.deleteBranch(repo: m.cwd, branch: b); await Stacks.untrack(b, in: m.cwd) }
    }

    /// Folders in the worktrees root that no session owns and no repository lists, untouched for a week.
    private static var worktreesRoot: String { AppPaths().root.appendingPathComponent("worktrees").path }

    private func removeOrphans(everyone: [SessionMeta]) async -> (Int, Int64) {
        let root = AppPaths().root.appendingPathComponent("worktrees")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path), !names.isEmpty else { return (0, 0) }
        var owned = Set(everyone.compactMap { $0.worktree }.map { ($0 as NSString).lastPathComponent })
        for repo in Set(everyone.map(\.cwd)) where fm.fileExists(atPath: repo) {
            let out = (try? await Shell.check("git", ["worktree", "list", "--porcelain"], cwd: URL(fileURLWithPath: repo))) ?? ""
            for line in out.split(separator: "\n") where line.hasPrefix("worktree ") { owned.insert((String(line.dropFirst(9)) as NSString).lastPathComponent) }
            _ = try? await Shell.run("git", ["worktree", "prune"], cwd: URL(fileURLWithPath: repo))
        }
        let entries = names.compactMap { n -> (name: String, modified: Date)? in
            let p = root.appendingPathComponent(n).path
            guard let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return nil }
            // A checkout whose repository still knows it is not an orphan, whatever the list said.
            if let gitFile = try? String(contentsOfFile: p + "/.git", encoding: .utf8), gitFile.hasPrefix("gitdir: "),
               fm.fileExists(atPath: String(gitFile.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)) { return nil }
            return (n, d)
        }
        var count = 0, bytes: Int64 = 0
        for name in CleanupPolicy.orphans(entries: entries, owned: owned) {
            let path = root.appendingPathComponent(name).path
            let size = await Self.size(of: path)
            guard (try? fm.removeItem(atPath: path)) != nil else { continue }
            count += 1; bytes += size
            Workspace.shared.audit.record(AuditEntry(session: "", tool: "cleanup", summary: "Removed the leftover folder \(name) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))", outcome: "done"))
        }
        return (count, bytes)
    }

    private static func size(of path: String) async -> Int64 {
        let out = (try? await Shell.run("du", ["-sk", path], timeout: 60))?.stdout ?? ""
        return (Int64(out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") ?? 0) * 1024
    }
}

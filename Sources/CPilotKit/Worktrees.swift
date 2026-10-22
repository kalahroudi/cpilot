// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One checkout of a repository: the folder you work in, a session's copy, a copy made for a restack, or one made by hand.
public struct WorktreeInfo: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case main, restack, session, other }
    public var path: String
    public var branch: String?
    public var head: String
    public var kind: Kind
    public var uncommitted = 0
    public var unpushed = 0
    /// The folder is gone but git still lists it. Pruning clears it.
    public var missing = false
    public var locked = false
    public var rebasing = false
    public var id: String { path }
    /// Removing it would lose work that exists nowhere else.
    public var holdsWork: Bool { uncommitted > 0 || unpushed > 0 }
}

public enum Worktrees {
    static func parse(_ porcelain: String) -> [(path: String, head: String, branch: String?, locked: Bool, prunable: Bool)] {
        porcelain.components(separatedBy: "\n\n").compactMap { block in
            var path: String?, head = "", branch: String?, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5).prefix(8)) }
                else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            return path.map { ($0, head, branch, locked, prunable) }
        }
    }

    /// Every checkout of the repository, the main one first. `sessionPaths` are the folders sessions own, so the rest can be called leftovers.
    public static func list(in dir: String, sessionPaths: Set<String> = []) async -> [WorktreeInfo] {
        let out = (try? await Shell.check("git", ["worktree", "list", "--porcelain"], cwd: URL(fileURLWithPath: dir))) ?? ""
        let jobPaths = Set(await Stacks.jobs(in: dir).map(\.path))
        let restackRoot = Stacks.restackRoot()
        var list: [WorktreeInfo] = []
        for (i, w) in parse(out).enumerated() {
            let kind: WorktreeInfo.Kind = i == 0 ? .main
                : jobPaths.contains(w.path) || w.path.hasPrefix(restackRoot + "/") ? .restack
                : sessionPaths.contains(w.path) ? .session : .other
            var info = WorktreeInfo(path: w.path, branch: w.branch, head: w.head, kind: kind, missing: w.prunable, locked: w.locked)
            if !w.prunable {
                let work = await Git.unsavedWork(w.path)
                info.uncommitted = work.uncommitted; info.unpushed = work.unpushed
                info.rebasing = await Stacks.rebaseInProgress(in: w.path)
            }
            list.append(info)
        }
        return list
    }

    /// Removes a checkout, and its branch when asked and nothing on it would be lost. Never the main folder.
    public static func remove(_ w: WorktreeInfo, in dir: String, deleteBranch: Bool) async throws {
        guard w.kind != .main else { throw StackError.message("That is the folder you work in. It cannot be removed here.") }
        if let job = await Stacks.jobs(in: dir).first(where: { $0.path == w.path }) {
            _ = try? await Shell.run("git", ["rebase", "--abort"], cwd: URL(fileURLWithPath: w.path))
            await Stacks.dropJob(job, in: dir)
        } else {
            if w.locked { _ = try? await Shell.run("git", ["worktree", "unlock", w.path], cwd: URL(fileURLWithPath: dir)) }
            let r = try await Shell.run("git", ["worktree", "remove", "--force", w.path], cwd: URL(fileURLWithPath: dir))
            if !r.ok && !w.missing { throw StackError.message(r.stderr.split(separator: "\n").first.map(String.init) ?? "git could not remove \(w.path).") }
        }
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: URL(fileURLWithPath: dir))
        if deleteBranch, let b = w.branch, !w.holdsWork { await Git.deleteBranch(repo: dir, branch: b); await Stacks.untrack(b, in: dir) }
    }

    /// Clears records of folders that no longer exist.
    public static func prune(in dir: String) async {
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: URL(fileURLWithPath: dir))
    }
}

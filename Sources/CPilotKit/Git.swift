// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RepoInfo: Equatable, Sendable {
    public var root: String
    public var branch: String
    public var remote: String?          // owner/name on GitHub
    public var dirty: Bool
    public var isClean: Bool { !dirty }
}

/// Plain git, run through the user's own git so credentials and config just work.
public enum Git {
    static func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    public static func isRepo(_ dir: String) async -> Bool {
        (try? await Shell.run("git", ["rev-parse", "--is-inside-work-tree"], cwd: url(dir)))?.stdout.hasPrefix("true") ?? false
    }

    public static func info(_ dir: String) async -> RepoInfo? {
        guard await isRepo(dir) else { return nil }
        let root = (try? await Shell.check("git", ["rev-parse", "--show-toplevel"], cwd: url(dir)))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? dir
        let branch = (try? await Shell.check("git", ["branch", "--show-current"], cwd: url(dir)))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteURL = (try? await Shell.check("git", ["remote", "get-url", "origin"], cwd: url(dir)))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (try? await Shell.check("git", ["status", "--porcelain"], cwd: url(dir))) ?? ""
        return RepoInfo(root: root, branch: branch, remote: remoteURL.flatMap(slug(fromRemote:)), dirty: !status.isEmpty)
    }

    /// `https://github.com/o/r.git`, `git@github.com:o/r.git` or `https://user@github.com/o/r` all give `o/r`.
    public static func slug(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = s.range(of: "github.com") else { return nil }
        s = String(s[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/")
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    public static func defaultBranch(_ dir: String) async -> String {
        let r = (try? await Shell.check("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: url(dir)))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r, r.hasPrefix("origin/") { return String(r.dropFirst(7)) }
        return "main"
    }

    /// The newest default branch to start a session from: the remote's after a fetch, else the local one.
    public static func freshBase(_ dir: String) async -> String {
        let name = await defaultBranch(dir)
        _ = try? await Shell.run("git", ["fetch", "origin", name], cwd: url(dir), timeout: 60)
        let remote = "origin/\(name)"
        let ok = (try? await Shell.run("git", ["rev-parse", "--verify", "--quiet", remote], cwd: url(dir)))?.ok ?? false
        return ok ? remote : name
    }

    public static func slugify(_ title: String) -> String {
        let s = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").prefix(6).joined(separator: "-")
        return joined.isEmpty ? "session" : joined
    }

    /// `name` if no branch has it, locally or on origin, else `name-2`, `name-3` and so on. A new session must never pick up an old branch, with its commits and merged pull request.
    public static func uniqueBranch(_ name: String, in dir: String) async -> String {
        func taken(_ n: String) async -> Bool {
            for ref in ["refs/heads/\(n)", "refs/remotes/origin/\(n)"] {
                if (try? await Shell.run("git", ["rev-parse", "--verify", "--quiet", ref], cwd: url(dir)))?.ok == true { return true }
            }
            return false
        }
        if !(await taken(name)) { return name }
        var i = 2
        while await taken("\(name)-\(i)") { i += 1 }
        return "\(name)-\(i)"
    }

    public static func createBranch(_ name: String, in dir: String) async throws {
        try await Shell.check("git", ["checkout", "-b", name], cwd: url(dir))
    }

    /// A separate checkout for one session, so parallel sessions never touch each other's files.
    public static func addWorktree(repo: String, branch: String, base: String, to path: String) async throws {
        try await Shell.check("git", ["worktree", "add", "--no-track", "-b", branch, path, base], cwd: url(repo))
    }

    /// A copy of the files on a branch that already exists (a task started before), keeping its commits. Stale worktree records are cleared first so a deleted copy does not hold the branch.
    public static func addWorktreeOnExisting(repo: String, branch: String, to path: String) async throws {
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: url(repo))
        try await Shell.check("git", ["worktree", "add", path, branch], cwd: url(repo))
    }

    public static func branchExists(_ name: String, in dir: String) async -> Bool {
        (try? await Shell.run("git", ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], cwd: url(dir)))?.ok == true
    }

    public static func removeWorktree(repo: String, path: String) async {
        _ = try? await Shell.run("git", ["worktree", "remove", "--force", path], cwd: url(repo))
    }

    public static func push(_ dir: String, branch: String) async throws {
        try await Shell.check("git", ["push", "-u", "origin", branch], cwd: url(dir), timeout: 120)
    }

    public static func diff(_ dir: String, base: String) async -> String {
        (try? await Shell.check("git", ["diff", "\(base)...HEAD"], cwd: url(dir), timeout: 60)) ?? ""
    }

    public static func uncommittedCount(_ dir: String) async -> Int {
        let out = (try? await Shell.check("git", ["status", "--porcelain"], cwd: url(dir))) ?? ""
        return out.split(separator: "\n").count
    }

    /// Commits on HEAD that `base` doesn't have.
    public static func commitsAhead(_ dir: String, of base: String) async -> Int {
        let out = (try? await Shell.check("git", ["rev-list", "--count", "\(base)..HEAD"], cwd: url(dir))) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public static func commitAll(_ dir: String, message: String) async throws {
        try await Shell.check("git", ["add", "-A"], cwd: url(dir))
        try await Shell.check("git", ["commit", "-m", message], cwd: url(dir))
    }

    public struct Commit: Identifiable, Equatable, Sendable {
        public var sha: String
        public var subject: String
        public var when: String
        public var id: String { sha }
        public init(sha: String, subject: String, when: String) { self.sha = sha; self.subject = subject; self.when = when }
    }

    /// Commits on HEAD that `base` doesn't have, newest first.
    public static func commits(_ dir: String, since base: String, limit: Int = 50) async -> [Commit] {
        let out = (try? await Shell.check("git", ["log", "--format=%h%x09%s%x09%cr", "-\(limit)", "\(base)..HEAD"], cwd: url(dir))) ?? ""
        return parseCommits(out)
    }

    static func parseCommits(_ out: String) -> [Commit] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return f.count == 3 ? Commit(sha: f[0], subject: f[1], when: f[2]) : nil
        }
    }

    /// Work that exists only in this checkout: uncommitted changes, and commits no remote branch has.
    public static func unsavedWork(_ dir: String) async -> (uncommitted: Int, unpushed: Int) {
        let unpushed = (try? await Shell.check("git", ["rev-list", "--count", "HEAD", "--not", "--remotes"], cwd: url(dir))) ?? ""
        return (await uncommittedCount(dir), Int(unpushed.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    /// Deletes a local branch once nothing needs it. `-D` because a squash merge leaves it looking unmerged.
    public static func deleteBranch(repo: String, branch: String) async {
        _ = try? await Shell.run("git", ["branch", "-D", branch], cwd: url(repo))
    }

    /// A title the pull request would add to the base branch that the base branch already has.
    public struct Duplicate: Equatable, Identifiable, Sendable {
        public var subject: String
        /// What carries the title here: a commit's short sha, or "title" for the pull request's own title.
        public var mine: String
        public var onBase: String
        /// Found by comparing the changes themselves (the same diff under another title), not the titles.
        public var sameChange = false
        public var id: String { mine + onBase }
    }

    /// "Fix the thing (#12)" and "fix the thing" are the same title.
    static func normalizeSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = t.range(of: #" \(#\d+\)$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    /// Which of `mine` (label, subject) already appear as titles in `baseLog`. This is how the same change ends up on main twice.
    public static func findDuplicates(_ mine: [(label: String, subject: String)], baseLog: [Commit]) -> [Duplicate] {
        var seen = Set<String>(), out: [Duplicate] = []
        for m in mine {
            let key = normalizeSubject(m.subject)
            guard !key.isEmpty, let hit = baseLog.first(where: { normalizeSubject($0.subject) == key }), seen.insert(hit.sha).inserted else { continue }
            out.append(Duplicate(subject: hit.subject, mine: m.label, onBase: hit.sha))
        }
        return out
    }

    /// Recent titles on the remote base branch. Fetches that one branch first, so it is not judged against a stale copy.
    public static func baseLog(_ dir: String, base: String, limit: Int = 1500) async -> [Commit] {
        _ = try? await Shell.run("git", ["fetch", "origin", base], cwd: url(dir), timeout: 60)
        let out = (try? await Shell.check("git", ["log", "--format=%h%x09%s%x09%cr", "-\(limit)", "origin/\(base)"], cwd: url(dir))) ?? ""
        return parseCommits(out)
    }

    /// Commits of `head` whose exact change is already in `base`, even under another title (`git cherry` compares patch ids).
    public static func alreadyOnBase(_ dir: String, base: String, head: String, subjects: [String: String]) async -> [Duplicate] {
        let out = (try? await Shell.check("git", ["cherry", "origin/\(base)", head], cwd: url(dir), timeout: 60)) ?? ""
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 2, f[0] == "-" else { return nil }
            let sha = String(f[1].prefix(7))
            return Duplicate(subject: subjects[sha] ?? "", mine: sha, onBase: "", sameChange: true)
        }
    }

    /// Merge commits inside the branch. A rebase merge would flatten them away, so squash or a merge commit is the safer choice.
    public static func mergeCommitCount(_ dir: String, base: String, head: String) async -> Int {
        let out = (try? await Shell.check("git", ["rev-list", "--merges", "--count", "origin/\(base)..\(head)"], cwd: url(dir))) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// After a merge: the files of the pull request whose content on `base` differs from the pull request's last commit.
    /// Empty means everything it changed is on `base` exactly as reviewed.
    public static func filesDiffering(_ dir: String, head: String, base: String, files: [String]) async -> [String] {
        guard !files.isEmpty else { return [] }
        _ = try? await Shell.run("git", ["fetch", "origin", base], cwd: url(dir), timeout: 60)
        let out = (try? await Shell.check("git", ["diff", "--name-only", head, "origin/\(base)", "--"] + files, cwd: url(dir), timeout: 60)) ?? ""
        return out.split(separator: "\n").map(String.init)
    }
}

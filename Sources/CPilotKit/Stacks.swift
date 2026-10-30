// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A branch in a stack: the branch it sits on, the commit it was last built on, and where it stands.
public struct StackBranch: Identifiable, Equatable, Sendable, Codable {
    public var name: String
    public var parent: String
    /// The parent's tip when this branch was last created or restacked.
    public var base: String?
    public var needsRestack = false
    public var commits = 0
    public var depth = 0
    public var pr: Int?
    public var prState: String?        // OPEN, MERGED, CLOSED
    /// The remote has this branch at exactly the local tip.
    public var pushed = false
    public var title: String?
    /// The pull request's head commit when the stack was read.
    public var prHead: String?
    /// GitHub's merge verdict for the pull request (`mergeStateStatus`), as of the last read.
    public var mergeState: String?
    public var id: String { name }
    public var isMerged: Bool { prState == "MERGED" }
    public init(name: String, parent: String, base: String?, needsRestack: Bool = false, commits: Int = 0, depth: Int = 0, pr: Int? = nil, prState: String? = nil, title: String? = nil) {
        self.name = name; self.parent = parent; self.base = base; self.needsRestack = needsRestack; self.commits = commits; self.depth = depth; self.pr = pr; self.prState = prState; self.title = title
    }
}

public struct Stack: Equatable, Sendable, Identifiable, Codable {
    public var trunk: String
    /// Bottom first.
    public var branches: [StackBranch]
    /// Commits the remote trunk has that the local trunk does not (as of the last fetch). The stack cannot be restacked correctly until it is synced.
    public var trunkBehind = 0
    public var id: String { branches.first?.name ?? trunk }
    public var needsRestack: Bool { branches.contains { $0.needsRestack || $0.isMerged } }
    /// Branches Submit would act on: no open pull request yet, or commits the remote has not seen.
    public var unsubmitted: [StackBranch] { branches.filter { !$0.isMerged && $0.commits > 0 && ($0.prState != "OPEN" || !$0.pushed) } }
    /// The lowest pull request still open, the one "Merge from the bottom" would merge.
    public var bottomOpen: StackBranch? { branches.first { !$0.isMerged && $0.prState == "OPEN" } }
    /// What to do next, in order: sync, restack, submit, merge.
    public var nextStep: Step? {
        if trunkBehind > 0 { return .sync }
        if needsRestack { return .restack }
        if !unsubmitted.isEmpty { return .submit }
        return bottomOpen == nil ? nil : .merge
    }
    public enum Step: Sendable { case sync, restack, submit, merge }
    public init(trunk: String, branches: [StackBranch]) { self.trunk = trunk; self.branches = branches }
}

extension StackHost {
    public func merge(_ number: Int, method: MergeMethod, expectedHead: String?) async throws { try await merge(number, method: method) }
    public func merge(_ number: Int, method: MergeMethod, expectedHead: String?, admin: Bool) async throws { try await merge(number, method: method, expectedHead: expectedHead) }
    public func close(_ number: Int, comment: String) async throws {}
}

/// What a stack needs from GitHub. The live version uses the GitHub command line; tests use a stand-in.
public protocol StackHost: Sendable {
    func pullRequests() async -> [PullRequest]
    func create(head: String, base: String, title: String, body: String, draft: Bool) async throws -> Int
    func setBase(_ number: Int, base: String) async throws
    func setBody(_ number: Int, body: String) async throws
    func merge(_ number: Int, method: MergeMethod) async throws
    /// Merges only if the branch is still at `expectedHead`; a push made after the stack was read is never left out and then deleted.
    func merge(_ number: Int, method: MergeMethod, expectedHead: String?) async throws
    /// `admin` merges past the repository's rules. Only ever on the user's explicit confirmation, never from auto-merge.
    func merge(_ number: Int, method: MergeMethod, expectedHead: String?, admin: Bool) async throws
    /// Closes a pull request with a comment saying why. Used when a stack is collapsed into one pull request.
    func close(_ number: Int, comment: String) async throws
}

public struct LiveStackHost: StackHost {
    let dir: String
    public init(dir: String) { self.dir = dir }
    private var cwd: URL { URL(fileURLWithPath: dir) }
    public func pullRequests() async -> [PullRequest] {
        guard let out = try? await Shell.check("gh", ["pr", "list", "--state", "all", "--limit", "100", "--json", PullRequest.listFields], cwd: cwd),
              let l = try? JSONDecoder().decode([PullRequest].self, from: Data(out.utf8)) else { return [] }
        return l
    }
    public func create(head: String, base: String, title: String, body: String, draft: Bool) async throws -> Int {
        var a = ["pr", "create", "--head", head, "--base", base, "--title", title, "--body", body]
        if draft { a.append("--draft") }
        let url = try await Shell.check("gh", a, cwd: cwd, timeout: 90).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(url.split(separator: "/").last ?? "") ?? 0
    }
    public func setBase(_ number: Int, base: String) async throws { try await Shell.check("gh", ["pr", "edit", String(number), "--base", base], cwd: cwd, timeout: 60) }
    public func setBody(_ number: Int, body: String) async throws { try await Shell.check("gh", ["pr", "edit", String(number), "--body", body], cwd: cwd, timeout: 60) }
    public func merge(_ number: Int, method: MergeMethod) async throws { try await GitHub.merge(number, method: method, auto: false, in: dir) }
    public func merge(_ number: Int, method: MergeMethod, expectedHead: String?) async throws { try await GitHub.merge(number, method: method, auto: false, expectedHead: expectedHead, in: dir) }
    public func merge(_ number: Int, method: MergeMethod, expectedHead: String?, admin: Bool) async throws { try await GitHub.merge(number, method: method, auto: false, admin: admin, expectedHead: expectedHead, in: dir) }
    public func close(_ number: Int, comment: String) async throws { try await Shell.check("gh", ["pr", "close", String(number), "--comment", comment], cwd: cwd, timeout: 60) }
}

public enum StackError: Error, LocalizedError, Equatable {
    case dirty, conflict(branch: String, files: [String]), notTracked(String), message(String)
    public var errorDescription: String? {
        switch self {
        case .dirty: return "There are uncommitted changes. Commit or stash them first."
        case .conflict(let b, let f): return "Restacking \(b) hit a conflict in \(f.prefix(3).joined(separator: ", "))\(f.count > 3 ? "…" : "")."
        case .notTracked(let b): return "\(b) is not part of a stack."
        case .message(let m): return m
        }
    }
}

public enum Stacks {
    static func cwd(_ d: String) -> URL { URL(fileURLWithPath: d) }

    @discardableResult
    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 60) async throws -> String {
        try await Shell.check("git", args, cwd: cwd(dir), timeout: timeout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gitOK(_ args: [String], in dir: String) async -> Bool {
        (try? await Shell.run("git", args, cwd: cwd(dir), timeout: 60))?.ok ?? false
    }

    // MARK: Metadata (kept in the repository's own git config, so it needs no extra files)

    public static func setParent(_ branch: String, to parent: String, base: String?, in dir: String) async throws {
        try await git(["config", "branch.\(branch).cpilot-parent", parent], in: dir)
        if let base { try await git(["config", "branch.\(branch).cpilot-base", base], in: dir) }
    }

    public static func untrack(_ branch: String, in dir: String) async {
        _ = try? await Shell.run("git", ["config", "--unset", "branch.\(branch).cpilot-parent"], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["config", "--unset", "branch.\(branch).cpilot-base"], cwd: cwd(dir))
    }

    public static func trunk(in dir: String) async -> String {
        if let t = try? await git(["config", "cpilot.trunk"], in: dir), !t.isEmpty { return t }
        return await Git.defaultBranch(dir)
    }

    struct Tracked { var parent: String; var base: String? }

    static func tracked(in dir: String) async -> [String: Tracked] {
        guard let out = try? await git(["config", "--get-regexp", #"^branch\..*\.cpilot-(parent|base)$"#], in: dir) else { return [:] }
        var parents: [String: String] = [:], bases: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("branch.") else { continue }
            let key = String(parts[0].dropFirst(7))
            if key.hasSuffix(".cpilot-parent") { parents[String(key.dropLast(14))] = parts[1] }
            else if key.hasSuffix(".cpilot-base") { bases[String(key.dropLast(12))] = parts[1] }
        }
        var result: [String: Tracked] = [:]
        for (b, p) in parents { result[b] = Tracked(parent: p, base: bases[b]) }
        return result
    }

    /// Brings the remote's view up to date so "the trunk moved" can be noticed. Quiet: offline is fine.
    public static func fetch(in dir: String) async { _ = try? await git(["fetch", "--prune", "origin"], in: dir, timeout: 60) }

    // MARK: Reading

    /// Every stack in the repository, each with its branches bottom first.
    public static func load(in dir: String, host: StackHost? = nil) async -> [Stack] {
        let t = await trunk(in: dir)
        let meta = await tracked(in: dir)
        let existing = Set(((try? await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: dir)) ?? "").split(separator: "\n").map(String.init))
        let live = meta.filter { existing.contains($0.key) }
        let prs = await host?.pullRequests() ?? []
        func info(_ b: String) -> PullRequest? { prs.filter { $0.headRefName == b }.sorted { $0.number > $1.number }.first }
        var out: [Stack] = []
        let roots = live.filter { live[$0.value.parent] == nil }.keys.sorted()
        for root in roots {
            var list: [StackBranch] = []
            func visit(_ b: String, depth: Int) async {
                let m = live[b]!
                var sb = StackBranch(name: b, parent: m.parent, base: m.base, depth: depth)
                sb.needsRestack = !(await gitOK(["merge-base", "--is-ancestor", m.parent, b], in: dir))
                sb.commits = Int((try? await git(["rev-list", "--count", "\(m.parent)..\(b)"], in: dir)) ?? "0") ?? 0
                if let remote = try? await git(["rev-parse", "--verify", "--quiet", "origin/\(b)"], in: dir), let local = try? await git(["rev-parse", b], in: dir) { sb.pushed = remote == local }
                if let p = info(b) { sb.pr = p.number; sb.prState = p.state; sb.title = p.title; sb.prHead = p.headRefOid; sb.mergeState = p.mergeStateStatus }
                list.append(sb)
                for child in live.filter({ $0.value.parent == b }).keys.sorted() { await visit(child, depth: depth + 1) }
            }
            await visit(root, depth: 0)
            var stack = Stack(trunk: live[root]!.parent == t || existing.contains(live[root]!.parent) ? live[root]!.parent : t, branches: list)
            let behind = (try? await git(["rev-list", "--count", "\(stack.trunk)..origin/\(stack.trunk)"], in: dir)) ?? "0"
            stack.trunkBehind = Int(behind) ?? 0
            out.append(stack)
        }
        return out
    }

    // MARK: Building a stack

    /// Creates a branch on top of the current one, remembers where it sits, and optionally commits what is staged or changed.
    @discardableResult
    public static func create(_ name: String, commit message: String? = nil, in dir: String) async throws -> String {
        let parent = try await git(["branch", "--show-current"], in: dir)
        guard !parent.isEmpty else { throw StackError.message("Switch to a branch first.") }
        let tip = try await git(["rev-parse", parent], in: dir)
        try await git(["checkout", "-b", name], in: dir)
        try await setParent(name, to: parent, base: tip, in: dir)
        if let m = message, !(try await git(["status", "--porcelain"], in: dir)).isEmpty {
            try await git(["add", "-A"], in: dir); try await git(["commit", "-m", m], in: dir)
        }
        return name
    }

    // MARK: Restack

    public enum RestackResult: Equatable, Sendable { case upToDate, restacked([String]) }

    /// Where the temporary folders for restacking live. Tests point this somewhere disposable.
    nonisolated(unsafe) public static var restackRootOverride: String?

    public static func restackRoot() -> String {
        if let o = restackRootOverride { return o }
        if let r = Exec.environment { return "\(r.remoteHome)/.cpilot/restack" }
        return AppPaths().root.appendingPathComponent("restack").path
    }

    /// One branch being rebased in a folder of its own. Kept in the repository's git config so it survives a restart.
    public struct Job: Equatable { var id: String, branch: String, oldTip: String, newBase: String, parent: String, path: String }

    static func jobID(_ branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    public static func jobs(in dir: String) async -> [Job] {
        guard let out = try? await git(["config", "--get-regexp", #"^cpilot-restack\."#], in: dir) else { return [] }
        var fields: [String: [String: String]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].split(separator: ".").map(String.init)      // cpilot-restack, <id>, <field>
            guard key.count == 3 else { continue }
            fields[key[1], default: [:]][key[2]] = parts[1]
        }
        return fields.compactMap { id, f in
            guard let branch = f["branch"], let oldTip = f["oldtip"], let newBase = f["newbase"], let parent = f["parent"], let path = f["path"] else { return nil }
            return Job(id: id, branch: branch, oldTip: oldTip, newBase: newBase, parent: parent, path: path)
        }.sorted { $0.id < $1.id }
    }

    public static func dropJob(_ j: Job, in dir: String) async {
        _ = try? await Shell.run("git", ["worktree", "remove", "--force", j.path], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["config", "--remove-section", "cpilot-restack.\(j.id)"], cwd: cwd(dir))
    }

    /// A temporary folder holding `branch` as it is now, so the rebase never touches the folder you work in.
    static func startJob(branch: String, oldTip: String, newBase: String, parent: String, in dir: String) async throws -> Job {
        let id = jobID(branch)
        if let old = await jobs(in: dir).first(where: { $0.id == id }) { await dropJob(old, in: dir) }
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: cwd(dir))
        let path = restackRoot() + "/" + id
        try await git(["worktree", "add", "--detach", path, oldTip], in: dir, timeout: 120)
        let top = (try? await git(["rev-parse", "--show-toplevel"], in: path)) ?? path
        let job = Job(id: id, branch: branch, oldTip: oldTip, newBase: newBase, parent: parent, path: top)
        for (k, v) in [("branch", branch), ("oldtip", oldTip), ("newbase", newBase), ("parent", parent), ("path", top)] {
            try await git(["config", "cpilot-restack.\(id).\(k)", v], in: dir)
        }
        return job
    }

    public static func rebaseInProgress(in path: String) async -> Bool {
        for sub in ["rebase-merge", "rebase-apply"] {
            guard let rel = try? await git(["rev-parse", "--git-path", sub], in: path) else { continue }
            let base = rel.hasPrefix("/") ? rel : path + "/" + rel
            if (try? await Shell.run("test", ["-d", base]))?.ok == true { return true }
        }
        return false
    }

    static func conflictedFiles(in path: String) async -> [String] {
        ((try? await git(["diff", "--name-only", "--diff-filter=U"], in: path)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Moves the branch to the rebased commits and records where it now sits. The folder that has the branch checked out (if any) follows it.
    static func land(_ j: Job, in dir: String) async throws {
        let newTip = try await git(["rev-parse", "HEAD"], in: j.path)
        let current = try await git(["rev-parse", "--verify", "refs/heads/\(j.branch)"], in: dir)
        guard current == j.oldTip else {
            await dropJob(j, in: dir)
            throw StackError.message("\(j.branch) changed while it was being restacked, so nothing was moved. Restack again.")
        }
        if let folder = await checkoutFolder(of: j.branch, in: dir) {
            guard (try await git(["status", "--porcelain", "--untracked-files=no"], in: folder)).isEmpty else {
                throw StackError.message("\(j.branch) has uncommitted changes in \(folder). Commit or stash them there, then restack again; the rebased commits are kept until then.")
            }
            try await git(["reset", "--hard", newTip], in: folder)
        } else {
            try await git(["update-ref", "refs/heads/\(j.branch)", newTip, j.oldTip], in: dir)
        }
        try await setParent(j.branch, to: j.parent, base: j.newBase, in: dir)
        await dropJob(j, in: dir)
    }

    /// Takes in rebases that finished in their own folders (resolved by Claude or by hand), and clears the ones that were abandoned.
    @discardableResult
    public static func reconcile(in dir: String) async -> (landed: [String], problems: [String]) {
        var landed: [String] = [], problems: [String] = []
        for j in await jobs(in: dir) {
            if await rebaseInProgress(in: j.path) { continue }
            let head = try? await git(["rev-parse", "HEAD"], in: j.path)
            guard let head, await gitOK(["merge-base", "--is-ancestor", j.newBase, head], in: j.path), head != j.oldTip else { await dropJob(j, in: dir); continue }
            do { try await land(j, in: dir); landed.append(j.branch) } catch { problems.append(error.localizedDescription) }
        }
        return (landed, problems)
    }

    /// Puts every branch of the stack back on top of its parent, bottom first. A parent that has been merged is replaced by
    /// the trunk, and only the branch's own commits are replayed, so a squash merge does not cause duplicate changes.
    /// Each rebase runs in a temporary folder, so your checkout is never left half-way through one.
    @discardableResult
    public static func restack(_ stack: Stack, in dir: String) async throws -> RestackResult {
        var moved: [String] = []
        var parentOf: [String: String] = [:]
        for b in stack.branches { parentOf[b.name] = b.parent }
        await reconcile(in: dir)
        let waiting = await pendingConflicts(in: dir)
        for b in stack.branches where !b.isMerged {
            if let c = waiting.first(where: { $0.branch == b.name }) { throw StackError.conflict(branch: c.branch, files: c.files) }
            var parent = parentOf[b.name] ?? b.parent
            // Parents that are merged (or gone) collapse into the trunk.
            while let p = stack.branches.first(where: { $0.name == parent }), p.isMerged { parent = parentOf[p.name] ?? stack.trunk }
            // GitHub (and `gh pr merge --delete-branch`) removes a merged branch, so a parent that is gone collapses into the trunk too.
            if !(await gitOK(["rev-parse", "--verify", "--quiet", parent], in: dir)) { parent = stack.trunk }
            let newBase = try await git(["rev-parse", parent], in: dir)
            var oldBase = b.base ?? ""
            if oldBase.isEmpty { oldBase = try await git(["merge-base", b.parent, b.name], in: dir) }
            let isAncestor = await gitOK(["merge-base", "--is-ancestor", newBase, b.name], in: dir)
            if oldBase == newBase && isAncestor && parent == b.parent { continue }
            if isAncestor && parent == b.parent && b.base == nil { try await setParent(b.name, to: parent, base: newBase, in: dir); continue }
            // Only a folder that has this very branch checked out has to be clean, because it is moved to the rebased commits afterwards.
            if let folder = await checkoutFolder(of: b.name, in: dir), !(try await git(["status", "--porcelain", "--untracked-files=no"], in: folder)).isEmpty {
                if URL(fileURLWithPath: folder).resolvingSymlinksInPath() == URL(fileURLWithPath: dir).resolvingSymlinksInPath() { throw StackError.dirty }
                throw StackError.message("\(b.name) has uncommitted changes in its session folder. Commit or stash them there, then restack.")
            }
            let oldTip = try await git(["rev-parse", b.name], in: dir)
            let job = try await startJob(branch: b.name, oldTip: oldTip, newBase: newBase, parent: parent, in: dir)
            let r = try await Shell.run("git", ["rebase", "--onto", newBase, oldBase], cwd: cwd(job.path), timeout: 120)
            if !r.ok {
                // Only a rebase that stopped part-way is a conflict. Anything else (a refusal, a missing ref) is reported as what it is.
                guard await rebaseInProgress(in: job.path) else {
                    await dropJob(job, in: dir)
                    let why = r.stderr.split(separator: "\n").first.map(String.init) ?? "git could not rebase it."
                    throw StackError.message("Could not restack \(b.name): \(why)")
                }
                throw StackError.conflict(branch: b.name, files: await conflictedFiles(in: job.path))
            }
            try await land(job, in: dir)
            parentOf[b.name] = parent
            moved.append(b.name)
        }
        return moved.isEmpty ? .upToDate : .restacked(moved)
    }

    /// Gives up on a stopped restack. The branch was never touched, so nothing is lost. With no branch named, the first one is aborted.
    public static func abortRestack(in dir: String, branch: String? = nil) async {
        guard let c = await pendingConflicts(in: dir).first(where: { branch == nil || $0.branch == branch }) else { return }
        _ = try? await Shell.run("git", ["rebase", "--abort"], cwd: cwd(c.dir))
        if let j = await jobs(in: dir).first(where: { $0.path == c.dir }) { await dropJob(j, in: dir) }
    }

    /// A rebase that stopped on a conflict, and the folder it is stopped in.
    public struct PendingConflict: Equatable, Sendable { public var branch: String; public var files: [String]; public var dir: String; public var isolated = true }

    /// Every checkout of this repository: the main one and each worktree, with the branch it has (nil when detached).
    static func checkouts(in dir: String) async -> [(path: String, branch: String?)] {
        let out = (try? await git(["worktree", "list", "--porcelain"], in: dir)) ?? ""
        var list: [(String, String?)] = []
        for block in out.components(separatedBy: "\n\n") {
            var path: String?, branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
            }
            if let path { list.append((path, branch)) }
        }
        return list
    }

    /// Where `branch` is checked out, if anywhere.
    static func checkoutFolder(of branch: String, in dir: String) async -> String? {
        await checkouts(in: dir).first { $0.branch == branch }?.path
    }

    /// Every restack stopped on a conflict: the ones in their own folders, and any an older version left half-way in a checkout.
    public static func pendingConflicts(in dir: String) async -> [PendingConflict] {
        var out: [PendingConflict] = []
        let all = await jobs(in: dir)
        for j in all where await rebaseInProgress(in: j.path) {
            out.append(PendingConflict(branch: j.branch, files: await conflictedFiles(in: j.path), dir: j.path))
        }
        let own = Set(all.map(\.path))
        for c in await checkouts(in: dir) where !own.contains(c.path) {
            for sub in ["rebase-merge", "rebase-apply"] {
                guard let rel = try? await git(["rev-parse", "--git-path", sub], in: c.path) else { continue }
                let base = rel.hasPrefix("/") ? rel : c.path + "/" + rel
                guard (try? await Shell.run("test", ["-d", base]))?.ok == true else { continue }
                let head = ((try? await Shell.run("cat", [base + "/head-name"]))?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = head.hasPrefix("refs/heads/") ? String(head.dropFirst(11)) : (c.branch ?? head)
                out.append(PendingConflict(branch: branch, files: await conflictedFiles(in: c.path), dir: c.path, isolated: false))
                break
            }
        }
        return out
    }

    public static func pendingConflict(in dir: String) async -> PendingConflict? { await pendingConflicts(in: dir).first }

    /// After resolving a conflict: continue the rebase in the folder it stopped in. The caller then takes the result in with `reconcile` and restacks the rest.
    public static func continueRestack(in dir: String) async throws {
        let r = try await Shell.run("git", ["-c", "core.editor=true", "rebase", "--continue"], cwd: cwd(dir), timeout: 120)
        guard r.ok else {
            let left = await conflictedFiles(in: dir)
            if !left.isEmpty { throw StackError.message("Still unresolved: \(left.joined(separator: ", ")). Resolve them (and git add), then continue.") }
            throw StackError.message(r.stderr.isEmpty ? "The rebase could not continue." : r.stderr)
        }
    }

    // MARK: Overlap

    /// Two open branches that change the same files. Whichever merges second has to be rebased over the first.
    public struct Overlap: Equatable, Sendable { public var first: String, second: String, files: [String] }

    /// Pure: which branches share files, given what each one changes. Branches of one stack build on each other and are not compared.
    public static func overlaps(changes: [String: Set<String>], sameStack: (String, String) -> Bool = { _, _ in false }) -> [Overlap] {
        let names = changes.keys.sorted()
        var out: [Overlap] = []
        for (i, a) in names.enumerated() { for b in names[(i + 1)...] where !sameStack(a, b) {
            let shared = changes[a]!.intersection(changes[b]!).sorted()
            if !shared.isEmpty { out.append(Overlap(first: a, second: b, files: shared)) }
        } }
        return out
    }

    /// The files each open branch changes on top of its parent, compared across stacks.
    public static func overlaps(of stacks: [Stack], in dir: String) async -> [Overlap] {
        var changes: [String: Set<String>] = [:], home: [String: Int] = [:]
        for (i, st) in stacks.enumerated() {
            for b in st.branches where !b.isMerged && b.prState == "OPEN" {
                let base = st.branches.first(where: { $0.name == b.parent && !$0.isMerged })?.name ?? st.trunk
                let out = (try? await git(["diff", "--name-only", "\(base)...\(b.name)"], in: dir)) ?? ""
                changes[b.name] = Set(out.split(separator: "\n").map(String.init)); home[b.name] = i
            }
        }
        return overlaps(changes: changes, sameStack: { home[$0] == home[$1] })
    }

    /// Stacks joined by overlaps: each group is stacks that change the same files, directly or through another stack. Only groups of two or more.
    public static func overlapGroups(_ stacks: [Stack], overlaps: [Overlap]) -> [[Stack]] {
        var parent = Array(stacks.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : { let r = root(parent[i]); parent[i] = r; return r }() }
        func index(of branch: String) -> Int? { stacks.firstIndex { $0.branches.contains { $0.name == branch } } }
        for o in overlaps { if let a = index(of: o.first), let b = index(of: o.second) { parent[root(a)] = root(b) } }
        var groups: [Int: [Stack]] = [:]
        for i in stacks.indices { groups[root(i), default: []].append(stacks[i]) }
        return groups.values.filter { $0.count >= 2 }.map { $0.sorted { $0.id < $1.id } }.sorted { ($0.first?.id ?? "") < ($1.first?.id ?? "") }
    }

    // MARK: Submit and merge

    static func footer(_ stack: Stack, numbers: [String: Int], current: String) -> String {
        var s = "\n\n<!-- cpilot-stack -->\n**Stack**\n"
        for b in stack.branches where !b.isMerged {
            s += "- " + (b.name == current ? "**" : "") + (numbers[b.name].map { "#\($0)" } ?? b.name) + (b.name == current ? " (this PR)**" : "") + "\n"
        }
        return s
    }

    /// The description as a person wrote it, without the stack list CPilot appends.
    public static func withoutFooter(_ body: String) -> String {
        guard let r = body.range(of: "<!-- cpilot-stack -->") else { return body }
        return String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits on origin that the local branch lacks (a review session pushed them, or a teammate did) would be thrown away by the force push.
    /// A restack rewrites commits legitimately, so only commits whose change is missing locally count. Checked for every branch before any push.
    static func refuseToDiscardRemoteWork(_ stack: Stack, in dir: String) async throws {
        for b in stack.branches where !b.isMerged {
            guard await gitOK(["fetch", "origin", b.name], in: dir), await gitOK(["rev-parse", "--verify", "-q", "refs/remotes/origin/\(b.name)"], in: dir) else { continue }
            let missing = ((try? await git(["cherry", b.name, "origin/\(b.name)"], in: dir)) ?? "").split(separator: "\n").filter { $0.hasPrefix("+") }
            if !missing.isEmpty {
                throw StackError.message("origin/\(b.name) has \(missing.count) commit\(missing.count == 1 ? "" : "s") that \(b.name) does not (for example from a review session). Submitting would delete them. Bring them in first: git checkout \(b.name) && git pull --rebase origin \(b.name).")
            }
        }
    }

    /// Pushes every branch, creates or updates its pull request on top of its parent's, and writes the stack list into each.
    @discardableResult
    public static func submit(_ stack: Stack, in dir: String, host: StackHost, draft: Bool = false) async throws -> [String: Int] {
        var numbers: [String: Int] = [:]
        for b in stack.branches where !b.isMerged { numbers[b.name] = b.pr }
        try await refuseToDiscardRemoteWork(stack, in: dir)
        for b in stack.branches where !b.isMerged {
            try await git(["push", "--force-with-lease", "-u", "origin", b.name], in: dir, timeout: 120)
            let base = stack.branches.first(where: { $0.name == b.parent && !$0.isMerged })?.name ?? stack.trunk
            if let n = b.pr, b.prState == "OPEN" { try await host.setBase(n, base: base); numbers[b.name] = n }
            else {
                let subject = (try? await git(["log", "--reverse", "--format=%s", "\(b.parent)..\(b.name)"], in: dir))?.split(separator: "\n").first.map(String.init) ?? b.name
                numbers[b.name] = try await host.create(head: b.name, base: base, title: subject, body: "", draft: draft)
            }
        }
        for b in stack.branches where !b.isMerged {
            if let n = numbers[b.name], n > 0 { try? await host.setBody(n, body: footer(stack, numbers: numbers, current: b.name)) }
        }
        return numbers
    }

    /// Merges the lowest open pull request. The next one is pointed at the trunk first so GitHub does not close it,
    /// then the rest of the stack is restacked on the updated trunk. One step at a time: checks must pass again before the next.
    public static func mergeBottom(_ stack: Stack, in dir: String, host: StackHost, method: MergeMethod = .squash, admin: Bool = false) async throws -> String {
        guard let bottom = stack.branches.first(where: { !$0.isMerged && $0.pr != nil && $0.prState == "OPEN" }), let n = bottom.pr else { throw StackError.message("There is no open pull request to merge.") }
        for child in stack.branches where child.parent == bottom.name && child.pr != nil && child.prState == "OPEN" { try await host.setBase(child.pr!, base: stack.trunk) }
        try await host.merge(n, method: method, expectedHead: bottom.prHead, admin: admin)
        _ = try? await git(["fetch", "--prune", "origin"], in: dir, timeout: 120)
        return bottom.name
    }

    /// Fast-forwards the trunk, then restacks what is left. Merged branches are reported so they can be cleaned up.
    public static func sync(in dir: String, host: StackHost?) async throws -> RestackResult {
        _ = try? await git(["fetch", "--prune", "origin"], in: dir, timeout: 120)
        let t = await trunk(in: dir)
        let current = (try? await git(["branch", "--show-current"], in: dir)) ?? ""
        if current == t { _ = try? await git(["merge", "--ff-only", "origin/\(t)"], in: dir) }
        else { _ = try? await git(["fetch", "origin", "\(t):\(t)"], in: dir) }
        var moved: [String] = []
        var conflict: StackError?
        for stack in await load(in: dir, host: host) where stack.needsRestack {
            do { if case .restacked(let m) = try await restack(stack, in: dir) { moved += m } }
            catch let e as StackError { if case .conflict = e { conflict = conflict ?? e } else { throw e } }   // the other stacks still move
        }
        if let conflict { throw conflict }
        return moved.isEmpty ? .upToDate : .restacked(moved)
    }

    /// Removes the local branches of merged pull requests and stops tracking them.
    public static func cleanUp(_ stack: Stack, in dir: String) async {
        let current = (try? await git(["branch", "--show-current"], in: dir)) ?? ""
        for b in stack.branches where b.isMerged && b.name != current {
            // Deleting the branch deletes its settings, so what a merged combined pull request replaced is kept apart for the specs.
            let replaced = (try? await git(["config", "branch.\(b.name).cpilot-replaces"], in: dir)) ?? ""
            for old in replaced.split(separator: ",") { _ = try? await git(["config", "--add", "cpilot.landed", String(old)], in: dir) }
            _ = try? await Shell.run("git", ["branch", "-D", b.name], cwd: cwd(dir))
            await untrack(b.name, in: dir)
        }
    }

    // MARK: Collapsing a stack into one pull request

    /// A stack being combined into one branch in a folder of its own. The branch gets every open branch's own commits, oldest first.
    /// Where picking a commit stopped on a conflict, `pending` holds the commits still to apply after it.
    public struct CollapseJob: Equatable, Sendable {
        public var branch: String
        public var path: String
        public var trunk: String
        /// The open pull requests this replaces, and the branches they come from.
        public var prs: [Int]
        public var sources: [String]
        /// Commits (hash and subject) applied so far, and still to come after a conflict.
        public var applied: Int
        public var pending: [String]
        public var conflicted: Bool
    }

    /// The commits each unmerged branch adds on top of its parent that the trunk does not already have, in stack order.
    /// A commit whose change the trunk already holds (for example the squashed merge of a lower pull request) is left out.
    public static func collapseCommits(_ stacks: [Stack], trunkRef: String, in dir: String) async -> [(branch: String, sha: String, subject: String)] {
        let open = stacks.flatMap(\.branches).filter { !$0.isMerged && $0.prState != "CLOSED" }
        let names = Set(open.map(\.name))
        var out: [(String, String, String)] = []
        for b in open {
            let parent = names.contains(b.parent) ? b.parent : trunkRef
            let fresh = Set(((try? await git(["cherry", trunkRef, b.name], in: dir)) ?? "").split(separator: "\n").compactMap { l -> String? in
                l.hasPrefix("+ ") ? String(l.dropFirst(2)) : nil
            })
            let listed = (try? await git(["log", "--reverse", "--format=%H\t%s", "\(parent)..\(b.name)"], in: dir)) ?? ""
            for line in listed.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if f.count == 2, fresh.contains(f[0]) { out.append((b.name, f[0], f[1])) }
            }
        }
        return out
    }

    /// Builds the combined branch from the latest trunk in a temporary folder, picking each commit in turn.
    /// Stops at the first conflict and says so; everything that picks cleanly is already in.
    public static func startCollapse(_ stack: Stack, in dir: String) async throws -> CollapseJob { try await startCollapse([stack], in: dir) }

    /// The same for several stacks at once, for stacks that change the same files and so cannot merge without conflicts.
    public static func startCollapse(_ stacks: [Stack], in dir: String) async throws -> CollapseJob {
        guard let first = stacks.first else { throw StackError.message("There is nothing to combine.") }
        let stack = Stack(trunk: first.trunk, branches: stacks.flatMap(\.branches))
        let open = stack.branches.filter { !$0.isMerged && $0.prState != "CLOSED" }
        guard open.count >= 2 else { throw StackError.message("There is nothing to combine: fewer than two open branches.") }
        await fetch(in: dir)
        let remote = "origin/\(stack.trunk)"
        let base = await gitOK(["rev-parse", "--verify", "--quiet", remote], in: dir) ? remote : stack.trunk
        let commits = await collapseCommits(stacks, trunkRef: base, in: dir)
        guard !commits.isEmpty else { throw StackError.message("Every change in these branches is already in \(stack.trunk).") }
        var name = Git.slugify((open.first?.name ?? "stack") + "-combined"), n = 2
        while await gitOK(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: dir) { name = Git.slugify((open.first?.name ?? "stack") + "-combined-\(n)"); n += 1 }
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: cwd(dir))
        let path = restackRoot() + "/collapse-" + jobID(name)
        try await git(["worktree", "add", "-b", name, path, base], in: dir, timeout: 120)
        let top = (try? await git(["rev-parse", "--show-toplevel"], in: path)) ?? path
        var job = CollapseJob(branch: name, path: top, trunk: stack.trunk, prs: open.compactMap(\.pr), sources: open.map(\.name), applied: 0, pending: [], conflicted: false)
        for (i, c) in commits.enumerated() {
            let r = try await Shell.run("git", ["cherry-pick", "-x", c.sha], cwd: cwd(top), timeout: 120)
            if r.ok { job.applied += 1; continue }
            if await conflictedFiles(in: top).isEmpty {
                // Nothing left to apply: the change was already there. Skip the empty pick and carry on.
                _ = try? await Shell.run("git", ["cherry-pick", "--skip"], cwd: cwd(top), timeout: 60)
                continue
            }
            job.conflicted = true
            job.pending = commits.dropFirst(i + 1).map { "\($0.sha) \($0.subject)" }
            return job
        }
        return job
    }

    /// What the agent is asked to do in the combined branch's folder: finish the picks, make the result one coherent change, prove it works.
    public static func collapsePrompt(_ job: CollapseJob) -> String {
        var p = "This folder holds the branch \(job.branch), made by combining \(job.sources.count) stacked branches (\(job.sources.joined(separator: ", "))) into one pull request against \(job.trunk). They were written separately, so they overlap: the same file edited by several, the same helper written twice."
        if job.conflicted {
            p += "\n\nA `git cherry-pick` is stopped on a conflict. Resolve the markers so both sides' intent is kept, `git add` the files and run `git -c core.editor=true cherry-pick --continue`."
            if !job.pending.isEmpty { p += " Then apply the rest in this order, resolving conflicts the same way (`git cherry-pick -x <hash>`; if a pick turns out empty, `git cherry-pick --skip`):\n" + job.pending.map { "- " + $0 }.joined(separator: "\n") }
        }
        p += "\n\nThen make the combined result one coherent change: remove duplicated definitions and helpers (keep one, the better one), and make sure names that two branches both introduced do not clash. Run the project's build and tests and fix what fails; commit the fixes on this branch. Do not switch branches, push or open a pull request: CPilot does that."
        p += "\n\nWhen it builds and the tests pass, run these two commands, with a title and a short plain description of what the whole change does (no task ids) in place of the placeholders, and then stop:\n`git config branch.\(job.branch).cpilot-title \"<pull request title>\"`\n`git config branch.\(job.branch).cpilot-summary \"<two or three sentences>\"`\n`git config branch.\(job.branch).cpilot-collapse done`"
        return p
    }

    /// True once the agent has said the combined branch is finished.
    public static func collapseFinished(_ job: CollapseJob, in dir: String) async -> Bool {
        (try? await git(["config", "branch.\(job.branch).cpilot-collapse"], in: dir)) == "done"
    }

    /// Publishes the combined branch as one pull request, closes the ones it replaces, and tidies up. Returns the new pull request's number.
    public static func finishCollapse(_ job: CollapseJob, in dir: String, host: StackHost) async throws -> Int {
        guard await !pickInProgress(in: job.path) else { throw StackError.message("A cherry-pick is still stopped in \(job.path). Resolve it, then try again.") }
        guard (try await git(["status", "--porcelain", "--untracked-files=no"], in: job.path)).isEmpty else { throw StackError.message("\(job.branch) has uncommitted changes in \(job.path). Commit them, then try again.") }
        let configured = (try? await git(["config", "branch.\(job.branch).cpilot-title"], in: dir)) ?? ""
        let summary = (try? await git(["config", "branch.\(job.branch).cpilot-summary"], in: dir)) ?? ""
        let title = configured.isEmpty ? "Combine \(job.sources.count) stacked pull requests" : configured
        let replaced = job.prs.map { "#\($0)" }.joined(separator: ", ")
        let body = (summary.isEmpty ? "" : summary + "\n\n") + "Combines \(replaced) into one pull request, because they changed the same files and conflicted with each other. Each change is still its own commit."
        try await git(["push", "-u", "origin", job.branch], in: job.path, timeout: 180)
        let number = try await host.create(head: job.branch, base: job.trunk, title: title, body: body, draft: false)
        for n in job.prs { try? await host.close(n, comment: "Combined into #\(number): these pull requests changed the same files and conflicted with each other.") }
        let tip = try await git(["rev-parse", job.branch], in: dir)
        try await setParent(job.branch, to: job.trunk, base: tip, in: dir)
        // Remembered, so the specs whose tasks these branches were are ticked off when this pull request merges.
        try await git(["config", "branch.\(job.branch).cpilot-replaces", job.sources.joined(separator: ",")], in: dir)
        for b in job.sources { await untrack(b, in: dir) }
        _ = try? await Shell.run("git", ["worktree", "remove", "--force", job.path], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: cwd(dir))
        return number
    }

    /// Branches that went in with a combined pull request which has since merged and been cleaned up.
    public static func landedBranches(in dir: String) async -> Set<String> {
        Set(((try? await git(["config", "--get-all", "cpilot.landed"], in: dir)) ?? "").split(separator: "\n").map(String.init))
    }

    /// Combined branch to the branches it replaced.
    public static func replacedBranches(in dir: String) async -> [String: [String]] {
        guard let out = try? await git(["config", "--get-regexp", #"^branch\..*\.cpilot-replaces$"#], in: dir) else { return [:] }
        var map: [String: [String]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("branch.") else { continue }
            let branch = String(parts[0].dropFirst(7).dropLast(".cpilot-replaces".count))
            map[branch] = parts[1].split(separator: ",").map(String.init)
        }
        return map
    }

    static func pickInProgress(in path: String) async -> Bool { await gitOK(["rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"], in: path) }

    /// Gives up on a combine: removes its folder and branch. The branches it was built from are untouched.
    public static func abortCollapse(_ job: CollapseJob, in dir: String) async {
        _ = try? await Shell.run("git", ["worktree", "remove", "--force", job.path], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["worktree", "prune"], cwd: cwd(dir))
        _ = try? await Shell.run("git", ["branch", "-D", job.branch], cwd: cwd(dir))
    }

    // MARK: Splitting a big change

    public struct Piece: Codable, Equatable, Sendable, Identifiable {
        public var branch: String
        public var message: String
        public var files: [String]
        public var id: String { branch }
        public init(branch: String, message: String, files: [String]) { self.branch = branch; self.message = message; self.files = files }
    }

    /// Files changed on `source` compared with the trunk.
    public static func changedFiles(source: String, in dir: String) async -> [String] {
        let t = await trunk(in: dir)
        return ((try? await git(["diff", "--name-only", "\(t)...\(source)"], in: dir)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Reads an agent's proposed split. Files the agent left out go into the last piece, and files that do not exist are dropped,
    /// so applying the pieces always reproduces the whole change.
    public static func parsePlan(_ text: String, changed: [String]) -> [Piece] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8), var pieces = try? JSONDecoder().decode([Piece].self, from: data), !pieces.isEmpty else { return [] }
        let known = Set(changed)
        var used = Set<String>()
        for i in pieces.indices {
            pieces[i].files = pieces[i].files.filter { known.contains($0) && used.insert($0).inserted }
            pieces[i].branch = Git.slugify(pieces[i].branch)
        }
        pieces.removeAll { $0.files.isEmpty }
        guard !pieces.isEmpty else { return [] }
        let left = changed.filter { !used.contains($0) }
        if !left.isEmpty { pieces[pieces.count - 1].files += left }
        return pieces
    }

    /// Builds the stack: each piece becomes a branch on top of the previous one, taking its files from `source`.
    /// The top of the stack ends up identical to `source`.
    public static func split(source: String, pieces: [Piece], in dir: String) async throws {
        guard (try await git(["status", "--porcelain", "--untracked-files=no"], in: dir)).isEmpty else { throw StackError.dirty }
        let t = await trunk(in: dir)
        try await git(["checkout", t], in: dir)
        for p in pieces {
            try await create(p.branch, in: dir)
            for f in p.files {
                let exists = await gitOK(["cat-file", "-e", "\(source):\(f)"], in: dir)
                if exists { try await git(["checkout", source, "--", f], in: dir) } else { _ = try? await Shell.run("git", ["rm", "-rf", "--ignore-unmatch", "--", f], cwd: cwd(dir)) }
            }
            try await git(["add", "-A"], in: dir)
            try await git(["commit", "-m", p.message.isEmpty ? p.branch : p.message], in: dir)
        }
    }
}

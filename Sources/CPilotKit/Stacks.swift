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

    /// Puts every branch of the stack back on top of its parent, bottom first. A parent that has been merged is replaced by
    /// the trunk, and only the branch's own commits are replayed, so a squash merge does not cause duplicate changes.
    @discardableResult
    public static func restack(_ stack: Stack, in dir: String) async throws -> RestackResult {
        guard (try await git(["status", "--porcelain", "--untracked-files=no"], in: dir)).isEmpty else { throw StackError.dirty }
        let original = (try? await git(["branch", "--show-current"], in: dir)) ?? ""
        var moved: [String] = []
        var parentOf: [String: String] = [:]
        for b in stack.branches { parentOf[b.name] = b.parent }
        for b in stack.branches where !b.isMerged {
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
            // A branch a session has checked out lives in that session's own folder, and git refuses to rebase it from anywhere else.
            let folder = await checkoutFolder(of: b.name, in: dir) ?? dir
            if folder != dir, !(try await git(["status", "--porcelain", "--untracked-files=no"], in: folder)).isEmpty {
                throw StackError.message("\(b.name) has uncommitted changes in its session folder. Commit or stash them there, then restack.")
            }
            let r = try await Shell.run("git", ["rebase", "--onto", newBase, oldBase, b.name], cwd: cwd(folder), timeout: 120)
            if !r.ok {
                // Only a rebase that stopped part-way is a conflict. Anything else (a refusal, a missing ref) is reported as what it is.
                guard let pending = await pendingConflict(in: dir) else {
                    let why = r.stderr.split(separator: "\n").first.map(String.init) ?? "git could not rebase it."
                    throw StackError.message("Could not restack \(b.name): \(why)")
                }
                throw StackError.conflict(branch: pending.branch, files: pending.files)
            }
            try await setParent(b.name, to: parent, base: newBase, in: dir)
            parentOf[b.name] = parent
            moved.append(b.name)
        }
        if !original.isEmpty { _ = try? await Shell.run("git", ["checkout", original], cwd: cwd(dir)) }
        return moved.isEmpty ? .upToDate : .restacked(moved)
    }

    public static func abortRestack(in dir: String) async {
        let where_ = await pendingConflict(in: dir)?.dir ?? dir
        _ = try? await Shell.run("git", ["rebase", "--abort"], cwd: cwd(where_))
    }

    /// A rebase that stopped on a conflict, and the folder it is stopped in (this checkout or one of its worktrees).
    public struct PendingConflict: Equatable, Sendable { public var branch: String; public var files: [String]; public var dir: String }

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

    public static func pendingConflict(in dir: String) async -> PendingConflict? {
        for c in await checkouts(in: dir) {
            for sub in ["rebase-merge", "rebase-apply"] {
                guard let rel = try? await git(["rev-parse", "--git-path", sub], in: c.path) else { continue }
                let base = rel.hasPrefix("/") ? rel : c.path + "/" + rel
                guard FileManager.default.fileExists(atPath: base) else { continue }
                let head = (try? String(contentsOfFile: base + "/head-name", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let branch = head.hasPrefix("refs/heads/") ? String(head.dropFirst(11)) : (c.branch ?? head)
                let files = ((try? await git(["diff", "--name-only", "--diff-filter=U"], in: c.path)) ?? "").split(separator: "\n").map(String.init)
                return PendingConflict(branch: branch, files: files, dir: c.path)
            }
        }
        return nil
    }

    /// After resolving a conflict: continue the rebase, then the caller restacks again to finish the rest of the stack.
    public static func continueRestack(in dir: String) async throws {
        let r = try await Shell.run("git", ["-c", "core.editor=true", "rebase", "--continue"], cwd: cwd(dir), timeout: 120)
        guard r.ok else { throw StackError.message(r.stderr.isEmpty ? "The rebase could not continue." : r.stderr) }
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

    /// Pushes every branch, creates or updates its pull request on top of its parent's, and writes the stack list into each.
    @discardableResult
    public static func submit(_ stack: Stack, in dir: String, host: StackHost, draft: Bool = false) async throws -> [String: Int] {
        var numbers: [String: Int] = [:]
        for b in stack.branches where !b.isMerged { numbers[b.name] = b.pr }
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
        for stack in await load(in: dir, host: host) where stack.needsRestack {
            if case .restacked(let m) = try await restack(stack, in: dir) { moved += m }
        }
        return moved.isEmpty ? .upToDate : .restacked(moved)
    }

    /// Removes the local branches of merged pull requests and stops tracking them.
    public static func cleanUp(_ stack: Stack, in dir: String) async {
        let current = (try? await git(["branch", "--show-current"], in: dir)) ?? ""
        for b in stack.branches where b.isMerged && b.name != current {
            _ = try? await Shell.run("git", ["branch", "-D", b.name], cwd: cwd(dir))
            await untrack(b.name, in: dir)
        }
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

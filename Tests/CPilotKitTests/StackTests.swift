// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class FakeHost: StackHost, @unchecked Sendable {
    var prs: [PullRequest] = []
    var calls: [String] = []
    var bodies: [Int: String] = [:]
    private var next = 100
    func pullRequests() async -> [PullRequest] { prs }
    func create(head: String, base: String, title: String, body: String, draft: Bool) async throws -> Int {
        next += 1; calls.append("create \(head)->\(base)")
        prs.append(PullRequest(number: next, title: title, state: "OPEN", isDraft: draft, headRefName: head, baseRefName: base, author: nil, url: "u"))
        return next
    }
    func setBase(_ number: Int, base: String) async throws { calls.append("base #\(number)->\(base)") }
    func setBody(_ number: Int, body: String) async throws { bodies[number] = body }
    func close(_ number: Int, comment: String) async throws {
        calls.append("close #\(number)")
        if let i = prs.firstIndex(where: { $0.number == number }) { prs[i].state = "CLOSED" }
    }
    func merge(_ number: Int, method: MergeMethod) async throws {
        calls.append("merge #\(number)")
        if let i = prs.firstIndex(where: { $0.number == number }) { prs[i].state = "MERGED" }
    }
}

final class StackTests: XCTestCase {
    var dir = "", origin = ""

    @discardableResult func sh(_ args: [String], in d: String? = nil) async throws -> String {
        try await Shell.check("git", ["-c", "user.name=T", "-c", "user.email=t@t.co", "-c", "commit.gpgsign=false"] + args, cwd: URL(fileURLWithPath: d ?? dir))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ name: String, _ text: String) throws { try text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
    func commit(_ file: String, _ text: String, _ msg: String) async throws { try write(file, text); try await sh(["add", "-A"]); try await sh(["commit", "-m", msg]) }

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString.prefix(8))")
        Stacks.restackRootOverride = root.appendingPathComponent("restack").path
        origin = root.appendingPathComponent("origin.git").path; dir = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        try await sh(["init", "--bare", "-b", "main", origin], in: root.path)
        try await sh(["clone", origin, dir], in: root.path)
        try await sh(["checkout", "-b", "main"])
        try await commit("base.txt", "base\n", "base")
        try await sh(["push", "-u", "origin", "main"])
        try await sh(["remote", "set-head", "origin", "main"])
    }

    func buildStack() async throws {
        try await Stacks.create("a", in: dir); try await commit("a.txt", "a\n", "add a")
        try await Stacks.create("b", in: dir); try await commit("b.txt", "b\n", "add b")
        try await Stacks.create("c", in: dir); try await commit("c.txt", "c\n", "add c")
    }

    func testLoadOrdersABottomFirstWithDepth() async throws {
        try await buildStack()
        let stacks = await Stacks.load(in: dir)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0].branches.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(stacks[0].branches.map(\.depth), [0, 1, 2])
        XCTAssertEqual(stacks[0].trunk, "main")
        XCTAssertFalse(stacks[0].needsRestack)
        XCTAssertEqual(stacks[0].branches.map(\.commits), [1, 1, 1])
    }

    func testChangeBelowRestacksAbove() async throws {
        try await buildStack()
        try await sh(["checkout", "a"]); try await commit("a2.txt", "more\n", "more a")
        var stack = await Stacks.load(in: dir)[0]
        XCTAssertEqual(stack.branches.filter(\.needsRestack).map(\.name), ["b"])
        let r = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(r, .restacked(["b", "c"]))
        stack = await Stacks.load(in: dir)[0]
        XCTAssertFalse(stack.needsRestack)
        let tree = try await sh(["ls-tree", "-r", "--name-only", "c"])
        XCTAssertTrue(tree.contains("a2.txt") && tree.contains("b.txt") && tree.contains("c.txt"))
        let again = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(again, .upToDate)
        let branch = try await sh(["branch", "--show-current"])
        XCTAssertEqual(branch, "a")   // the checkout is put back
    }

    func testSquashMergedBottomCollapsesIntoTrunkWithoutDuplicates() async throws {
        try await buildStack()
        // GitHub squash merges a into main: the same changes, one new commit.
        try await sh(["checkout", "main"]); try await sh(["merge", "--squash", "a"]); try await sh(["commit", "-m", "add a (#1)"])
        try await sh(["push", "origin", "main"])
        let host = FakeHost()
        host.prs = [PullRequest(number: 1, title: "add a", state: "MERGED", isDraft: false, headRefName: "a", baseRefName: "main", author: nil, url: "u")]
        let stack = await Stacks.load(in: dir, host: host)[0]
        XCTAssertTrue(stack.needsRestack); XCTAssertTrue(stack.branches[0].isMerged)
        let r = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(r, .restacked(["b", "c"]))
        let own = try await sh(["rev-list", "--count", "main..b"]); XCTAssertEqual(own, "1")
        let own2 = try await sh(["rev-list", "--count", "b..c"]); XCTAssertEqual(own2, "1")
        let afterStacks = await Stacks.load(in: dir, host: host)
        XCTAssertEqual(afterStacks.flatMap(\.branches).first { $0.name == "b" }?.parent, "main")
        let after = afterStacks.first { $0.branches.contains { $0.isMerged } }!
        await Stacks.cleanUp(after, in: dir)
        let branches = try await sh(["branch", "--format=%(refname:short)"])
        XCTAssertFalse(branches.contains("\na\n") || branches.hasPrefix("a\n"))
    }

    func testRestackWhenTheMergedBranchWasDeleted() async throws {
        try await buildStack()
        try await sh(["checkout", "main"]); try await sh(["merge", "--squash", "a"]); try await sh(["commit", "-m", "add a (#1)"]); try await sh(["push", "origin", "main"])
        try await sh(["branch", "-D", "a"])                       // gh pr merge --delete-branch does this
        let stack = await Stacks.load(in: dir)[0]
        XCTAssertEqual(stack.branches.first?.name, "b"); XCTAssertEqual(stack.trunk, "main"); XCTAssertTrue(stack.needsRestack)
        let r = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(r, .restacked(["b", "c"]))
        let own = try await sh(["rev-list", "--count", "main..b"]); XCTAssertEqual(own, "1")
        let tree = try await sh(["ls-tree", "-r", "--name-only", "c"])
        XCTAssertTrue(tree.contains("a.txt") && tree.contains("b.txt") && tree.contains("c.txt"))
    }

    /// The real-world failure: a session has the branch checked out in its own worktree, so git refuses to rebase it from the main folder.
    func testBranchCheckedOutInAWorktreeIsRestackedThere() async throws {
        try await buildStack()
        let wt = NSTemporaryDirectory() + "cpilot-wt-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: wt) }
        try await sh(["checkout", "a"]); try await commit("a2.txt", "more\n", "more a")
        try await sh(["worktree", "add", wt, "b"])                // b is now "used by worktree"
        let stack = await Stacks.load(in: dir)[0]
        let r = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(r, .restacked(["b", "c"]))
        let tree = try await sh(["ls-tree", "-r", "--name-only", "c"]); XCTAssertTrue(tree.contains("a2.txt"))
        let nowAt = try await sh(["-C", wt, "branch", "--show-current"]); XCTAssertEqual(nowAt, "b")
    }

    func testDirtyCheckoutOfTheBranchBeingMovedIsRefused() async throws {
        try await buildStack()
        try await sh(["checkout", "a"]); try await commit("a2.txt", "more\n", "more a")
        try await sh(["checkout", "b"]); try write("b.txt", "changed\n")
        let stack = await Stacks.load(in: dir)[0]
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected dirty") } catch { XCTAssertEqual(error as? StackError, .dirty) }
    }

    func testUncommittedChangesElsewhereDoNotBlockARestack() async throws {
        try await buildStack()
        try await sh(["checkout", "a"]); try await commit("a2.txt", "more\n", "more a")
        try write("scratch.txt", "x\n"); try write("a.txt", "dirty\n")          // a is checked out and dirty, but a is not moved
        let stack = await Stacks.load(in: dir)[0]
        let r = try await Stacks.restack(stack, in: dir)
        XCTAssertEqual(r, .restacked(["b", "c"]))
        let tree = try await sh(["ls-tree", "-r", "--name-only", "c"]); XCTAssertTrue(tree.contains("a2.txt"))
        let mine = try String(contentsOfFile: dir + "/a.txt", encoding: .utf8); XCTAssertEqual(mine, "dirty\n")
    }

    private func conflictSetup() async throws -> Stack {
        try await buildStack()
        try await sh(["checkout", "b"]); try await commit("shared.txt", "from b\n", "b shared")
        try await sh(["checkout", "a"]); try await commit("shared.txt", "from a\n", "a shared")
        try await sh(["checkout", "c"])
        return await Stacks.load(in: dir)[0]
    }

    /// The point of restacking in a folder of its own: a conflict leaves your checkout exactly as it was.
    func testAConflictLeavesYourCheckoutAloneAndAbortLosesNothing() async throws {
        let stack = try await conflictSetup()
        let tipB = try await sh(["rev-parse", "b"])
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected a conflict") }
        catch let e as StackError { guard case .conflict(let b, let files) = e else { return XCTFail("\(e)") }; XCTAssertEqual(b, "b"); XCTAssertEqual(files, ["shared.txt"]) }
        let status = try await sh(["status", "--porcelain", "--untracked-files=no"]); XCTAssertEqual(status, "")
        let here = try await sh(["branch", "--show-current"]); XCTAssertEqual(here, "c")
        let state = try await sh(["status"]); XCTAssertFalse(state.contains("rebase in progress"))
        let pending = await Stacks.pendingConflicts(in: dir); XCTAssertEqual(pending.map(\.branch), ["b"])
        XCTAssertNotEqual(pending.first?.dir, dir)
        await Stacks.abortRestack(in: dir)
        let none = await Stacks.pendingConflicts(in: dir); XCTAssertTrue(none.isEmpty)
        let after = try await sh(["rev-parse", "b"]); XCTAssertEqual(after, tipB)
        let listed = try await sh(["worktree", "list"]); XCTAssertEqual(listed.split(separator: "\n").count, 1)
    }

    func testResolvingByHandLandsTheBranchAndTheRestFollows() async throws {
        let stack = try await conflictSetup()
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected a conflict") } catch {}
        let pc = await Stacks.pendingConflict(in: dir); let c = try XCTUnwrap(pc)
        do { try await Stacks.continueRestack(in: c.dir); XCTFail("expected unresolved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("shared.txt")) }
        try "resolved\n".write(toFile: c.dir + "/shared.txt", atomically: true, encoding: .utf8)
        try await sh(["add", "shared.txt"], in: c.dir)
        try await Stacks.continueRestack(in: c.dir)
        let r = await Stacks.reconcile(in: dir)
        XCTAssertEqual(r.landed, ["b"]); XCTAssertTrue(r.problems.isEmpty)
        let shared = try await sh(["show", "b:shared.txt"]); XCTAssertEqual(shared, "resolved")
        let fresh = await Stacks.load(in: dir)[0]
        XCTAssertEqual(fresh.branches.first { $0.name == "b" }?.needsRestack, false)
        XCTAssertEqual(fresh.branches.first { $0.name == "c" }?.needsRestack, true)
        let done = try await Stacks.restack(fresh, in: dir)
        XCTAssertEqual(done, .restacked(["c"]))
        let tree = try await sh(["ls-tree", "-r", "--name-only", "c"]); XCTAssertTrue(tree.contains("shared.txt") && tree.contains("c.txt"))
    }

    func testAbandoningTheRebaseInItsFolderClearsTheJob() async throws {
        let stack = try await conflictSetup()
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected a conflict") } catch {}
        let pc = await Stacks.pendingConflict(in: dir); let c = try XCTUnwrap(pc)
        try await sh(["rebase", "--abort"], in: c.dir)
        await Stacks.reconcile(in: dir)
        let none = await Stacks.pendingConflicts(in: dir); XCTAssertTrue(none.isEmpty)
        let jobs = await Stacks.jobs(in: dir); XCTAssertTrue(jobs.isEmpty)
    }

    func testAConflictInOneStackDoesNotStopTheOthers() async throws {
        try await buildStack()
        try await sh(["checkout", "main"])
        try await Stacks.create("x", in: dir); try await commit("x.txt", "x\n", "add x")
        try await sh(["checkout", "b"]); try await commit("shared.txt", "from b\n", "b shared")
        try await sh(["checkout", "a"]); try await commit("shared.txt", "from a\n", "a shared")
        try await sh(["checkout", "main"]); try await commit("m.txt", "m\n", "main moves"); try await sh(["push", "origin", "main"])
        do { _ = try await Stacks.sync(in: dir, host: nil); XCTFail("expected a conflict") }
        catch let e as StackError { guard case .conflict(let b, _) = e else { return XCTFail("\(e)") }; XCTAssertEqual(b, "b") }
        let x = await Stacks.load(in: dir).first { $0.branches.map(\.name) == ["x"] }
        XCTAssertEqual(x?.needsRestack, false)                       // x was restacked even though the stack of a, b, c stopped
    }

    func testAnOldHalfFinishedRebaseInTheCheckoutIsStillFoundAndAborted() async throws {
        try await buildStack()
        try await sh(["checkout", "b"]); try await commit("shared.txt", "from b\n", "b shared")
        try await sh(["checkout", "a"]); try await commit("shared.txt", "from a\n", "a shared")
        _ = try? await sh(["rebase", "--onto", "a", "a~1", "b"])      // what earlier versions left behind
        let p = await Stacks.pendingConflict(in: dir)
        XCTAssertEqual(p?.branch, "b"); XCTAssertEqual(p.map { URL(fileURLWithPath: $0.dir).resolvingSymlinksInPath().path }, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
        await Stacks.abortRestack(in: dir)
        let none = await Stacks.pendingConflict(in: dir); XCTAssertNil(none)
    }

    func testOverlapNamesFilesSharedAcrossStacksOnly() async throws {
        let o = Stacks.overlaps(changes: ["t002": ["ComposeField.swift", "a"], "t006": ["ComposeField.swift"], "t007": ["z"], "t002b": ["ComposeField.swift"]],
                                sameStack: { Set([$0, $1]) == ["t002", "t002b"] })
        XCTAssertEqual(o.map { "\($0.first)+\($0.second)" }, ["t002+t006", "t002b+t006"])
        XCTAssertEqual(o.first?.files, ["ComposeField.swift"])
    }

    func testOverlapReadsTheRealDiffs() async throws {
        try await sh(["checkout", "-b", "p"]); try await commit("shared.txt", "p\n", "p")
        try await sh(["checkout", "main"]); try await sh(["checkout", "-b", "q"]); try await commit("shared.txt", "q\n", "q")
        try await sh(["checkout", "main"])
        func branch(_ n: String) -> StackBranch { var b = StackBranch(name: n, parent: "main", base: nil, depth: 0); b.prState = "OPEN"; b.pr = 1; return b }
        let o = await Stacks.overlaps(of: [Stack(trunk: "main", branches: [branch("p")]), Stack(trunk: "main", branches: [branch("q")])], in: dir)
        XCTAssertEqual(o, [Stacks.Overlap(first: "p", second: "q", files: ["shared.txt"])])
    }

    func testWorktreesAreListedClassifiedAndRemoved() async throws {
        try await buildStack()
        let wt = NSTemporaryDirectory() + "cpilot-wt-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: wt) }
        try await sh(["checkout", "main"]); try await sh(["worktree", "add", wt, "b"])
        try write("x.txt", "wip\n"); try "wip\n".write(toFile: wt + "/b-wip.txt", atomically: true, encoding: .utf8)
        try await sh(["add", "b-wip.txt"], in: wt)
        var list = await Worktrees.list(in: dir)
        XCTAssertEqual(list.count, 2); XCTAssertEqual(list[0].kind, .main)
        XCTAssertEqual(list[1].kind, .other); XCTAssertEqual(list[1].branch, "b"); XCTAssertEqual(list[1].uncommitted, 1); XCTAssertTrue(list[1].holdsWork)
        let top = try await sh(["rev-parse", "--show-toplevel"], in: wt)
        list = await Worktrees.list(in: dir, sessionPaths: [top]); XCTAssertEqual(list[1].kind, .session)
        do { try await Worktrees.remove(list[0], in: dir, deleteBranch: false); XCTFail("main cannot go") } catch {}
        try await Worktrees.remove(list[1], in: dir, deleteBranch: true)
        let after = await Worktrees.list(in: dir); XCTAssertEqual(after.count, 1)
        let kept = try await sh(["branch", "--list", "b"]); XCTAssertFalse(kept.isEmpty)           // the branch held unsaved work, so it stays
    }

    func testAFolderDeletedBehindGitsBackIsPrunedAndALeftoverRestackFolderIsClearedWithItsJob() async throws {
        let stack = try await conflictSetup()
        do { _ = try await Stacks.restack(stack, in: dir) } catch {}
        let listed = await Worktrees.list(in: dir)
        let leftover = try XCTUnwrap(listed.first { $0.kind == .restack })
        XCTAssertTrue(leftover.rebasing)
        try await Worktrees.remove(leftover, in: dir, deleteBranch: false)
        let jobs = await Stacks.jobs(in: dir); XCTAssertTrue(jobs.isEmpty)
        let none = await Stacks.pendingConflicts(in: dir); XCTAssertTrue(none.isEmpty)
        let gone = NSTemporaryDirectory() + "cpilot-wt-\(UUID().uuidString.prefix(6))"
        try await sh(["worktree", "add", gone, "a"]); try FileManager.default.removeItem(atPath: gone)
        let stale = await Worktrees.list(in: dir); XCTAssertTrue(stale.contains { $0.missing })
        await Worktrees.prune(in: dir)
        let clean = await Worktrees.list(in: dir); XCTAssertFalse(clean.contains { $0.missing })
    }

    func testSubmitCreatesChainedPullRequestsThenUpdates() async throws {
        try await buildStack()
        let host = FakeHost()
        var stack = await Stacks.load(in: dir, host: host)[0]
        let numbers = try await Stacks.submit(stack, in: dir, host: host)
        XCTAssertEqual(host.calls, ["create a->main", "create b->a", "create c->b"])
        XCTAssertEqual(Set(numbers.keys), ["a", "b", "c"])
        XCTAssertTrue(host.bodies[numbers["b"]!]!.contains("cpilot-stack") && host.bodies[numbers["b"]!]!.contains("(this PR)"))
        host.calls = []
        stack = await Stacks.load(in: dir, host: host)[0]
        _ = try await Stacks.submit(stack, in: dir, host: host)
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("create") })      // existing pull requests are updated, not duplicated
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("base") }.count, 3)
        let remote = try await sh(["branch", "-r"]); XCTAssertTrue(remote.contains("origin/c"))
    }

    func testMergeBottomRetargetsChildFirst() async throws {
        try await buildStack()
        let host = FakeHost()
        var stack = await Stacks.load(in: dir, host: host)[0]
        _ = try await Stacks.submit(stack, in: dir, host: host)
        host.calls = []
        stack = await Stacks.load(in: dir, host: host)[0]
        let merged = try await Stacks.mergeBottom(stack, in: dir, host: host)
        XCTAssertEqual(merged, "a")
        XCTAssertEqual(host.calls, ["base #102->main", "merge #101"])       // the next PR is moved to main before the merge
    }

    // MARK: Collapsing

    func testCollapseCombinesSiblingBranchesIntoOneAndFinishClosesTheOthers() async throws {
        try await commit("shared.txt", "one\ntwo\nthree\n", "shared")
        try await sh(["push", "origin", "main"])
        try await Stacks.create("a", in: dir); try await commit("a.txt", "a\n", "add a")
        try await sh(["checkout", "a"]); try await Stacks.create("b", in: dir); try await commit("shared.txt", "one\ntwo b\nthree\n", "b edits shared")
        try await sh(["checkout", "a"]); try await Stacks.create("c", in: dir); try await commit("c.txt", "c\n", "add c")
        let host = FakeHost()
        let stack = await Stacks.load(in: dir, host: host)[0]
        _ = try await Stacks.submit(stack, in: dir, host: host)
        let fresh = await Stacks.load(in: dir, host: host)[0]
        let job = try await Stacks.startCollapse(fresh, in: dir)
        XCTAssertFalse(job.conflicted)
        XCTAssertEqual(job.applied, 3)
        XCTAssertEqual(Set(job.sources), ["a", "b", "c"])
        let files = try await sh(["ls-tree", "-r", "--name-only", job.branch])
        XCTAssertTrue(files.contains("a.txt") && files.contains("c.txt"))
        let shared = try await sh(["show", "\(job.branch):shared.txt"])
        XCTAssertTrue(shared.contains("two b"))
        try await sh(["config", "branch.\(job.branch).cpilot-title", "Everything"])
        let done = await Stacks.collapseFinished(job, in: dir)
        XCTAssertFalse(done)
        let number = try await Stacks.finishCollapse(job, in: dir, host: host)
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("create") }.last, "create \(job.branch)->main")
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("close") }.count, 3)
        XCTAssertTrue(host.prs.contains { $0.number == number && $0.title == "Everything" })
        let after = await Stacks.load(in: dir, host: host)
        XCTAssertEqual(after.flatMap(\.branches).map(\.name), [job.branch])
        let replaced = await Stacks.replacedBranches(in: dir)
        XCTAssertEqual(Set(replaced[job.branch] ?? []), ["a", "b", "c"])
    }

    func testCollapseStopsOnAConflictAndHandsOverTheRest() async throws {
        try await commit("shared.txt", "one\ntwo\nthree\n", "shared")
        try await sh(["push", "origin", "main"])
        try await Stacks.create("a", in: dir); try await commit("shared.txt", "one\ntwo from a\nthree\n", "a edits shared")
        try await sh(["checkout", "main"]); try await Stacks.create("b", in: dir); try await commit("shared.txt", "one\ntwo from b\nthree\n", "b edits shared")
        try await Stacks.create("c", in: dir); try await commit("c.txt", "c\n", "add c")
        // a and b are separate roots; combine them as one list to test the stop.
        let stack = Stack(trunk: "main", branches: [
            StackBranch(name: "a", parent: "main", base: nil, commits: 1, pr: 1, prState: "OPEN"),
            StackBranch(name: "b", parent: "main", base: nil, commits: 1, pr: 2, prState: "OPEN"),
            StackBranch(name: "c", parent: "b", base: nil, commits: 1, pr: 3, prState: "OPEN")])
        let job = try await Stacks.startCollapse(stack, in: dir)
        XCTAssertTrue(job.conflicted)
        XCTAssertEqual(job.pending.count, 1)
        XCTAssertTrue(job.pending[0].hasSuffix("add c"))
        XCTAssertTrue(Stacks.collapsePrompt(job).contains("cherry-pick"))
        await Stacks.abortCollapse(job, in: dir)
        let gone = await Stacks.gitOK(["rev-parse", "--verify", "--quiet", "refs/heads/\(job.branch)"], in: dir)
        XCTAssertFalse(gone)
    }

    func testOverlapGroupsJoinStacksThroughOverlaps() {
        func st(_ names: String...) -> Stack { Stack(trunk: "main", branches: names.map { StackBranch(name: $0, parent: "main", base: nil, commits: 1, pr: 1, prState: "OPEN") }) }
        let stacks = [st("a"), st("b"), st("c"), st("d")]
        let groups = Stacks.overlapGroups(stacks, overlaps: [.init(first: "a", second: "b", files: ["x"]), .init(first: "b", second: "c", files: ["y"])])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.id), ["a", "b", "c"])
        XCTAssertTrue(Stacks.overlapGroups(stacks, overlaps: []).isEmpty)
    }

    func testCollapseNeedsTwoOpenBranches() async throws {
        try await Stacks.create("a", in: dir); try await commit("a.txt", "a\n", "add a")
        let stack = await Stacks.load(in: dir)[0]
        do { _ = try await Stacks.startCollapse(stack, in: dir); XCTFail("one branch is nothing to combine") } catch {}
    }
}

final class RulesetTests: XCTestCase {
    func testOwnerCannotPushDirectlyByDefault() throws {
        func mode(_ on: Bool) throws -> String {
            let j = try JSONSerialization.jsonObject(with: Data(RepoSetup.rulesetJSON(requiredChecks: [], ownerMayPushDirectly: on).utf8)) as! [String: Any]
            return ((j["bypass_actors"] as! [[String: Any]])[0]["bypass_mode"]) as! String
        }
        XCTAssertEqual(try mode(false), "pull_request"); XCTAssertEqual(try mode(true), "always")
    }
}

final class SplitTests: XCTestCase {
    func testPlanParsingCoversEveryFileOnce() {
        let changed = ["a.txt", "b.txt", "c.txt", "d.txt"]
        let text = "Here is the plan:\n[{\"branch\":\"Add A!\",\"message\":\"add a\",\"files\":[\"a.txt\",\"nope.txt\"]},{\"branch\":\"b\",\"message\":\"add b\",\"files\":[\"b.txt\",\"a.txt\"]}]"
        let plan = Stacks.parsePlan(text, changed: changed)
        XCTAssertEqual(plan.map(\.branch), ["add-a", "b"])
        XCTAssertEqual(plan[0].files, ["a.txt"])
        XCTAssertEqual(plan[1].files, ["b.txt", "c.txt", "d.txt"])         // leftovers land in the last piece
        XCTAssertTrue(Stacks.parsePlan("no json here", changed: changed).isEmpty)
    }

    func testSplitBuildsAStackWhoseTopEqualsTheSource() async throws {
        let t = StackTests()
        try await t.setUp()
        let dir = t.dir
        try await t.sh(["checkout", "-b", "big"])
        for f in ["x.txt", "y.txt", "z.txt"] { try t.write(f, "\(f)\n") }
        try await t.sh(["add", "-A"]); try await t.sh(["commit", "-m", "everything"])
        let changed = await Stacks.changedFiles(source: "big", in: dir)
        XCTAssertEqual(Set(changed), ["x.txt", "y.txt", "z.txt"])
        let pieces = [Stacks.Piece(branch: "part-x", message: "add x", files: ["x.txt"]), Stacks.Piece(branch: "part-yz", message: "add y and z", files: ["y.txt", "z.txt"])]
        try await Stacks.split(source: "big", pieces: pieces, in: dir)
        let stack = await Stacks.load(in: dir)
        XCTAssertEqual(stack.first { $0.branches.contains { $0.name == "part-x" } }?.branches.map(\.name), ["part-x", "part-yz"])
        let diff = try await t.sh(["diff", "--stat", "big", "part-yz"]); XCTAssertEqual(diff, "")
        let first = try await t.sh(["ls-tree", "-r", "--name-only", "part-x"]); XCTAssertTrue(first.contains("x.txt") && !first.contains("y.txt"))
    }
}

final class SuggestTests: XCTestCase {
    func tmp(_ files: [String: String]) throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sug-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (n, t) in files { try t.write(to: d.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        return d.path
    }

    func testDescriptionAndTopicsFromProjectFiles() throws {
        let d = try tmp(["README.md": "# Hush\n\n[![CI](x)](y)\n\nA **quiet** menu bar app that reads [Telegram](https://t.me) for you.\n\n## Install\nrun it", "Package.swift": "platforms: [.macOS(.v14)]", "Dockerfile": ""])
        let s = RepoSetup.suggest(folder: d)
        XCTAssertEqual(s.description, "A quiet menu bar app that reads Telegram for you.")
        XCTAssertEqual(s.topics, ["swift", "macos", "docker"])
        let js = RepoSetup.suggest(folder: try tmp(["package.json": #"{"name":"x","description":"Tiny CLI"}"#, "tsconfig.json": "{}"]))
        XCTAssertEqual(js.description, "Tiny CLI"); XCTAssertEqual(js.topics, ["javascript", "nodejs", "typescript"])
        XCTAssertEqual(RepoSetup.suggest(folder: try tmp([:])).description, "")
    }
}

final class StackNextStepTests: XCTestCase {
    private func stack(behind: Int = 0, restack: Bool = false, pushed: Bool = true, prState: String? = "OPEN") -> Stack {
        var b = StackBranch(name: "a", parent: "main", base: nil, needsRestack: restack, commits: 1, pr: 2, prState: prState)
        b.pushed = pushed
        var s = Stack(trunk: "main", branches: [b]); s.trunkBehind = behind
        return s
    }

    func testStepsComeInOrder() {
        XCTAssertEqual(stack(behind: 3, restack: true, pushed: false).nextStep, .sync)
        XCTAssertEqual(stack(restack: true, pushed: false).nextStep, .restack)
        XCTAssertEqual(stack(pushed: false).nextStep, .submit)
        XCTAssertEqual(stack().nextStep, .merge)
        XCTAssertEqual(stack(prState: "MERGED").nextStep, .restack)   // a merged branch is cleared out by restacking
    }
}

final class TailscaleLinkTests: XCTestCase {
    func testFindsTheApprovalLinkInSshOutput() {
        let out = "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/lf3e68092d0bf3\n"
        XCTAssertEqual(Shell.tailscaleLink(in: out)?.absoluteString, "https://login.tailscale.com/a/lf3e68092d0bf3")
        XCTAssertNil(Shell.tailscaleLink(in: "Permission denied (publickey)."))
    }
    func testTimeoutWithoutBrowserApprovalIsExplained() {
        XCTAssertTrue(EnvironmentProbe.describe("# Tailscale SSH requires an additional check.").contains("approve"))
    }
}

final class DuplicateTitleTests: XCTestCase {
    func testSameTitleAlreadyOnBaseIsFound() {
        let base = [Git.Commit(sha: "8709ae1", subject: "Something else (#1)", when: ""), Git.Commit(sha: "40da634", subject: "Friendly, logged update failures; stop ControlServer cleanly", when: "")]
        let d = Git.findDuplicates([("title", "Friendly, logged update failures; stop ControlServer cleanly"), ("7091fff", "friendly, logged update failures; stop controlserver cleanly"), ("5cfd54e", "Capture every app error")], baseLog: base)
        XCTAssertEqual(d.map(\.onBase), ["40da634"])   // reported once, even though two of mine match it
        XCTAssertEqual(d.first?.mine, "title")
    }
    func testSquashSuffixIsIgnored() {
        let d = Git.findDuplicates([("title", "Something else")], baseLog: [Git.Commit(sha: "8709ae1", subject: "Something else (#1)", when: "")])
        XCTAssertEqual(d.count, 1)
    }
}

final class MergeSafetyGitTests: XCTestCase {
    private func sh(_ cmd: String, in dir: String) async throws {
        let r = try await Shell.run("sh", ["-c", cmd], cwd: URL(fileURLWithPath: dir))
        XCTAssertTrue(r.ok, "\(cmd): \(r.stderr)")
    }

    func testSameChangeUnderAnotherTitleAndFileCheck() async throws {
        let root = NSTemporaryDirectory() + "cpilot-merge-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let git = "git -c user.email=t@t -c user.name=t"
        try await sh("git init -q -b main origin && cd origin && echo one > a.txt && git add . && \(git) commit -qm base", in: root)
        try await sh("git clone -q origin work", in: root)
        let work = root + "/work", origin = root + "/origin"
        // The same edit lands on main under one title, and exists on a branch under another.
        try await sh("git checkout -q -b feature && echo two >> a.txt && \(git) commit -qam 'Rewritten title'", in: work)
        try await sh("echo two >> a.txt && \(git) commit -qam 'Original title'", in: origin)
        try await sh("git fetch -q origin", in: work)
        let found = await Git.alreadyOnBase(work, base: "main", head: "feature", subjects: [:])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].sameChange)

        // Files check: the branch tip's content for a.txt equals main's, so nothing differs.
        let tip = try await Shell.check("git", ["rev-parse", "feature"], cwd: URL(fileURLWithPath: work)).trimmingCharacters(in: .whitespacesAndNewlines)
        let same = await Git.filesDiffering(work, head: tip, base: "main", files: ["a.txt"])
        XCTAssertEqual(same, [])
        try await sh("echo three >> a.txt && \(git) commit -qam later", in: origin)
        let differ = await Git.filesDiffering(work, head: tip, base: "main", files: ["a.txt"])
        XCTAssertEqual(differ, ["a.txt"])
    }

    func testStackSurvivesTheCache() throws {
        var b = StackBranch(name: "a", parent: "main", base: "abc", commits: 2, depth: 0, pr: 7, prState: "OPEN", title: "T")
        b.mergeState = "BLOCKED"; b.prHead = "deadbeef"
        var st = Stack(trunk: "main", branches: [b]); st.trunkBehind = 3
        let back = try JSONDecoder().decode(Stack.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back, st)
        XCTAssertEqual(back.bottomOpen?.mergeState, "BLOCKED")
    }

    func testPolicyBlockIsRecognised() {
        let e = ShellError.failed(command: "gh pr merge 2", status: 1, stderr: "X Pull request #2 is not mergeable: the base branch policy prohibits the merge.")
        XCTAssertTrue(GitHub.isPolicyBlocked(e))
        XCTAssertFalse(GitHub.isPolicyBlocked(ShellError.failed(command: "gh", status: 1, stderr: "network down")))
    }
}

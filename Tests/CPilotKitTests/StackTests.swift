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

    func testConflictIsReportedAndCanBeAborted() async throws {
        try await buildStack()
        try await sh(["checkout", "b"]); try await commit("shared.txt", "from b\n", "b shared")
        try await sh(["checkout", "a"]); try await commit("shared.txt", "from a\n", "a shared")
        let stack = await Stacks.load(in: dir)[0]
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected a conflict") }
        catch let e as StackError { guard case .conflict(let b, let files) = e else { return XCTFail("\(e)") }; XCTAssertEqual(b, "b"); XCTAssertEqual(files, ["shared.txt"]) }
        await Stacks.abortRestack(in: dir)
        let status = try await sh(["status", "--porcelain", "--untracked-files=no"]); XCTAssertEqual(status, "")
    }

    func testDirtyTreeIsRefused() async throws {
        try await buildStack()
        try write("a.txt", "changed\n")
        let stack = await Stacks.load(in: dir)[0]
        do { _ = try await Stacks.restack(stack, in: dir); XCTFail("expected dirty") } catch { XCTAssertEqual(error as? StackError, .dirty) }
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

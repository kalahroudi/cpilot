// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class WorktreeCommandsTests: XCTestCase {
    let t1 = "/Users/me/Library/Application Support/CPilot/worktrees/aaa111", t2 = "/Users/me/Library/Application Support/CPilot/worktrees/bbb222"

    // MARK: Commands that name a folder

    func testACommandThatNamesAWorktreeRunsThereAndOnlyWhenTheFolderIsKnown() {
        let md = "For T001 run `cd '\(t1)' && pnpm guard:approve` and then `cd '\(t1)' && git add guard.lock.json`. For T002 `cd '\(t2)' && pnpm guard:approve`."
        let cmds = RunnableCommands.find(in: md, allowedDirectories: [t1, t2])
        XCTAssertEqual(cmds, [RunnableCommand(command: "pnpm guard:approve", directory: t1), RunnableCommand(command: "git add guard.lock.json", directory: t1), RunnableCommand(command: "pnpm guard:approve", directory: t2)])
        XCTAssertEqual(RunnableCommands.find(in: md, allowedDirectories: [t2]).map(\.directory), [t2])                          // a folder nobody listed is dropped
        XCTAssertEqual(RunnableCommands.find(in: md), [])                                                                          // and with no list nothing that names a folder is offered
        XCTAssertEqual(RunnableCommands.find(in: "run `cd / && rm -rf build`", allowedDirectories: [t1]), [])
        XCTAssertEqual(RunnableCommands.find(in: "`cd '\(t1)/packages/core' && pnpm test`", allowedDirectories: [t1]).first?.directory, t1 + "/packages/core")   // inside an allowed folder is fine
        XCTAssertEqual(RunnableCommands.find(in: "`cd '\(t1)/../../etc' && cat passwd`", allowedDirectories: [t1]), [])         // but not out of it
    }

    func testSpellingsOfTheFolderAndTheJoiner() {
        XCTAssertEqual(RunnableCommands.scoped("cd /a/b && swift test")?.directory, "/a/b")
        XCTAssertEqual(RunnableCommands.scoped("cd /a/b; swift test")?.command, "swift test")
        XCTAssertEqual(RunnableCommands.scoped("cd \"/a b/c\" && $ make test")?.directory, "/a b/c")
        XCTAssertEqual(RunnableCommands.scoped("cd ~/code/app && pnpm test")?.directory, NSHomeDirectory() + "/code/app")
        XCTAssertEqual(RunnableCommands.scoped("cd /a && pnpm a && pnpm b")?.command, "pnpm a && pnpm b")
        for bad in ["cd relative/path && ls", "cd /a", "cd /a &&", "cd '/a && ls", "ls /a", "cd /a ls"] { XCTAssertNil(RunnableCommands.scoped(bad), bad) }
    }

    func testAFencedBlockThatStartsWithCdRunsEachLineThere() {
        let md = """
        T001:
        ```bash
        cd '\(t1)'
        git diff --cached -- packages/core/src
        # then approve
        pnpm guard:approve
        git add guard.lock.json
        ```
        T002:
        ```
        cd '\(t2)' && pnpm guard:approve
        git add guard.lock.json
        ```
        """
        let cmds = RunnableCommands.find(in: md, allowedDirectories: [t1, t2])
        XCTAssertEqual(cmds.filter { $0.directory == t1 }.map(\.command), ["git diff --cached -- packages/core/src", "pnpm guard:approve", "git add guard.lock.json"])
        XCTAssertEqual(cmds.filter { $0.directory == t2 }.map(\.command), ["pnpm guard:approve", "git add guard.lock.json"])
        let long = "```\ncd '\(t1)'\n" + (1...20).map { "echo \($0)" }.joined(separator: "\n") + "\n```"
        XCTAssertEqual(RunnableCommands.find(in: long, allowedDirectories: [t1]).count, RunnableCommands.maxScopedLines)
    }

    func testPlainCommandsBehaveAsBefore() {
        XCTAssertEqual(RunnableCommands.find(in: "Run `swift test` now.").map(\.command), ["swift test"])
        XCTAssertEqual(RunnableCommands.find(in: "Run `swift test` now.").first?.directory, nil)
        XCTAssertEqual(RunnableCommands.find(in: "```\nswift test\n```").map(\.command), ["swift test"])
        XCTAssertEqual(RunnableCommands.find(in: "```\nls\npwd\n```"), [])                                   // several lines without a folder: not offered
        XCTAssertNotEqual(RunnableCommand(command: "x", directory: "/a").id, RunnableCommand(command: "x", directory: "/b").id)
    }

    // MARK: What runs in a worktree

    func testNodeScriptsAndThePackageManager() throws {
        let pkg = #"{"name": "rose", "packageManager": "pnpm@9.1.0", "scripts": {"build": "tsc", "guard:approve": "node scripts/guard.mjs --approve", "test": "vitest", "dev": "node dev.mjs", "pentest": "node scripts/pentest.mjs"}}"#
        let f = try XCTUnwrap(ProjectScripts.node(packageJSON: pkg, lockfiles: []))
        XCTAssertEqual(f.runner, "pnpm"); XCTAssertEqual(f.scripts, ["build", "dev", "guard:approve", "pentest", "test"])
        XCTAssertEqual(ProjectScripts.relevant(f.scripts), ["guard:approve", "pentest", "test", "build"])               // approvals and checks first, "dev" is not a step
        XCTAssertEqual(ProjectScripts.command(f, "guard:approve"), "pnpm run guard:approve")
        XCTAssertEqual(ProjectScripts.packageManager(lockfiles: ["yarn.lock"], packageManagerField: nil), "yarn")
        XCTAssertEqual(ProjectScripts.packageManager(lockfiles: ["pnpm-lock.yaml", "package-lock.json"], packageManagerField: nil), "pnpm")
        XCTAssertEqual(ProjectScripts.packageManager(lockfiles: [], packageManagerField: nil), "npm")
        XCTAssertEqual(ProjectScripts.packageManager(lockfiles: ["yarn.lock"], packageManagerField: "bun@1.1"), "bun")
        XCTAssertNil(ProjectScripts.node(packageJSON: "not json", lockfiles: [])); XCTAssertNil(ProjectScripts.node(packageJSON: #"{"name": "x"}"#, lockfiles: []))
    }

    func testMakeAndJustTargets() {
        let mk = "CC := clang\n.PHONY: build test\nbuild:\n\t$(CC) x\ntest: build\n\t./run\nlint:\n\techo\nVERSION:=1\nrelease::\n"
        XCTAssertEqual(ProjectScripts.make(mk)?.scripts, ["build", "test", "lint"])
        XCTAssertEqual(ProjectScripts.command(ProjectScripts.make(mk)!, "test"), "make test")
        let jf = "set shell := [\"bash\"]\nversion := \"1\"\n\ntest *args:\n  cargo test\n@check:\n  cargo check\n_private:\n  echo"
        XCTAssertEqual(ProjectScripts.just(jf)?.scripts, ["test", "check"])           // _private recipes are private to the justfile
        XCTAssertNil(ProjectScripts.make("nothing here")); XCTAssertNil(ProjectScripts.just(""))
    }

    func testGitStatusIsSplitIntoStagedUnstagedAndUntracked() {
        let s = GitStatusSummary.parse("M  packages/core/src/gateway.ts\nA  guard.lock.json\n M README.md\nMM both.ts\n?? notes.txt\nR  old.ts -> new.ts\n")
        XCTAssertEqual(s.staged, ["packages/core/src/gateway.ts", "guard.lock.json", "both.ts", "old.ts -> new.ts"])
        XCTAssertEqual(s.unstaged, ["README.md", "both.ts"]); XCTAssertEqual(s.untracked, ["notes.txt"])
        XCTAssertTrue(GitStatusSummary.parse("").isClean); XCTAssertFalse(s.isClean)
    }

    func testSuggestionsAreReadyToTypeFromAnywhere() {
        let found = ProjectScripts.Found(runner: "pnpm", scripts: ["build", "guard:approve", "dev"])
        let s = WorktreeCommands.suggestions(path: t1, status: GitStatusSummary(staged: ["a.ts"], unstaged: [], untracked: []), scripts: [found])
        XCTAssertEqual(s, ["cd '\(t1)' && git diff --cached --stat", "cd '\(t1)' && git diff --cached", "cd '\(t1)' && pnpm run guard:approve", "cd '\(t1)' && pnpm run build"])
        // every one of them is a command the chips understand, in its own folder
        for line in s { XCTAssertEqual(RunnableCommands.scoped(line)?.directory, t1, line) }
        XCTAssertEqual(WorktreeCommands.suggestions(path: "/w", status: GitStatusSummary(staged: [], unstaged: [], untracked: []), scripts: []), [])
        XCTAssertEqual(WorktreeCommands.suggestions(path: "/w", status: GitStatusSummary(staged: [], unstaged: ["a"], untracked: []), scripts: []), ["cd /w && git status --short"])
    }

    func testTheChiefKnowsTheToolAndHowToHandOverCommands() {
        XCTAssertEqual(ChiefPilot.Action(rawValue: "worktree_status"), .worktreeStatus)
        XCTAssertFalse(ChiefPilot.Action.worktreeStatus.startsWork); XCTAssertFalse(ChiefPilot.Action.worktreeStatus.needsApproval)
        for autonomy in ChiefPilot.Autonomy.allCases {
            let g = ChiefPilot.guidance(repo: "/code/rose", autonomy: autonomy)
            for expected in ["worktree_status {id?, task?}", "8c.", "`cd <worktree path> && <command>`", "never guess a script name", "Never tell the user to open or find a worktree"] { XCTAssertTrue(g.contains(expected), "\(autonomy): \(expected)") }
        }
    }

    /// Real git output, not a string written to match the parser.
    func testStatusParsingMatchesWhatGitReallyPrints() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir)
        func git(_ a: String...) async throws -> String { try await Shell.check("git", a, cwd: url, timeout: 30) }
        try await git("init", "-q", "-b", "main"); try await git("config", "user.email", "t@example.com"); try await git("config", "user.name", "T")
        try "a".write(toFile: dir + "/kept.txt", atomically: true, encoding: .utf8); try "a".write(toFile: dir + "/changed.txt", atomically: true, encoding: .utf8)
        try await git("add", "-A"); try await git("commit", "-q", "-m", "base")
        try "b".write(toFile: dir + "/changed.txt", atomically: true, encoding: .utf8)                       // unstaged
        try "new".write(toFile: dir + "/staged new.txt", atomically: true, encoding: .utf8); try await git("add", "staged new.txt")   // staged, with a space in the name
        try "x".write(toFile: dir + "/loose.txt", atomically: true, encoding: .utf8)                         // untracked
        let z = GitStatusSummary.parse(try await git("status", "--porcelain=v1", "-z")), lines = GitStatusSummary.parse(try await git("status", "--porcelain=v1"))
        for s in [z, lines] { XCTAssertEqual(s.staged, ["staged new.txt"]); XCTAssertEqual(s.unstaged, ["changed.txt"]); XCTAssertEqual(s.untracked, ["loose.txt"]) }
        try await git("mv", "kept.txt", "moved.txt")
        let renamed = GitStatusSummary.parse(try await git("status", "--porcelain=v1", "-z"))
        XCTAssertTrue(renamed.staged.contains("moved.txt")); XCTAssertFalse(renamed.staged.contains("kept.txt"))     // the old name of a rename is not a second change
        let s = z
        let cmds = WorktreeCommands.suggestions(path: dir, status: s, scripts: [])
        XCTAssertEqual(cmds.count, 3); XCTAssertTrue(cmds[0].hasSuffix("git diff --cached --stat"))
        XCTAssertEqual(RunnableCommands.find(in: "Run `\(cmds[0])`.", allowedDirectories: [dir]).first?.directory, dir)
    }
}

/// Gives the real Claude the chief pilot's guidance and what worktree_status would return for a blocked pre-commit guard, and checks that its message turns into buttons in each worktree.
/// Runs only when CPILOT_LIVE=1 (it uses a little quota).
final class LiveWorktreeHandoverTests: XCTestCase {
    func testTheChiefHandsOverCommandsPerWorktreeInAFormThePanelRuns() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_LIVE"] == "1", "set CPILOT_LIVE=1")
        let w1 = "/Users/me/Library/Application Support/CPilot/worktrees/6C41A2E0", w2 = "/Users/me/Library/Application Support/CPilot/worktrees/9F03B7D5"
        let tool = """
        {"worktrees": [
         {"task": "T001", "task_title": "/svc gateway host escape", "branch": "spec-001-t001", "worktree": "\(w1)", "state": "idle", "role": "task",
          "staged": ["packages/core/src/gateway.ts", "packages/core/test/gateway.test.ts"], "unstaged": [], "untracked": [],
          "scripts": [{"runner": "pnpm", "names": ["guard:approve", "pentest", "test", "build"]}],
          "commands": ["cd '\(w1)' && git diff --cached --stat", "cd '\(w1)' && git diff --cached", "cd '\(w1)' && pnpm run guard:approve", "cd '\(w1)' && pnpm run pentest"]},
         {"task": "T002", "task_title": "development mode fails closed", "branch": "spec-001-t002", "worktree": "\(w2)", "state": "idle", "role": "task",
          "staged": ["packages/core/src/env.ts", "packages/core/src/tenant-app.ts"], "unstaged": [], "untracked": [],
          "scripts": [{"runner": "pnpm", "names": ["guard:approve", "pentest", "test", "build"]}],
          "commands": ["cd '\(w2)' && git diff --cached --stat", "cd '\(w2)' && git diff --cached", "cd '\(w2)' && pnpm run guard:approve", "cd '\(w2)' && pnpm run pentest"]}
        ]}
        """
        let prompt = """
        \(ChiefPilot.guidance(repo: "/Users/me/code/rose", autonomy: .leads))

        Situation: both tasks T001 and T002 are written and staged but not committed. The repository's pre-commit hook refuses protected-file changes until the user reviews them and runs the guard's approve script in each worktree, then commits. You cannot do this yourself.
        You called worktree_status and it returned:
        \(tool)

        Write your message to the user now, and end with a STATUS line.
        """
        let reply = await ClaudeOneShot.run(prompt, in: NSTemporaryDirectory(), model: "sonnet", timeout: 240)
        let answer = try XCTUnwrap(reply, "Claude did not answer")
        print("LIVE HANDOVER: \(answer.prefix(1500))")
        let cmds = RunnableCommands.find(in: answer, allowedDirectories: [w1, w2])
        XCTAssertFalse(cmds.filter { $0.directory == w1 }.isEmpty, "no button for T001's worktree")
        XCTAssertFalse(cmds.filter { $0.directory == w2 }.isEmpty, "no button for T002's worktree")
        for dir in [w1, w2] { XCTAssertTrue(cmds.contains { $0.directory == dir && $0.command.contains("guard:approve") }, "no approve command for \(dir)") }
        XCTAssertFalse(answer.lowercased().contains("go to the worktree") || answer.lowercased().contains("open the worktree"), "it still tells the user to visit worktrees")
    }
}

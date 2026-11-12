// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

/// These run real git in a throwaway repository.
final class TestLockTests: XCTestCase {
    var dir = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.email", "t@example.com"); try await git("config", "user.name", "Tester")
        try write("Sources/Gateway.swift", "func resolve() {}\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "base")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult func git(_ args: String...) async throws -> String { try await Shell.check("git", args, cwd: URL(fileURLWithPath: dir)).trimmingCharacters(in: .whitespacesAndNewlines) }
    func write(_ path: String, _ text: String) throws {
        let u = URL(fileURLWithPath: dir).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ path: String) -> String? { try? String(contentsOfFile: dir + "/" + path, encoding: .utf8) }

    /// The tester's branch: two visible test files and one hidden one, in two commits.
    func makeTesterBranch() async throws {
        try await git("checkout", "-q", "-b", "tests-t003")
        try write("Tests/GatewayTests.swift", "func testPathStaysOnOrigin() {}\nfunc testNeverLeaves() {}\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "first tests")
        try write("Tests/AbuseTests.swift", "func testBackslashPath() {}\n")
        try write("Tests/HiddenGatewayTests.swift", "func testDoubleSlashHost() {}\nfunc testUnicodeHost() {}\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "more tests")
    }

    func testFreezeSplitsVisibleFromHiddenAndTheBranchCannotReachTheHiddenOnes() async throws {
        try await makeTesterBranch()
        let trace = ["A2": ["testPathStaysOnOrigin", "testDoubleSlashHost"], "A3": ["testUnicodeHost"], "R2": ["testNeverLeaves"]]
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "014-t003", hidden: ["Tests/HiddenGatewayTests.swift"], trace: trace, message: "T003 tests")
        XCTAssertEqual(Set(l.files.keys), ["Tests/GatewayTests.swift", "Tests/AbuseTests.swift"])
        XCTAssertEqual(l.hiddenFiles, ["Tests/HiddenGatewayTests.swift"]); XCTAssertEqual(l.hiddenRef, "refs/cpilot/hidden/014-t003")
        XCTAssertEqual(l.hiddenTrace, ["A2": ["testDoubleSlashHost"], "A3": ["testUnicodeHost"]])      // only the hidden tests, by requirement
        let v1 = try await git("rev-parse", "HEAD")
        XCTAssertEqual(l.commit, v1)
        // The branch has the visible tests and one commit on top of main...
        let v2 = try await git("rev-list", "--count", "main..HEAD")
        XCTAssertEqual(v2, "1")
        let v3 = try await git("show", "HEAD:Tests/GatewayTests.swift")
        XCTAssertEqual(v3, "func testPathStaysOnOrigin() {}\nfunc testNeverLeaves() {}")
        // ...but nothing reachable from it holds the hidden file, in any commit.
        let all = try await git("log", "--name-only", "--format=", "HEAD")
        XCTAssertFalse(all.contains("HiddenGatewayTests"))
        let v4 = try await git("show", "refs/cpilot/hidden/014-t003:Tests/HiddenGatewayTests.swift")
        XCTAssertEqual(v4, "func testDoubleSlashHost() {}\nfunc testUnicodeHost() {}")
        let branchesContaining = try await git("branch", "--contains", "refs/cpilot/hidden/014-t003")
        XCTAssertEqual(branchesContaining, "", "no branch may contain the hidden commit")
    }

    func testFreezeWithoutHiddenKeepsTheCommitsAsTheyAre() async throws {
        try await makeTesterBranch()
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: [], trace: [:], message: "x")
        let v5 = try await git("rev-list", "--count", "main..HEAD")
        XCTAssertNil(l.hiddenRef); XCTAssertEqual(l.files.count, 3); XCTAssertEqual(v5, "2")
    }

    func testFreezeRefusesBadHiddenChoices() async throws {
        try await makeTesterBranch()
        do { _ = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: ["Tests/Nope.swift"], trace: [:], message: "x"); XCTFail("unknown file") }
        catch { XCTAssertTrue("\(error)".contains("Tests/Nope.swift")) }
        do { _ = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: ["Tests/GatewayTests.swift", "Tests/AbuseTests.swift", "Tests/HiddenGatewayTests.swift"], trace: [:], message: "x"); XCTFail("all hidden") }
        catch { XCTAssertTrue("\(error)".contains("visible")) }
    }

    func testVerifyCatchesEditDeleteRenameAndUncommittedChangesAndRestoreFixesThem() async throws {
        try await makeTesterBranch()
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: [], trace: [:], message: "x")
        let none = await TestLock.verify(worktree: dir, l)
        XCTAssertEqual(none, [])
        // new code and new tests of the implementer's own are fine
        try write("Sources/Gateway.swift", "func resolve() { /* real */ }\n"); try write("Tests/MyOwnTests.swift", "func testMine() {}\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "impl")
        let still = await TestLock.verify(worktree: dir, l)
        XCTAssertEqual(still, [])

        try write("Tests/GatewayTests.swift", "func testNeverLeaves() {}\n")                        // weakened but uncommitted
        var p = await TestLock.verify(worktree: dir, l)
        XCTAssertEqual(p.count, 1); XCTAssertTrue(p[0].contains("Tests/GatewayTests.swift")); XCTAssertTrue(p[0].contains("changed"))
        try await git("add", "-A"); try await git("commit", "-q", "-m", "weaken")                    // now committed too
        p = await TestLock.verify(worktree: dir, l); XCTAssertEqual(p.count, 1)
        try FileManager.default.removeItem(atPath: dir + "/Tests/AbuseTests.swift")
        p = await TestLock.verify(worktree: dir, l); XCTAssertEqual(p.count, 2); XCTAssertTrue(p.contains { $0.contains("deleted or renamed") })
        try await git("mv", "Tests/GatewayTests.swift", "Tests/Renamed.swift")
        p = await TestLock.verify(worktree: dir, l); XCTAssertEqual(p.count, 2)

        await TestLock.restore(worktree: dir, l)
        let uncommitted = await TestLock.verify(worktree: dir, l)
        XCTAssertEqual(uncommitted.count, 1)                       // the last commit still holds the weakened file until the restoration is committed
        try await git("commit", "-q", "-m", "restore the locked tests")
        let after = await TestLock.verify(worktree: dir, l)
        XCTAssertEqual(after, [])
        XCTAssertEqual(read("Tests/GatewayTests.swift"), "func testPathStaysOnOrigin() {}\nfunc testNeverLeaves() {}\n")
    }

    func testHiddenTestsRunAgainstTheCodeAndLeaveTheWorktreeClean() async throws {
        try await makeTesterBranch()
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: ["Tests/HiddenGatewayTests.swift"], trace: ["A2": ["testDoubleSlashHost"]], message: "x")
        try write("Sources/Gateway.swift", "func resolve() { /* real */ }\n"); try await git("add", "-A"); try await git("commit", "-q", "-m", "impl")
        var seen = false
        let r = await TestLock.runHidden(worktree: dir, l, commands: ["check"]) { cmd in
            seen = FileManager.default.fileExists(atPath: self.dir + "/Tests/HiddenGatewayTests.swift")      // the file is there while the command runs
            return GateCheck(command: cmd, ok: false, output: "Test Case 'testDoubleSlashHost' failed")
        }
        XCTAssertTrue(seen); XCTAssertNil(r.problem); XCTAssertEqual(r.checks.count, 1)
        XCTAssertEqual(TestLock.failedHiddenIds(output: r.checks[0].output, l), ["A2"])
        XCTAssertNil(read("Tests/HiddenGatewayTests.swift"))                                                  // and gone afterwards
        let v6 = try await git("status", "--porcelain")
        XCTAssertEqual(v6, "")
        // a second command is not run after one fails
        let stop = await TestLock.runHidden(worktree: dir, l, commands: ["a", "b"]) { GateCheck(command: $0, ok: false, output: "x") }
        XCTAssertEqual(stop.checks.map(\.command), ["a"])
        let none = await TestLock.runHidden(worktree: dir, LockedTests(commit: l.commit, files: l.files), commands: ["a"]) { GateCheck(command: $0, ok: true, output: "") }
        XCTAssertTrue(none.checks.isEmpty); XCTAssertNil(none.problem)
    }

    func testImplementerCreatingAFileAtAHiddenPathIsNotOverwrittenOrDeleted() async throws {
        try await makeTesterBranch()
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: ["Tests/HiddenGatewayTests.swift"], trace: [:], message: "x")
        try write("Tests/HiddenGatewayTests.swift", "the implementer's own file\n")
        let r = await TestLock.runHidden(worktree: dir, l, commands: ["x"]) { GateCheck(command: $0, ok: true, output: "") }
        XCTAssertNotNil(r.problem); XCTAssertTrue(r.checks.isEmpty)
        XCTAssertEqual(read("Tests/HiddenGatewayTests.swift"), "the implementer's own file\n")
    }

    func testFeedbackNamesRequirementsAndNeverShowsTests() {
        let criteria = [Specs.Criterion(id: "A2", text: "A path starting with // stays on the origin.", checks: [])]
        let m = TestLock.hiddenFeedback(failedIds: ["A2"], criteria: criteria)
        XCTAssertTrue(m.contains("A2: A path starting with // stays on the origin.")); XCTAssertTrue(m.contains("not shown"))
        XCTAssertTrue(TestLock.hiddenFeedback(failedIds: [], criteria: criteria).contains("not shown"))
        XCTAssertEqual(TestLock.failedHiddenIds(output: "nothing about tests", LockedTests(commit: "c", files: [:], hiddenTrace: ["A2": ["testX"]])), [])
    }

    func testDropHiddenRemovesTheRef() async throws {
        try await makeTesterBranch()
        let l = try await TestLock.freeze(worktree: dir, parent: "main", key: "k", hidden: ["Tests/HiddenGatewayTests.swift"], trace: [:], message: "x")
        await TestLock.dropHidden(repo: dir, l)
        let r = try await Shell.run("git", ["rev-parse", "--verify", "--quiet", "refs/cpilot/hidden/k"], cwd: URL(fileURLWithPath: dir))
        XCTAssertFalse(r.ok)
    }

    func testHoldBackKeepsAWholeTestersWorkOnlyInARef() async throws {
        try await makeTesterBranch()
        let h = try await TestLock.holdBack(worktree: dir, parent: "main", key: "b", trace: ["A2": ["testDoubleSlashHost", "testNotThere"], "R9": ["testUnrelated"]])
        XCTAssertEqual(h.ref, "refs/cpilot/hidden/b"); XCTAssertEqual(h.files, ["Tests/AbuseTests.swift", "Tests/GatewayTests.swift", "Tests/HiddenGatewayTests.swift"])
        XCTAssertEqual(h.trace, ["A2": ["testDoubleSlashHost"]])
        let refTip = try await git("rev-parse", h.ref), headTip = try await git("rev-parse", "HEAD")
        XCTAssertEqual(refTip, headTip)
        // it works as the held-back set of a task whose branch has only another tester's visible tests
        try await git("checkout", "-q", "main"); try await git("checkout", "-q", "-b", "task")
        try write("Tests/FirstTests.swift", "func testFirst() {}\n"); try await git("add", "-A"); try await git("commit", "-q", "-m", "visible")
        let l = LockedTests(commit: try await git("rev-parse", "HEAD"), files: ["Tests/FirstTests.swift": try await git("rev-parse", "HEAD:Tests/FirstTests.swift")], hiddenRef: h.ref, hiddenFiles: h.files, hiddenTrace: h.trace)
        var seen: [String] = []
        let r = await TestLock.runHidden(worktree: dir, l, commands: ["x"]) { cmd in
            seen = h.files.filter { FileManager.default.fileExists(atPath: self.dir + "/" + $0) }
            return GateCheck(command: cmd, ok: true, output: "")
        }
        XCTAssertNil(r.problem); XCTAssertEqual(seen, h.files)
        let clean = try await git("status", "--porcelain")
        XCTAssertEqual(clean, "")
        do { _ = try await TestLock.holdBack(worktree: dir, parent: "task", key: "c", trace: [:]); XCTFail("nothing changed") } catch { XCTAssertTrue("\(error)".contains("No test file")) }
    }
}

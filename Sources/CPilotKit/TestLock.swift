// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The tester's work, frozen. The visible tests are one commit on the task's branch, whose files are recorded by content hash; the hidden ones live only in a ref that no branch reaches
/// and is never pushed, so the implementer cannot read them from the history.
public struct LockedTests: Codable, Equatable, Sendable {
    /// The task branch's tip with the visible tests in it.
    public var commit: String
    /// Visible test file → its content hash (`git hash-object`).
    public var files: [String: String]
    /// Where the hidden tests are kept, and which files they are. Nil when there are none.
    public var hiddenRef: String?
    public var hiddenFiles: [String]
    /// Requirement or rule id → the hidden tests that cover it, so a failure can be reported by requirement without showing the test.
    public var hiddenTrace: [String: [String]]
    public var disputes: Int
    public init(commit: String, files: [String: String], hiddenRef: String? = nil, hiddenFiles: [String] = [], hiddenTrace: [String: [String]] = [:], disputes: Int = 0) {
        self.commit = commit; self.files = files; self.hiddenRef = hiddenRef; self.hiddenFiles = hiddenFiles; self.hiddenTrace = hiddenTrace; self.disputes = disputes
    }
}

public enum TestLock {
    public enum Failure: Error, Equatable, LocalizedError {
        case message(String)
        public var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
    }

    private static func git(_ args: [String], in dir: String, timeout: TimeInterval = 60) async throws -> String {
        try await Shell.check("git", args, cwd: URL(fileURLWithPath: dir), timeout: timeout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ok(_ args: [String], in dir: String) async -> Bool {
        (try? await Shell.run("git", args, cwd: URL(fileURLWithPath: dir), timeout: 60))?.ok == true
    }

    /// The test files the tester changed on top of `parent`, as path → text.
    public static func changedFiles(worktree: String, parent: String) async throws -> [String: String] {
        let names = try await git(["diff", "--name-only", "--diff-filter=ACMR", "\(parent)...HEAD"], in: worktree).split(whereSeparator: \.isNewline).map(String.init)
        var out: [String: String] = [:]
        for n in names { out[n] = (try? await git(["show", "HEAD:\(n)"], in: worktree)) ?? "" }
        return out
    }

    /// Freezes the tester's commits. `key` names the hidden ref. Files in `hidden` are taken out of the commit that goes on the branch and kept only in the hidden ref.
    /// Throws when nothing visible would be left, or a hidden path is not one the tester changed.
    public static func freeze(worktree: String, parent: String, key: String, hidden: [String], trace: [String: [String]], message: String) async throws -> LockedTests {
        let changed = try await changedFiles(worktree: worktree, parent: parent)
        let hiddenSet = Set(hidden)
        guard hiddenSet.isSubset(of: Set(changed.keys)) else { throw Failure.message("The hidden files must be test files you changed: " + hiddenSet.subtracting(changed.keys).sorted().joined(separator: ", ") + ".") }
        let visible = changed.keys.filter { !hiddenSet.contains($0) }.sorted()
        guard !visible.isEmpty else { throw Failure.message("At least some tests must be visible to the implementer. Every test file was marked hidden.") }
        var ref: String?
        if !hiddenSet.isEmpty {
            let r = "refs/cpilot/hidden/\(key)"
            try await git(["update-ref", r, "HEAD"], in: worktree)
            let base = try await git(["merge-base", parent, "HEAD"], in: worktree)
            try await git(["reset", "--soft", base], in: worktree)
            try await git(["reset", "-q", "HEAD", "--"] + hidden.sorted(), in: worktree)
            try await git(["commit", "-q", "-m", message], in: worktree)
            // They live in the ref now; take them out of the checkout so nothing here can show them to the implementer.
            for f in hidden { try? FileManager.default.removeItem(atPath: worktree + "/" + f) }
            ref = r
        }
        let head = try await git(["rev-parse", "HEAD"], in: worktree)
        var files: [String: String] = [:]
        for f in visible { files[f] = try await git(["rev-parse", "HEAD:\(f)"], in: worktree) }
        let hiddenTrace = trace.mapValues { names in names.filter { n in hiddenSet.contains { changed[$0]?.contains(TestFirst.testBaseName(n)) == true } } }.filter { !$0.value.isEmpty }
        return LockedTests(commit: head, files: files, hiddenRef: ref, hiddenFiles: hidden.sorted(), hiddenTrace: hiddenTrace)
    }

    /// What is wrong with the locked tests in `worktree`: a file changed, deleted, or left different from the commit. Empty when they are exactly as the tester wrote them.
    public static func verify(worktree: String, _ locked: LockedTests) async -> [String] {
        var out: [String] = []
        for (path, hash) in locked.files.sorted(by: { $0.key < $1.key }) {
            let committed = try? await git(["rev-parse", "HEAD:\(path)"], in: worktree)
            let working = (try? await git(["hash-object", "--", path], in: worktree))
            if committed == nil || working == nil { out.append("`\(path)` is a locked test and was deleted or renamed. Locked tests are not removed."); continue }
            if committed != hash || working != hash { out.append("`\(path)` is a locked test and was changed. Locked tests are not edited, weakened or skipped; fix the code instead.") }
        }
        return out
    }

    /// Puts the locked files back exactly as the tester wrote them, in the working tree and the index.
    public static func restore(worktree: String, _ locked: LockedTests) async {
        _ = try? await git(["checkout", locked.commit, "--"] + locked.files.keys.sorted(), in: worktree)
    }

    /// Runs the held-back tests against the code in `worktree` (its last commit), then leaves the worktree as it found it. `run` executes one command in the right place and returns what it printed.
    /// Returns nil when there are no hidden tests, or what went wrong before they could run.
    public static func runHidden(worktree: String, _ locked: LockedTests, commands: [String], run: (String) async -> GateCheck) async -> (checks: [GateCheck], problem: String?) {
        guard let ref = locked.hiddenRef, !locked.hiddenFiles.isEmpty else { return ([], nil) }
        let files = locked.hiddenFiles
        for f in files where await ok(["cat-file", "-e", "HEAD:\(f)"], in: worktree) || FileManager.default.fileExists(atPath: worktree + "/" + f) {
            return ([], "`\(f)` is the path of a held-back test, but a file is already there. Use another name for that file.")
        }
        guard await ok(["checkout", ref, "--"] + files, in: worktree) else { return ([], "The held-back tests could not be put in place.") }
        var checks: [GateCheck] = []
        for c in commands {
            let r = await run(c)
            checks.append(r)
            if !r.ok { break }
        }
        _ = try? await git(["rm", "-q", "-f", "--cached", "--ignore-unmatch", "--"] + files, in: worktree)
        for f in files { try? FileManager.default.removeItem(atPath: worktree + "/" + f) }
        return (checks, nil)
    }

    /// Which requirements' held-back tests failed in this output, found by the names of their tests. The output itself is never shown to the implementer.
    public static func failedHiddenIds(output: String, _ locked: LockedTests) -> [String] {
        locked.hiddenTrace.filter { $0.value.contains { output.contains(TestFirst.testBaseName($0)) } }.keys.sorted()
    }

    /// What goes back to the implementer for a failed held-back run: the requirements, never the tests or their output.
    public static func hiddenFeedback(failedIds: [String], criteria: [Specs.Criterion]) -> String {
        let lines = failedIds.map { id in "- \(id)" + (criteria.first { $0.id == id }.map { ": " + $0.text } ?? "") }
        if lines.isEmpty { return "Checks that CPilot holds back fail. Their output is not shown, so look again at every requirement of this task and make sure the code does what each one says, including bad input, limits and every setting, then commit." }
        return "Checks that CPilot holds back fail for these requirements. Their output is not shown, so make the code do what each one says, including bad input, limits and every setting, then commit:\n" + lines.joined(separator: "\n")
    }

    /// Takes a task's hidden ref away once the task is merged or dropped.
    public static func dropHidden(repo: String, _ locked: LockedTests) async {
        if let ref = locked.hiddenRef { _ = try? await git(["update-ref", "-d", ref], in: repo) }
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

/// Drives CPilot's own code against a real GitHub repository it creates for the purpose.
/// Opt in with CPILOT_GITHUB_LIVE=1. It creates `<you>/cpilot-sandbox` (or CPILOT_SANDBOX), opens and merges pull requests there,
/// and leaves the repository behind for you to look at and delete.
final class LiveGitHubTests: XCTestCase {
    func say(_ s: String) { FileHandle.standardError.write(Data(("[live] " + s + "\n").utf8)) }
    func git(_ args: [String], _ dir: String) async throws -> String {
        try await Shell.check("git", args, cwd: URL(fileURLWithPath: dir), timeout: 120).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func gh(_ args: [String], _ dir: String? = nil) async throws -> String {
        try await Shell.check("gh", args, cwd: dir.map { URL(fileURLWithPath: $0) }, timeout: 120).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRealRepositoryEndToEnd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_GITHUB_LIVE"] == "1", "live GitHub test")
        guard let account = await GitHub.account() else { return XCTFail("not signed in to GitHub") }
        let owner = account.login, name = ProcessInfo.processInfo.environment["CPILOT_SANDBOX"] ?? "cpilot-sandbox"
        let slug = "\(owner)/\(name)"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: work + "/src", withIntermediateDirectories: true)
        try "export function hello(name) { return `Hello, ${name}!` }\n".write(toFile: work + "/src/hello.js", atomically: true, encoding: .utf8)

        // 1. Repo setup: create, README, license, pages, topics, protected main.
        var plan = RepoSetupPlan(owner: owner, name: name)
        plan.description = "A throwaway repository used to test CPilot. Safe to delete."
        plan.topics = ["cpilot-test"]; plan.pages = true; plan.protectMain = true; plan.securityScan = false
        var log: [String] = []
        let lock = NSLock()
        try await RepoSetup.run(plan, folder: work) { l in lock.lock(); log.append(l); lock.unlock() }
        say("repo setup: " + log.joined(separator: " | "))
        let repo = try await gh(["api", "repos/\(slug)"])
        let info = try JSONSerialization.jsonObject(with: Data(repo.utf8)) as! [String: Any]
        XCTAssertEqual(info["description"] as? String, plan.description)
        XCTAssertEqual(info["allow_auto_merge"] as? Bool, true); XCTAssertEqual(info["delete_branch_on_merge"] as? Bool, true)
        XCTAssertTrue((info["topics"] as? [String])?.contains("cpilot-test") == true)
        let rulesets = try await gh(["api", "repos/\(slug)/rulesets"])
        XCTAssertTrue(rulesets.contains("Protect main"), "ruleset missing: \(rulesets.prefix(200))")
        let pages = try? await gh(["api", "repos/\(slug)/pages"]); XCTAssertNotNil(pages, "pages not enabled")
        let tree = try await git(["ls-tree", "-r", "--name-only", "origin/main"], work)
        XCTAssertTrue(tree.contains("README.md") && tree.contains("LICENSE") && tree.contains("docs/index.html") && tree.contains("src/hello.js"))
        say("repo setup verified: description, topics, merge settings, ruleset, pages, files")

        // main is protected now: a direct push must be refused.
        try "x\n".write(toFile: work + "/direct.txt", atomically: true, encoding: .utf8)
        _ = try await git(["checkout", "main"], work)
        try await git(["add", "-A"], work).isEmpty ? () : ()
        _ = try? await git(["-c", "user.name=T", "-c", "user.email=t@t.co", "commit", "-m", "direct"], work)
        let direct = try await Shell.run("git", ["push", "origin", "main"], cwd: URL(fileURLWithPath: work), timeout: 60)
        say("direct push to protected main: exit \(direct.status) \(direct.stderr.split(separator: "\n").first.map(String.init) ?? "")")
        XCTAssertNotEqual(direct.status, 0, "main should refuse a direct push, even from the owner")
        _ = try? await git(["reset", "--hard", "origin/main"], work)

        // 2. Issues.
        let issueURL = try await gh(["issue", "create", "--repo", slug, "--title", "Add a farewell function", "--body", "We have hello(name). Add goodbye(name) that returns `Goodbye, <name>!`, with a test."])
        let issueNumber = Int(issueURL.split(separator: "/").last ?? "") ?? 0
        let listed = try await GitHub.issues(in: work)
        XCTAssertTrue(listed.contains { $0.number == issueNumber })
        let full = try await GitHub.issue(issueNumber, in: work)
        XCTAssertTrue(full.requirementText().contains("goodbye"))
        say("issues: created #\(issueNumber), listed and read it")

        // 3. Spec pipeline from the issue, with real Claude, read only.
        let src = SpecPrompts.specify(requirement: full.requirementText(), source: "Issue #\(issueNumber)", constitution: Specs.defaultConstitution, assume: true)
        let spec = SpecPrompts.extractDocument(try await SpecStageRunner.run(prompt: src, cwd: work, model: "haiku"))
        let plantext = SpecPrompts.extractDocument(try await SpecStageRunner.run(prompt: SpecPrompts.plan(spec: spec, constitution: nil), cwd: work, model: "haiku"))
        let tasksText = SpecPrompts.extractDocument(try await SpecStageRunner.run(prompt: SpecPrompts.tasks(spec: spec, plan: plantext, constitution: nil), cwd: work, model: "haiku"))
        let tasks = Specs.parseTasks(tasksText)
        XCTAssertGreaterThanOrEqual(tasks.count, 1)
        let id = Specs.folderName(number: 1, title: Specs.title(of: spec) ?? "farewell")
        try await Specs.write("\(Specs.folder)/\(id)/spec.md", spec, in: work); try await Specs.write("\(Specs.folder)/\(id)/plan.md", plantext, in: work); try await Specs.write("\(Specs.folder)/\(id)/tasks.md", tasksText, in: work)
        let (docs, _) = await Specs.list(in: work)
        XCTAssertEqual(docs.first?.status(), .ready)
        say("spec: \(docs.first?.title ?? "?") with \(tasks.count) tasks: " + tasks.map { "\($0.id) \($0.title)" }.joined(separator: " | "))
        try await git(["checkout", "--", "."], work); _ = try? await git(["clean", "-fd", "specs"], work)

        // 4. A stack of two branches, submitted as chained pull requests.
        _ = try await git(["checkout", "main"], work)
        try await Stacks.create("farewell-function", in: work)
        try "export function goodbye(name) { return `Goodbye, ${name}!` }\n".write(toFile: work + "/src/goodbye.js", atomically: true, encoding: .utf8)
        _ = try await git(["add", "-A"], work); _ = try await git(["-c", "user.name=T", "-c", "user.email=t@t.co", "commit", "-m", "Add goodbye()"], work)
        try await Stacks.create("farewell-test", in: work)
        try "import { goodbye } from './goodbye.js'\nconsole.assert(goodbye('a') === 'Goodbye, a!')\n".write(toFile: work + "/src/goodbye.test.js", atomically: true, encoding: .utf8)
        _ = try await git(["add", "-A"], work); _ = try await git(["-c", "user.name=T", "-c", "user.email=t@t.co", "commit", "-m", "Test goodbye()"], work)
        let host = LiveStackHost(dir: work)
        var stack = await Stacks.load(in: work, host: host)[0]
        XCTAssertEqual(stack.branches.map(\.name), ["farewell-function", "farewell-test"])
        let numbers = try await Stacks.submit(stack, in: work, host: host)
        let a = numbers["farewell-function"] ?? 0, b = numbers["farewell-test"] ?? 0
        XCTAssertGreaterThan(a, 0); XCTAssertGreaterThan(b, 0)
        let prB = try await GitHub.view(b, in: work)
        XCTAssertEqual(prB.baseRefName, "farewell-function", "the second pull request should sit on the first")
        XCTAssertTrue(prB.body?.contains("cpilot-stack") == true, "stack list missing from the body")
        say("stack: submitted #\(a) (base main) and #\(b) (base farewell-function)")

        // 5. Pull request screens: list, view, diff, checks, review, comment, gate, inbox.
        let open = try await GitHub.list(in: work)
        XCTAssertTrue(open.contains { $0.number == a } && open.contains { $0.number == b })
        let diff = DiffParser.parse(try await GitHub.diff(b, in: work))
        XCTAssertEqual(diff.map(\.path), ["src/goodbye.test.js"]); XCTAssertEqual(diff.first?.additions, 2)
        let checks = await GitHub.checks(a, in: work)
        try await GitHub.comment(a, body: "Comment posted by CPilot's live test.", in: work)
        try await GitHub.review(a, action: .comment, body: "Reviewed by CPilot's live test.", in: work)
        let gate = MergeGate.evaluate(pr: try await GitHub.view(a, in: work), checks: checks, scan: nil, requireScan: false)
        XCTAssertTrue(gate.ready, "gate: \(gate.reasons)")
        let inbox = await GitHub.inbox(repo: slug)
        XCTAssertTrue(inbox.mine.contains { $0.repository.nameWithOwner == slug && $0.number == a }, "inbox did not list the pull request")
        say("pull requests: list, view, diff (\(diff.count) file), checks (\(checks.count)), comment, review, gate ready, inbox lists it")

        // 6. Merge from the bottom through the real squash-merge restack.
        stack = await Stacks.load(in: work, host: host)[0]
        let merged = try await Stacks.mergeBottom(stack, in: work, host: host)
        XCTAssertEqual(merged, "farewell-function")
        let movedBase = try await GitHub.view(b, in: work).baseRefName
        XCTAssertEqual(movedBase, "main", "the next pull request must be retargeted to main")
        let r = try await Stacks.sync(in: work, host: host)
        say("after merging #\(a): sync -> \(r)")
        let after = await Stacks.load(in: work, host: host)
        let fresh = after.first { $0.branches.contains { !$0.isMerged } }!
        let before = try await git(["rev-list", "--count", "origin/main..farewell-test"], work)
        XCTAssertEqual(before, "1", "farewell-test should carry only its own commit after the restack, got \(before)")
        _ = try await Stacks.submit(fresh, in: work, host: host)
        let stack2 = await Stacks.load(in: work, host: host).first { $0.branches.contains { !$0.isMerged } }!
        let merged2 = try await Stacks.mergeBottom(stack2, in: work, host: host)
        XCTAssertEqual(merged2, "farewell-test")
        _ = try? await git(["fetch", "--prune", "origin"], work)
        let final = try await git(["ls-tree", "-r", "--name-only", "origin/main"], work)
        XCTAssertTrue(final.contains("src/goodbye.js") && final.contains("src/goodbye.test.js"), "both changes should be on main: \(final)")
        let states = try await gh(["pr", "list", "--state", "merged", "--json", "number", "--jq", "length"], work)
        say("merge from the bottom: both pull requests merged, main has both files; merged PR count \(states)")

        // 7. Tidy: close the issue.
        _ = try? await gh(["issue", "close", String(issueNumber), "--repo", slug, "--comment", "Closed by CPilot's live test."])
        say("done. Repository left in place: https://github.com/\(slug)")
    }

    /// The offline security scan, on this very repository.
    func testSecurityScanOnTheRealRepository() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_GITHUB_LIVE"] == "1", "live test")
        let dir = FileManager.default.currentDirectoryPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir + "/Package.swift"), "run from the repository root")
        try XCTSkipUnless(SecurityCage.locate(configured: nil) != nil, "no local SecurityCage checkout")
        let result = try await SecurityCage.scan(folder: dir) { _ in }
        say("security scan of this repository: \(result.confirmed.count) confirmed, \(result.leads.count) leads, report \(result.report.count) characters")
        XCTAssertFalse(result.report.isEmpty)
        // And it finds a real problem: a hardcoded live key in a throwaway project. The key is assembled here so that no key-shaped
        // text sits in the repository (and secret scanning stays quiet).
        let fakeKey = ["sk", "live", "51H8abcdefghijklmnopqrstuvwxyz" + "0123456789ABCDEF"].joined(separator: "_")
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: sample + "/src", withIntermediateDirectories: true)
        try "const express = require('express')\nconst KEY = \"\(fakeKey)\"\napp.get('/admin/users', (req, res) => res.json(db.users))\n".write(toFile: sample + "/src/server.js", atomically: true, encoding: .utf8)
        let found = try await SecurityCage.scan(folder: sample) { _ in }
        XCTAssertEqual(found.confirmed.count, 1, "the hardcoded key should be a blocking finding: \(found.findings.map(\.title))")
        XCTAssertTrue(found.blocksMerge)
        say("security scan of a sample with a hardcoded key: \(found.confirmed.map(\.title))")
    }
}

/// The deep scan with a local model (mlxplayer) and sandboxed proofs in Docker/Colima: no API key, nothing leaves the Mac.
final class LiveDeepScanTests: XCTestCase {
    func testDeepScanWithLocalModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CPILOT_DEEP_LIVE"] == "1", "opt in with CPILOT_DEEP_LIVE=1")
        try XCTSkipUnless(SecurityCage.locate(configured: nil) != nil, "no local SecurityCage checkout")
        let mode = await SecurityCage.chooseMode()
        FileHandle.standardError.write(Data("[live] mode: deep=\(mode.deep) — \(mode.note)\n".utf8))
        try XCTSkipUnless(mode.deep, mode.note)
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("deep-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: sample + "/src", withIntermediateDirectories: true)
        try """
        const express = require('express')
        const app = express()
        app.get('/users/:id', (req, res) => { res.json(db.query('select * from users where id = ' + req.params.id)) })
        app.listen(3000)
        """.write(toFile: sample + "/src/server.js", atomically: true, encoding: .utf8)
        try #"{"dependencies":{"express":"4.18.2"}}"#.write(toFile: sample + "/package.json", atomically: true, encoding: .utf8)
        let started = Date()
        let result = try await SecurityCage.scan(folder: sample, deep: true, environment: mode.environment) { line in FileHandle.standardError.write(Data("[scan] \(line)\n".utf8)) }
        FileHandle.standardError.write(Data("[live] deep scan took \(Int(Date().timeIntervalSince(started))) s: \(result.confirmed.count) confirmed, \(result.leads.count) leads: \(result.findings.map(\.title))\n".utf8))
        XCTAssertFalse(result.report.isEmpty)
    }
}

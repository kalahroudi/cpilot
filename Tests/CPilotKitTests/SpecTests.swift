// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class SpecTests: XCTestCase {
    let tasksText = """
    # Tasks: Cursor pagination
    - [x] T001 Cursor encoding helper (R1)
    - [ ] T002 Paginate the orders endpoint (R1, R2) needs: T001
    - [ ] T003 Keep offset clients working (R3) needs: T002 branch: spec-014-t003 pr: #223
    - [ ] T004 Update the API docs (R4)
    Some other line
    """

    func testParseTasks() {
        let t = Specs.parseTasks(tasksText)
        XCTAssertEqual(t.map(\.id), ["T001", "T002", "T003", "T004"])
        XCTAssertTrue(t[0].done); XCTAssertFalse(t[1].done)
        XCTAssertEqual(t[1].title, "Paginate the orders endpoint"); XCTAssertEqual(t[1].covers, ["R1", "R2"]); XCTAssertEqual(t[1].needs, ["T001"])
        XCTAssertEqual(t[2].branch, "spec-014-t003"); XCTAssertEqual(t[2].pr, 223); XCTAssertEqual(t[2].needs, ["T002"])
        XCTAssertTrue(t[3].needs.isEmpty && t[3].branch == nil)
    }

    func testUpdateTaskPreservesTheRestOfTheFile() {
        let out = Specs.updateTask(tasksText, id: "T002", done: true, branch: "spec-014-t002", pr: 222)
        XCTAssertTrue(out.contains("- [x] T002 Paginate the orders endpoint (R1, R2) needs: T001 branch: spec-014-t002 pr: #222"))
        XCTAssertTrue(out.contains("Some other line") && out.contains("- [ ] T004 Update the API docs (R4)"))
        XCTAssertEqual(Specs.parseTasks(out).first { $0.id == "T002" }?.pr, 222)
        // writing and re-reading is stable
        XCTAssertEqual(Specs.updateTask(out, id: "T002"), out)
    }

    func testReadyAndParentBranch() {
        let t = Specs.parseTasks(tasksText)
        XCTAssertEqual(Specs.ready(t).map(\.id), ["T002", "T004"])               // T003 already has a branch
        XCTAssertEqual(Specs.ready(t, merged: ["spec-014-t003"]).map(\.id), ["T002", "T004"])
        var s2 = t; s2[1].branch = "b2"                                                  // T002 started
        XCTAssertEqual(Specs.ready(s2).map(\.id), ["T004"])                               // T003 already has a branch, T002 is running
        XCTAssertEqual(Specs.ready(s2.map { var x = $0; if x.id == "T003" { x.branch = nil; x.pr = nil }; return x }, coded: ["b2"]).map(\.id), ["T003", "T004"])   // T002 has commits, so T003 can stack on it
        XCTAssertEqual(Specs.parentBranch(for: t[1], in: t, trunk: "main"), "main")    // T001 is done
        XCTAssertEqual(Specs.parentBranch(for: t[2], in: t, trunk: "main"), "main")    // T002 has no branch yet
        var u = t; u[1].branch = "spec-014-t002"
        XCTAssertEqual(Specs.parentBranch(for: u[2], in: u, trunk: "main"), "spec-014-t002")
        XCTAssertEqual(Specs.parentBranch(for: u[2], in: u, trunk: "main", merged: ["spec-014-t002"]), "main")
    }

    func testOpenQuestionsAndTitle() {
        let spec = "# Invite teammates\n> Source: Issue #9\n## Why\nx\n## Open questions\n- Should invites expire?\n- [ ] Who can revoke?\n## Assumptions\n- none"
        XCTAssertEqual(Specs.openQuestions(spec), ["Should invites expire?", "Who can revoke?"])
        XCTAssertEqual(Specs.title(of: spec), "Invite teammates"); XCTAssertEqual(Specs.sourceLine(of: spec), "Issue #9")
        XCTAssertTrue(Specs.openQuestions("# T\n## Open questions\n- none").isEmpty)
    }

    func testNumberingNamesAndStatus() {
        XCTAssertEqual(Specs.nextNumber(existing: ["001-a", "014-b", "x"]), 15)
        XCTAssertEqual(Specs.folderName(number: 7, title: "Cursor pagination for orders!"), "007-cursor-pagination-for-orders")
        var d = SpecDoc(id: "014-x", number: 14, title: "x", spec: nil, plan: nil, tasksText: nil)
        XCTAssertEqual(d.status(), .draft)
        d.spec = "# x"; XCTAssertEqual(d.status(), .draft)
        d.plan = "# p"; XCTAssertEqual(d.status(), .planned)
        d.tasksText = "- [ ] T001 a\n- [ ] T002 b needs: T001"; XCTAssertEqual(d.status(), .ready)
        d.tasksText = "- [ ] T001 a branch: b1\n- [ ] T002 b needs: T001"; XCTAssertEqual(d.status(started: ["b1"]), .inProgress)
        XCTAssertEqual(d.status(merged: ["b1"], started: ["b1"]), .inProgress)
        d.tasksText = "- [x] T001 a\n- [x] T002 b"; XCTAssertEqual(d.status(), .done)
        d.tasksText = "- [ ] T001 a branch: b1"; XCTAssertEqual(d.status(merged: ["b1"]), .done)
    }

    func testExtractDocument() {
        XCTAssertEqual(SpecPrompts.extractDocument("Sure, here it is:\n\n# Title\nbody"), "# Title\nbody\n")
        XCTAssertEqual(SpecPrompts.extractDocument("```markdown\n# T\n- [ ] T001 a\n```"), "# T\n- [ ] T001 a\n")
        let p = SpecPrompts.specify(requirement: "invite teammates", source: "Described by you", constitution: "Be small", assume: true)
        XCTAssertTrue(p.contains("Be small") && p.contains("Assumptions") && p.contains("invite teammates"))
        let rev = SpecPrompts.specify(requirement: "r", source: "s", constitution: nil, answers: "Q1: yes", previous: "# old")
        XCTAssertTrue(rev.contains("# old") && rev.contains("Q1: yes"))
        let ti = SpecPrompts.tasks(spec: "S", plan: "P", constitution: nil); XCTAssertTrue(ti.contains("- [ ] T001") && ti.contains("needs:"))
    }

    func testListAndWriteRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("specs-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try await Specs.write("\(Specs.folder)/001-first-thing/spec.md", "# First thing\n> Source: Issue #1\n## Why\nx", in: dir)
        try await Specs.write("\(Specs.folder)/001-first-thing/plan.md", "# Plan\nbody", in: dir)
        try await Specs.write("\(Specs.folder)/001-first-thing/tasks.md", "# Tasks\n- [ ] T001 do it (R1)", in: dir)
        try await Specs.write("\(Specs.folder)/constitution.md", "# Rules", in: dir)
        try await Specs.write("\(Specs.folder)/002-second/source.md", "> Source: Described by you\nmake it faster", in: dir)
        let (docs, constitution) = await Specs.list(in: dir)
        XCTAssertEqual(docs.map(\.id), ["001-first-thing", "002-second"])
        XCTAssertEqual(docs[0].title, "First thing"); XCTAssertEqual(docs[0].source, "Issue #1"); XCTAssertEqual(docs[0].tasks.count, 1)
        XCTAssertEqual(docs[0].status(), .ready)
        XCTAssertEqual(docs[1].status(), .draft); XCTAssertEqual(docs[1].source, "Described by you"); XCTAssertEqual(constitution, "# Rules")
    }

    func testRemoveDeletesOnlyThatSpec() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("specs-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try await Specs.write("\(Specs.folder)/001-a/source.md", "a", in: dir)
        try await Specs.write("\(Specs.folder)/002-b/source.md", "b", in: dir)
        try await Specs.remove("002-b", in: dir)
        let (docs, _) = await Specs.list(in: dir)
        XCTAssertEqual(docs.map(\.id), ["001-a"])
        do { try await Specs.remove("../x", in: dir); XCTFail("a path must be refused") } catch {}
    }

    func testUniqueBranchSkipsExistingOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("br-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let u = URL(fileURLWithPath: dir)
        for a in [["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"], ["branch", "session"], ["branch", "session-2"]] { _ = try await Shell.run("git", a, cwd: u) }
        let fresh = await Git.uniqueBranch("other", in: dir), taken = await Git.uniqueBranch("session", in: dir)
        XCTAssertEqual(fresh, "other"); XCTAssertEqual(taken, "session-3")
    }

    func testMergedWorkMatchesByIdOrBranch() {
        let t = SpecTask(id: "T001", title: "Pin favorites first in ChatListFilter.apply", done: false)
        XCTAssertTrue(Specs.isMergedWork(task: t, spec: "001-pin", head: "spec-001-t001", title: "x"))
        XCTAssertTrue(Specs.isMergedWork(task: t, spec: "001-pin", head: "pin-favs", title: "T001: Pin favorites"))
        XCTAssertFalse(Specs.isMergedWork(task: t, spec: "001-pin", head: "spec-002-t001", title: "x"))
        XCTAssertFalse(Specs.isMergedWork(task: t, spec: "001-pin", head: "other", title: "T0011 unrelated"))
    }
}

final class AuditHeadlineTests: XCTestCase {
    func testHeadlines() {
        func h(_ t: String, _ s: String) -> String { AuditEntry(session: "s", tool: t, summary: s, outcome: "allowed once").headline }
        XCTAssertEqual(h("Bash", "cd /tmp/x && FOO=1 git status --short | head"), "Ran git status")
        XCTAssertEqual(h("Bash", "/usr/bin/ssh -o X=1 host 'long script'"), "Ran ssh")
        XCTAssertEqual(h("Edit", "/a/b/Package.swift"), "Edited Package.swift")
    }
}

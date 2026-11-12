// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Which testers' turns are being looked at right now, so one turn is not handled twice.
@MainActor private enum TesterGuard { static var active = Set<String>() }

/// Tests first. For a task that needs it (Settings, Tests first), a tester session writes the tests from the spec before any code, CPilot checks that every requirement has one and that they
/// fail now, freezes them (see `TestLock`), and only then starts the implementer, who cannot change them. A test the implementer is sure is wrong is ruled on by the tester, from the spec.
extension SpecCenter {
    /// Times a tester is sent back to fix its tests before a person is asked.
    static let testerRunLimit = 6

    func testerHandler(_ id: String, _ taskId: String) -> (SessionController) -> Void {
        { [weak self] session in Task { @MainActor in await self?.testerTurnEnded(id, taskId, session) } }
    }

    func testFirstDecision(_ d: SpecDoc, _ task: SpecTask) -> (test: Bool, reasons: [String]) {
        TestFirst.decide(mode: TestFirst.Mode(rawValue: Prefs.shared.testFirst) ?? .off, task: task, criteria: Specs.criteria(spec: d.spec ?? "", covers: task.covers))
    }

    /// The repository's own list of rules that always hold, read from its checkout, never from a task's branch.
    func readInvariants(_ r: PRCenter.Repo) async -> [Invariant] {
        let text = (try? await Exec.with(env) { try await Shell.check("cat", [r.dir + "/.cpilot/invariants"], timeout: 15) }) ?? ""
        return Invariants.parse(text)
    }

    func lastAnswer(_ c: SessionController) -> String { c.items.last(where: { $0.kind == .assistant && $0.status == .done })?.text ?? "" }

    // MARK: Starting

    /// Puts a tester on the task when it needs one. True when the implementer must wait (a tester is working, or has just started); false when the task goes ahead as it is.
    func beginTesting(_ id: String, _ task: SpecTask, parent: String) async -> Bool {
        guard Prefs.shared.testFirst != "off", let r = repo, let d = doc(id) else { return false }
        let decision = testFirstDecision(d, task)
        guard decision.test else { return false }
        var rec = gateRecord(id, task.id) ?? GateRecord()
        if rec.locked != nil { return false }
        let skey = gateKey(id, task.id)
        if rec.held != nil { return true }
        if let t = rec.tester, let c = Workspace.shared.controller(t.session), c.meta.role == "tester" { return true }
        // A task whose branch already exists was started before tests-first was on: it goes on in its own session.
        let branch = Specs.taskBranch(spec: id, task: task)
        if await Exec.with(env, { await Git.branchExists(branch, in: r.dir) }) { return false }

        let criteria = Specs.criteria(spec: d.spec ?? "", covers: task.covers)
        let invariants = await readInvariants(r)
        let prompt = TestFirst.testerPrompt(task: task, criteria: criteria, invariants: invariants, constitution: constitution, hidden: Prefs.shared.hiddenTests)
        let temp = "tests-" + branch
        do {
            let c = try await Workspace.shared.startTask(repo: r.dir, environment: r.environment, branch: temp, parent: parent, title: "\(task.id) tests", prompt: prompt, focus: false,
                                                         model: Prefs.shared.testerModel, role: "tester", onTurnEnd: testerHandler(id, task.id))
            rec.tester = TesterState(session: c.id, branch: temp)
            Workspace.shared.gates.set(rec, for: skey)
            c.addNotice("CPilot: a tester writes the tests for \(task.id) first (\(decision.reasons.isEmpty ? "tests first is on" : decision.reasons.joined(separator: ", "))). The implementer starts when they are locked.")
            Workspace.shared.audit.record(AuditEntry(session: c.id, tool: "tester", summary: "\(task.id) \(task.title): tests first", outcome: "allowed by rule"))
        } catch {
            let message = AppModel.shared.capture(error, action: "Start the tester for \(task.id)")
            create(id) { $0.error = message; $0.stage = Self.implementStage + task.id }
        }
        return true
    }

    /// Tester sessions that were working before a restart: listen for their turns again, and look at the ones that had finished.
    func reattachTesters(_ id: String, _ d: SpecDoc) {
        for t in d.tasks where !t.done {
            guard let rec = gateRecord(id, t.id), let ts = rec.tester, let c = Workspace.shared.controller(ts.session) else { continue }
            c.onTurnEnd = testerHandler(id, t.id)
            if !c.isBusy { Task { @MainActor in await self.testerTurnEnded(id, t.id, c) } }
        }
    }

    // MARK: A tester's turn

    func testerTurnEnded(_ id: String, _ taskId: String, _ c: SessionController) async {
        let key = "\(gateKey(id, taskId))#tester"
        guard let d = doc(id), let task = d.tasks.first(where: { $0.id == taskId }), let rec0 = gateRecord(id, taskId), let ts = rec0.tester, ts.session == c.id, TesterGuard.active.insert(key).inserted else { return }
        defer { TesterGuard.active.remove(key) }
        var rec = rec0
        let answering = rec.answering
        rec.answering = false
        // The user spoke to the tester after it was held: count again from here.
        if rec.held != nil, !answering { rec.held = nil; rec.tester?.runs = 0 }
        if rec.held != nil { Workspace.shared.gates.set(rec, for: gateKey(id, taskId)); return }
        if case .failed = c.state { return }
        if ts.phase == "writing" { await firstTests(id, d, task, c, &rec) } else { await amendment(id, d, task, c, &rec) }
        Workspace.shared.gates.set(rec, for: gateKey(id, taskId))
    }

    private func sendBack(_ c: SessionController, _ task: SpecTask, _ rec: inout GateRecord, _ problems: [String], then: String) {
        var t = rec.tester!
        t.runs += 1
        rec.tester = t
        if t.runs > Self.testerRunLimit {
            let why = "The tester was sent back \(Self.testerRunLimit) times and its tests still do not pass the checks: \(problems.first ?? "")"
            rec.held = why
            c.addNotice("CPilot stopped checking the tests for \(task.id): \(why) It needs you.", error: true)
            AlertCenter.shared.alert(.failed, title: "Tests for a task need you", body: "\(task.id) \(task.title): \(why)", tag: "tester-\(task.id)", session: c.id, project: projectName)
            return
        }
        c.addNotice("CPilot checked the tests for \(task.id): \(problems.first ?? "needs attention") Sent back to the tester (try \(t.runs) of \(Self.testerRunLimit)).")
        rec.answering = true
        c.draft = "CPilot checked your tests and found problems:\n" + problems.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + then
        c.send()
    }

    /// The first tests: complete, only tests, and red. Then they are frozen and the implementer starts.
    private func firstTests(_ id: String, _ d: SpecDoc, _ task: SpecTask, _ c: SessionController, _ rec: inout GateRecord) async {
        guard let r = repo, let ts = rec.tester else { return }
        let url = c.meta.workingDirectory
        let parent = Specs.parentBranch(for: task, in: d.tasks, trunk: trunk, merged: merged)
        let last = lastAnswer(c)
        let seen = await Exec.with(c.env) { () -> (files: [String: String], dirty: Bool) in
            let f = (try? await TestLock.changedFiles(worktree: url, parent: parent)) ?? [:]
            let s = (try? await Shell.check("git", ["status", "--porcelain"], cwd: URL(fileURLWithPath: url), timeout: 30)) ?? ""
            return (f, !s.isEmpty)
        }
        // A tester that asked a question is waiting for the answer, not for a push.
        if seen.files.isEmpty, !seen.dirty, TaskNudge.asksQuestion(last) { return }
        let criteria = Specs.criteria(spec: d.spec ?? "", covers: task.covers)
        let invariants = await readInvariants(r)
        let trace = TestFirst.parseTrace(last)
        var problems = TestFirst.problems(required: TestFirst.requiredIds(criteria: criteria, invariants: invariants), trace: trace, files: seen.files)
        if seen.dirty { problems.append("Some of your changes are not committed. Commit the test files with the message \"\(task.id) tests: \(task.title)\".") }
        let finish = "Fix them, commit only test files, and end with the TRACE lines" + (Prefs.shared.hiddenTests ? " and the HIDDEN line" : "") + " again."
        guard problems.isEmpty else { sendBack(c, task, &rec, problems, then: finish); return }

        // Red: the tests must fail now, for a missing behavior. A test that passes with no code written checks nothing.
        var commands = task.verify.map { [$0] } ?? []
        if commands.isEmpty { commands = await TaskGateRunner.defaultCommands(repo: r.dir) }
        if commands.isEmpty {
            c.addNotice("CPilot: no verification command is set for this repository (.cpilot/verify), so it could not check that the tests fail before the code exists.", error: true)
        } else {
            let checks = await TaskGateRunner.runChecks(commands, in: c)
            switch TestFirst.red(checks) {
            case .green: sendBack(c, task, &rec, ["Your tests pass although the code does not exist yet, so they check nothing. Make each one fail until the behavior is built."], then: finish); return
            case .unclear(let why): sendBack(c, task, &rec, [why + " Fix the tests so they fail only because the behavior is missing."], then: finish); return
            case .red(let why): c.addNotice("CPilot ran the new tests: they fail as they should (\(why)).")
            }
        }

        do {
            let hidden = Prefs.shared.hiddenTests ? TestFirst.parseHidden(last) : []
            let locked = try await Exec.with(c.env) { try await TestLock.freeze(worktree: url, parent: parent, key: "\(id)-\(task.id)", hidden: hidden, trace: trace, message: "\(task.id) tests: \(task.title)") }
            let branch = Specs.taskBranch(spec: id, task: task)
            try await Exec.with(env) { _ = try await Shell.check("git", ["branch", branch, locked.commit], cwd: URL(fileURLWithPath: r.dir)) }
            await retireTester(c, repo: r.dir, branch: ts.branch)
            rec.locked = locked; rec.tester = nil; rec.answering = false
            Workspace.shared.gates.set(rec, for: gateKey(id, task.id))
            Workspace.shared.audit.record(AuditEntry(session: c.id, tool: "tester", summary: "\(task.id): \(locked.files.count) test file\(locked.files.count == 1 ? "" : "s") locked, \(locked.hiddenFiles.count) held back", outcome: "allowed by rule"))
            AppModel.shared.notify("Tests locked for \(task.id)", body: "\(locked.files.count) visible, \(locked.hiddenFiles.count) held back. The implementer starts now.", project: projectName)
            await implement(id, task)
        } catch TestLock.Failure.message(let m) {
            sendBack(c, task, &rec, [m], then: finish)
        } catch {
            let why = "The tests could not be frozen: \(error.localizedDescription)"
            rec.held = why
            c.addNotice(why, error: true)
            AlertCenter.shared.alert(.failed, title: "Tests for a task need you", body: "\(task.id) \(task.title): \(why)", tag: "tester-\(task.id)", session: c.id, project: projectName)
        }
    }

    /// Takes the tester's checkout and temporary branch away; what it wrote is already on the task's branch.
    func retireTester(_ c: SessionController, repo: String, branch: String) async {
        let wt = c.meta.worktree
        await Exec.with(c.env) {
            if let wt { await Git.removeWorktree(repo: repo, path: wt) }
            await Git.deleteBranch(repo: repo, branch: branch)
        }
        Workspace.shared.forget(c.id)
    }

    // MARK: A test the implementer disputes

    /// The implementer ended its turn with `TEST_DISPUTE:`. The tester decides, from the spec. After `disputeLimit` rulings a person decides. True when the gate should wait.
    func handleDispute(_ id: String, _ task: SpecTask, _ implementer: SessionController, _ rec: inout GateRecord) async -> Bool {
        guard var locked = rec.locked, rec.tester == nil, let r = repo, let d = doc(id), let dispute = TestFirst.parseDispute(lastAnswer(implementer)) else { return false }
        if locked.disputes >= TestFirst.disputeLimit {
            let payload = (try? JSONEncoder().encode(DisputePayload(spec: id, task: task.id, dir: r.dir, environment: r.environment))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Workspace.shared.proposals.add(Proposal(kind: "test_dispute", scope: RepoRef(dir: r.dir, environment: r.environment).key,
                what: "Should the implementer of \(task.id) be allowed to change a locked test?",
                why: "The implementer still says a test contradicts the spec after the tester ruled \(locked.disputes) times. Either the test is wrong and the work is stuck, or the code is wrong and unlocking would let a real bug through.",
                recommendation: "Read the objection and the spec lines under Evidence. If the test matches the spec, keep it locked.",
                ifApprove: "The tests are unlocked and the implementer may change them. The gate stops enforcing them.",
                ifDecline: "The tests stay locked and the implementer is told to make them pass.",
                evidence: [dispute], payload: payload))
            rec.held = "The implementer still disputes a locked test after \(locked.disputes) rulings. It is waiting for you."
            implementer.addNotice("CPilot: a person must decide whether this test may change. Waiting.", error: true)
            AlertCenter.shared.alert(.needs, title: "A locked test is disputed", body: "\(task.id) \(task.title): the implementer and the tester disagree.", tag: "dispute-\(task.id)", session: implementer.id, project: projectName)
            return true
        }
        locked.disputes += 1
        rec.locked = locked
        let taskBranch = Specs.taskBranch(spec: id, task: task), temp = "tests-\(taskBranch)-d\(locked.disputes)"
        let prompt = TestFirst.disputePrompt(task: task, dispute: dispute, criteria: Specs.criteria(spec: d.spec ?? "", covers: task.covers))
        do {
            let c = try await Workspace.shared.startTask(repo: r.dir, environment: r.environment, branch: temp, parent: taskBranch, title: "\(task.id) tests (ruling \(locked.disputes))", prompt: prompt, focus: false,
                                                         model: Prefs.shared.testerModel, role: "tester", onTurnEnd: testerHandler(id, task.id))
            rec.tester = TesterState(session: c.id, branch: temp, phase: "disputing", dispute: dispute)
            implementer.addNotice("CPilot: you disputed a locked test. The tester is ruling on it from the spec; you will be told.")
            Workspace.shared.audit.record(AuditEntry(session: c.id, tool: "tester", summary: "\(task.id): test disputed: \(dispute.prefix(120))", outcome: "allowed by rule"))
        } catch {
            rec.held = "The tester could not be started to rule on a disputed test: \(error.localizedDescription)"
            implementer.addNotice(rec.held ?? "", error: true)
        }
        return true
    }

    struct DisputePayload: Codable { var spec: String; var task: String; var dir: String; var environment: String? }

    /// A ruling (or a strengthening): the tester says what it did, and what it changed is brought into the implementer's branch and locked again.
    private func amendment(_ id: String, _ d: SpecDoc, _ task: SpecTask, _ c: SessionController, _ rec: inout GateRecord) async {
        guard let r = repo, var locked = rec.locked, let ts = rec.tester else { return }
        let last = lastAnswer(c), taskBranch = Specs.taskBranch(spec: id, task: task)
        let implementer = taskSessions["\(id)/\(task.id)"].flatMap { Workspace.shared.controller($0) }
        let ruling = ts.phase == "disputing" ? TestFirst.parseRuling(last) : .amended("the tests were strengthened")
        guard let ruling else { sendBack(c, task, &rec, ["Your message does not end with a ruling."], then: "End with `DISPUTE: UPHELD, because …` or `DISPUTE: AMENDED, because …`."); return }

        var message: String
        switch ruling {
        case .upheld(let why):
            message = "The tester looked at your objection and kept the test\(why.isEmpty ? "" : ": \(why)"). Make it pass; the tests stay locked."
        case .amended(let why):
            let url = c.meta.workingDirectory
            let changed = await Exec.with(c.env) { (try? await TestLock.changedFiles(worktree: url, parent: taskBranch)) ?? [:] }
            let notTests = changed.keys.filter { !DiffCheck.isTest($0) }
            if changed.isEmpty { sendBack(c, task, &rec, ["You ruled that the test was amended but no test file changed."], then: "Commit the amended tests, or rule UPHELD."); return }
            if !notTests.isEmpty { sendBack(c, task, &rec, ["Only test files may change; these are not tests: " + notTests.joined(separator: ", ")], then: "Fix and commit."); return }
            guard let implementer else { rec.held = "The implementer's session is gone, so the amended tests could not be brought in."; return }
            let iurl = implementer.meta.workingDirectory
            do {
                let files = try await Exec.with(implementer.env) { () -> [String: String] in
                    _ = try await Shell.check("git", ["merge", "--no-edit", ts.branch], cwd: URL(fileURLWithPath: iurl), timeout: 60)
                    var out: [String: String] = [:]
                    for p in Set(locked.files.keys).union(changed.keys.filter { !locked.hiddenFiles.contains($0) }) {
                        if let h = try? await Shell.check("git", ["rev-parse", "HEAD:\(p)"], cwd: URL(fileURLWithPath: iurl), timeout: 15) { out[p] = h.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    locked.commit = (try? await Shell.check("git", ["rev-parse", "HEAD"], cwd: URL(fileURLWithPath: iurl), timeout: 15))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? locked.commit
                    return out
                }
                locked.files = files
                rec.locked = locked
            } catch {
                rec.held = "The amended tests could not be merged into the implementer's branch: \(error.localizedDescription)"
                c.addNotice(rec.held ?? "", error: true)
                return
            }
            message = "The tester amended the tests\(why.isEmpty ? "" : ": \(why)"). They are merged into your branch and locked again. Read them and carry on."
        }
        await retireTester(c, repo: r.dir, branch: ts.branch)
        rec.tester = nil; rec.answering = false; rec.passedHead = nil
        Workspace.shared.audit.record(AuditEntry(session: c.id, tool: "tester", summary: "\(task.id): " + message.prefix(160), outcome: "allowed by rule"))
        if let implementer { implementer.addNotice("CPilot: " + message); implementer.draft = message; implementer.send() }
    }

    // MARK: A person decides

    /// A person approved unlocking: the tests become ordinary files the implementer may change.
    func releaseLock(_ id: String, _ taskId: String) async {
        guard var rec = gateRecord(id, taskId), let locked = rec.locked else { return }
        rec.locked = nil; rec.held = nil; rec.state = GateState(); rec.passedHead = nil
        Workspace.shared.gates.set(rec, for: gateKey(id, taskId))
        if let r = repo { await Exec.with(env) { await TestLock.dropHidden(repo: r.dir, locked) } }
        if let c = taskSessions["\(id)/\(taskId)"].flatMap({ Workspace.shared.controller($0) }) {
            c.addNotice("CPilot: a person unlocked the tests.")
            c.draft = "A person reviewed your objection and unlocked the tests. You may change them now. Keep every requirement of the spec covered, and commit."
            c.send()
        }
    }

    /// A person said the tests stay: the implementer is told to make them pass.
    func keepLock(_ id: String, _ taskId: String) {
        guard var rec = gateRecord(id, taskId) else { return }
        rec.held = nil; rec.state = GateState(); rec.passedHead = nil
        Workspace.shared.gates.set(rec, for: gateKey(id, taskId))
        if let c = taskSessions["\(id)/\(taskId)"].flatMap({ Workspace.shared.controller($0) }) {
            c.addNotice("CPilot: a person reviewed your objection. The tests stay locked.")
            c.draft = "A person reviewed your objection and the tests stay locked. Make them pass by changing the code, and commit."
            c.send()
        }
    }
}

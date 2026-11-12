// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// Runs the task gate for one spec task whose session just ended a turn: its verification commands and the checks on its diff, inside the task's
/// worktree. What fails goes back to the session as its next message; a task that will not pass is held for the user.
@MainActor
enum TaskGateRunner {
    enum Outcome: Equatable {
        /// Nothing to verify yet: the session has not changed anything.
        case clear
        /// Everything passed on this commit.
        case passed(head: String, summary: TaskSummary?)
        /// Failures were sent back; the session's next turn answers them.
        case sentBack
        /// The gate gave up. The reason is for the user.
        case held(String)
    }

    /// The commands a repository runs for every task that does not name its own, one per line in `.cpilot/verify` (blank lines and `#` comments are skipped).
    static func defaultCommands(repo: String) async -> [String] {
        let text = (try? await Shell.check("cat", [repo + "/.cpilot/verify"], timeout: 15)) ?? ""
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// What a repository protects: the built-in list and `.cpilot/protected`, one entry per line. Read from the repository's own checkout, never from the task's branch.
    static func protectedPaths(repo: String) async -> [String] {
        let text = (try? await Shell.check("cat", [repo + "/.cpilot/protected"], timeout: 15)) ?? ""
        return ScopeGuard.defaultProtected + text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Runs verification commands in a session's checkout, in order, and stops at the first that fails (what a later command prints after a failed build is only noise).
    static func runChecks(_ commands: [String], in c: SessionController) async -> [GateCheck] {
        let url = URL(fileURLWithPath: c.meta.workingDirectory)
        var checks: [GateCheck] = []
        for command in commands {
            let result = await Exec.with(c.env) { () -> GateCheck in
                do {
                    let r = try await Shell.run("bash", ["-lc", command], cwd: url, timeout: 900)
                    return GateCheck(command: command, ok: r.ok, output: r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
                } catch { return GateCheck(command: command, ok: false, output: "\(error.localizedDescription)") }
            }
            checks.append(result)
            if !result.ok { break }
        }
        return checks
    }

    /// `locked` is the task's tests written first by a tester: they must still be exactly as the tester wrote them, and the held-back ones are run once everything else passes.
    static func run(task: SpecTask, session c: SessionController, parent: String, repo: String, passedHead: String?, state: inout GateState,
                    locked: LockedTests? = nil, criteria: [Specs.Criterion] = []) async -> Outcome {
        let url = URL(fileURLWithPath: c.meta.workingDirectory)
        let inputs = await Exec.with(c.env) { () -> (diff: String, dirty: Bool, head: String, commands: [String]) in
            let head = (try? await Shell.check("git", ["rev-parse", "HEAD"], cwd: url, timeout: 15)) ?? ""
            let diff = (try? await Shell.check("git", ["diff", "\(parent)...HEAD"], cwd: url, timeout: 60)) ?? ""
            let status = (try? await Shell.check("git", ["status", "--porcelain"], cwd: url, timeout: 30)) ?? ""
            let own = task.verify.map { [$0] } ?? []
            return (String(diff.prefix(400_000)), !status.isEmpty, head, own.isEmpty ? await defaultCommands(repo: repo) : own)
        }
        // A session that has written nothing is thinking or asking, not done.
        if inputs.diff.isEmpty, !inputs.dirty { return .clear }
        // Passed on this very commit before (the app was restarted since): nothing has changed, so nothing to run again.
        if !inputs.head.isEmpty, inputs.head == passedHead, !inputs.dirty { return .passed(head: inputs.head, summary: nil) }

        let protected = await protectedPaths(repo: repo)
        var problems = DiffCheck.problems(diff: inputs.diff, touches: task.touches, protected: protected)
        if inputs.dirty { problems.append("Some of your changes are not committed. Commit them with the message \"\(task.id): \(task.title)\".") }
        // Locked tests are put back as the tester wrote them before anything runs, so the tests that run are always the tester's own.
        if let locked {
            let changed = await Exec.with(c.env) { await TestLock.verify(worktree: url.path, locked) }
            if !changed.isEmpty {
                await Exec.with(c.env) { await TestLock.restore(worktree: url.path, locked) }
                problems += changed.map { $0 + " CPilot put it back as the tester wrote it; commit it as it is." }
            }
        }

        var checks = await runChecks(inputs.commands, in: c)
        // Tests the tester held back run last, once everything else passes. A failure names the requirement, never the test.
        if let locked, locked.hiddenRef != nil, checks.allSatisfy(\.ok), problems.isEmpty {
            let hidden = await Exec.with(c.env) { await TestLock.runHidden(worktree: url.path, locked, commands: inputs.commands) { cmd in (await runChecks([cmd], in: c)).first ?? GateCheck(command: cmd, ok: false, output: "") } }
            if let p = hidden.problem { problems.append(p) }
            else if let bad = hidden.checks.first(where: { !$0.ok }) {
                checks.append(GateCheck(command: "checks CPilot holds back", ok: false, output: TestLock.hiddenFeedback(failedIds: TestLock.failedHiddenIds(output: bad.output, locked), criteria: criteria)))
            }
        }

        switch TaskGate.decide(&state, checks: checks, problems: problems) {
        case .pass:
            let flagged = ScopeGuard.flagged(diff: inputs.diff, touches: task.touches, protected: protected)
            if !flagged.isEmpty, state.flaggedHead != inputs.head {
                state.flaggedHead = inputs.head
                c.addNotice("\(task.id) changes protected files its spec names: \(flagged.prefix(5).map { "`\($0)`" }.joined(separator: ", ")). Look at them yourself before this merges.", error: true)
            }
            let summary = TaskSummarizer.summarize(diff: inputs.diff, head: inputs.head, touches: task.touches, protected: protected,
                                                   verified: checks.filter(\.ok).map(\.command), attempts: state.runs)
            return .passed(head: inputs.head, summary: summary)
        case .retry(let message):
            let what = checks.first { !$0.ok }.map { "`\($0.command)` failed" } ?? "the change needs attention"
            c.addNotice("CPilot checked \(task.id): \(what). Sent back to the agent (try \(state.runs) of \(TaskGate.runLimit)).")
            c.draft = message
            c.send()
            return .sentBack
        case .escalate(let why):
            c.addNotice("CPilot stopped checking \(task.id): \(why) It needs you. The work is kept as it is in this session.", error: true)
            return .held(why)
        }
    }
}

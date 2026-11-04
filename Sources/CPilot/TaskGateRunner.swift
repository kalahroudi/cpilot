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
        case passed(head: String)
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

    static func run(task: SpecTask, session c: SessionController, parent: String, repo: String, passedHead: String?, state: inout GateState) async -> Outcome {
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
        if !inputs.head.isEmpty, inputs.head == passedHead, !inputs.dirty { return .passed(head: inputs.head) }

        var problems = DiffCheck.problems(diff: inputs.diff, touches: task.touches)
        if inputs.dirty { problems.append("Some of your changes are not committed. Commit them with the message \"\(task.id): \(task.title)\".") }

        var checks: [GateCheck] = []
        for command in inputs.commands {
            let result = await Exec.with(c.env) { () -> GateCheck in
                do {
                    let r = try await Shell.run("bash", ["-lc", command], cwd: url, timeout: 900)
                    return GateCheck(command: command, ok: r.ok, output: r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
                } catch { return GateCheck(command: command, ok: false, output: "\(error.localizedDescription)") }
            }
            checks.append(result)
            if !result.ok { break }        // what a later command would print after a failed build is only noise
        }

        switch TaskGate.decide(&state, checks: checks, problems: problems) {
        case .pass:
            return .passed(head: inputs.head)
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

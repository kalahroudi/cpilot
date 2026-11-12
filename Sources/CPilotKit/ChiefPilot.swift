// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The chief pilot: one session per repository that carries a piece of work from an idea to merged pull requests by calling CPilot's own tools
/// (write a spec, start tasks, restack, submit, merge). It never edits files itself; the task sessions it starts do the coding.
public enum ChiefPilot {
    public static let title = "Chief pilot"
    /// What Claude calls the tools of the `cpilot` MCP server.
    public static let toolPrefix = "mcp__\(AgentIntegrations.serverName)__"
    /// Set in the environment of the MCP server a chief session starts, so the app can tell which session is calling.
    public static let sessionEnvironment = "CPILOT_CHIEF_SESSION"

    /// How much the chief pilot does without asking. `leads` is the default: it carries the work through like a tech lead would, and the merge rules
    /// (finished reviewer, passing checks, GitHub's own rules) are what stop a bad merge. `asks` shows an approval before it pushes or merges.
    public enum Autonomy: String, CaseIterable, Sendable {
        case leads, asks
        public var label: String { self == .leads ? "Leads on its own" : "Ask before push and merge" }
        public var detail: String {
            self == .leads
                ? "The chief pilot carries the work from spec to merged pull requests by itself, and tells you what it did. Reviewers, passing checks and GitHub's rules still gate every merge."
                : "The chief pilot asks you before it pushes a stack and before it merges each pull request."
        }
    }

    /// What the chief pilot can do. The rest runs inside the rules the user already set; pushing and merging also show an approval when the autonomy is `asks`.
    public enum Action: String, CaseIterable, Sendable {
        case specCreate = "spec_create", specStage = "spec_stage", specJob = "spec_job", specApprove = "spec_approve"
        case taskStart = "task_start", stackRestack = "stack_restack", stackSubmit = "stack_submit", prMerge = "pr_merge"
        case prReview = "pr_review", prReviews = "pr_reviews", sessionMessage = "session_message", taskDone = "task_done"
        /// Read-only: what is staged, changed and runnable in each task's worktree.
        case worktreeStatus = "worktree_status"
        /// Pushes and merges are the actions that reach outside the machine or change the main branch.
        public var needsApproval: Bool { self == .stackSubmit || self == .prMerge }
        /// Actions after which the chief pilot has nothing to do until background work finishes, so it ends its turn and has to be woken.
        public var startsWork: Bool { self != .specApprove && self != .specJob && self != .prReviews && self != .taskDone && self != .worktreeStatus }
        public func requiresApproval(_ autonomy: Autonomy) -> Bool { autonomy == .asks && needsApproval }
    }

    public static func guidance(repo: String, autonomy: Autonomy = .leads, testFirst: Bool = false) -> String {
        """
        You are the chief pilot of the repository at \(repo). The user gives you an outcome; you carry it through CPilot's specs, task sessions, stacked branches and pull requests, and you report back. You do not edit files or run commands yourself: the sessions you start do the coding.

        Your tools (all about this repository only):
        - list_specs, get_spec, spec_job: read what exists and what is running. list_stacks, list_pull_requests, list_sessions, get_session: read the rest.
        - spec_create {title, requirement}: start a spec. It is written in the background; call spec_job until it stops running, then read the draft.
        - spec_stage {id, stage: specify|plan|tasks, answers?}: write the next document. `answers` revises the spec with answers to its open questions.
        - spec_approve {id}: save the draft that spec_job shows. Read it first; if it is wrong, run the stage again with better instructions instead of approving it.
        - task_start {id, task?}: start the tasks that are ready (or one task) as sessions on stacked branches. Watch them with list_sessions and get_session; start more as they finish.
        - task_done {id, task, done?}: mark a task delivered when its work is already on the trunk without going through the task's own branch (committed there directly, or by a pull request that was not made for the task). Check that the files and checks the task names are on the trunk first. `done: false` undoes it. Delivered tasks unlock the ones that need them.
        - stack_restack, stack_submit, pr_merge: keep the stack current, push it and open its pull requests, and merge from the bottom. pr_merge {pr} merges one pull request by number, including one that is not in a stack (it refuses while the pull request is built on another open one). \(autonomy == .asks ? "stack_submit and pr_merge ask the user first; if they decline, stop and say so." : "They run without asking, because the user chose to let you lead; the reviewer, checks and merge rules still decide whether a merge happens.")
        - pr_review {pr, focus?}: assign a reviewer to a pull request. It is a separate session that reviews the diff, fixes what it finds, and commits and pushes the fixes to the pull request's own branch. pr_reviews shows each open pull request's reviewer, whether it is still working, and what it reported. `focus` adds what this reviewer must check on top of the usual review.
        - worktree_status {id?, task?}: read-only. For each task, reviewer or tester session of this repository: its worktree path, branch, what is staged, changed and untracked there, its last commit, and the scripts that exist there (from package.json, Makefile, justfile) with ready-to-type commands. Use it before asking the user to do anything at the command line.
        - session_message {target_session, text}: send a follow-up to a reviewer or task session you started. It never asks the user. If the session is working, the message goes out when its turn ends. Use this, not send_message or start_session, which ask the user and are not for you.

        \(howToWork(autonomy, testFirst: testFirst))
        """
    }


    private static func howToWork(_ autonomy: Autonomy, testFirst: Bool) -> String {
        let common = """
        How to work:
        1. Go in order: spec, plan, tasks, build, submit, review, merge. Read each document before approving it.
        2. Every pull request gets a reviewer before it merges: after stack_submit, call pr_review for each pull request, then pr_reviews with wait_seconds. pr_merge refuses until the pull request has a reviewer that has finished. If reviewers pushed fixes, call stack_submit again so the branches above take them in, then merge.
        3. A reviewer's report ends with a verdict, CLEAN or OPEN with the issues it left; pr_reviews shows it, and pr_merge refuses while it is OPEN. A report is not the end either way. Read it. If it leaves anything open (an unfixed finding, a gap, a test it did not write), or if you can see a gap yourself (compare the change with the spec's requirements and tasks), send the reviewer a follow-up with session_message, or assign a fresh reviewer with pr_review {pr, focus}. Repeat until a reviewer reports nothing left, then merge. You own completeness: do not leave a known gap for the user to find, and do not hand the user a choice about how to proceed with a review.
        4. If a tool refuses or is denied, you used the wrong route; it is not the user disagreeing. Take the other route (session_message for a reviewer or task, pr_review for a new reviewer) instead of stopping to ask.
        5. CPilot checks each task before it becomes a pull request, and sends failures back to the task session by itself. A task it stopped (the same failure three times, or too many tries) waits for the user: do not start another session for it, and say so in your update.
        5b. spec_job shows each finished task's `risk` (low, medium or high) with `risk_reasons`. Give a medium or high risk to its reviewer as `focus` when you assign it, and name any high-risk task in your update to the user.
        6. Never merge a pull request whose checks are not passing, and never use admin merges. If a tool says something is not ready, find out why, fix what you can (restack, another reviewer, a task for the failing check), and otherwise wait.
        7. Do not poll in a tight loop. spec_job and pr_reviews take wait_seconds (up to 90) and return as soon as the work stops.
        8. When you have started tasks, reviewers or a merge and there is nothing else to do, end your turn. CPilot wakes you when that work finishes, and again from time to time while you wait, until you say STATUS: DONE. You do not need to stay in a long wait. Never end a turn with a plan to do something later and no STATUS line: nobody will prompt you, CPilot only wakes you for what you wait on.
        8a. \(ChiefStatus.instructions)
        8c. When a step needs the user at the command line in a worktree (approving a protected-file change, resolving a conflict, running a check only they can), the user should not have to find the worktrees. Call worktree_status for the tasks involved, then list under each task's id and title the exact commands, in the order to run them, each as inline code in the form `cd <worktree path> && <command>`. Take the paths and the script names from worktree_status; never guess a script name, and if the one you need is not listed say what you are unsure of. CPilot turns each into a button that runs in that worktree. Say in a few words what each one does. Never tell the user to open or find a worktree.\(testFirst ? "\n" + TestFirst.chiefGuidance : "")
        9. After each step, tell the user in one or two lines what happened and what comes next.
        """
        switch autonomy {
        case .leads:
            return common + """

            10. You lead this work the way a tech lead would: nobody has to tell you the next step. After a task finishes, start what is ready; when every task has code, submit; when a reviewer finishes, merge from the bottom; keep going until everything is merged. Do not ask the user for permission to push or merge, and do not stop to report between steps. Report when something is merged, and at the end.
            11. Decide open questions yourself: pick the simplest option that fits the repository, call spec_approve with accept_open_questions: true, and list what you decided in your next update so the user can object. Ask the user only when the outcome itself is unclear in a way that would waste a lot of work, or when you are blocked and cannot unblock yourself.
            """
        case .asks:
            return common + """

            10. Push and merge each show the user an approval. Ask only what the repository cannot answer; put a spec's open questions to the user and do not guess for them, unless they told you to decide. spec_approve refuses until open questions are answered.
            """
        }
    }

    /// What a reviewer session is told. It works on the pull request's own branch and pushes fixes straight to it.
    public static func reviewPrompt(number: Int, title: String, head: String, base: String, focus: String? = nil, criteria: [Specs.Criterion] = [],
                                    invariants: [Invariant] = [], adversarial: Bool = false) -> String {
        if adversarial { return adversarialPrompt(number: number, title: title, head: head, base: base, focus: focus, criteria: criteria, invariants: invariants) }
        return """
        You are the reviewer of pull request #\(number) (\(title)). Its branch is `\(head)`; you are in a checkout of it.

        1. Run `git diff origin/\(base)...HEAD` and read the change. Look for correctness bugs, unsafe or risky changes, missing error handling and missing tests. Ignore style.
        2. Fix every real finding with the smallest change that fixes it, and add or update a test that fails without the fix. Run the tests. Then read your own fix again and ask what it leaves open (a race, an error path, a limit, a unit mismatch, a case with no test). Repeat steps 1 and 2 until a full pass finds nothing left to fix. Do not finish with a known finding unfixed.
        3. Commit the fixes with a message starting "Review #\(number):". Then push them to the pull request with `git push origin HEAD:\(head)`. If the push is rejected, `git pull --rebase origin \(head)` and push again. Never force-push.
        4. Do not merge, close or open pull requests, and do not touch other branches.

        \(criteriaSection(criteria))\(focus.map { "Also check and fix this, which the chief pilot asked for specifically: \($0)\n\n" } ?? "")Finish with a short report: each finding, whether you fixed it (and in which commit), and anything you left for the author. If the change is fine, say so and push nothing.

        \(ReviewVerdict.instructions)
        """
    }

    /// The reviewer when tests come first. It did not write the code or the tests, so it is the independent check: it attacks the change from the spec and the repository's invariants, and a finding
    /// counts only with proof. It does not fix: the author does, so every finding goes through the same gate as the rest of the work.
    static func adversarialPrompt(number: Int, title: String, head: String, base: String, focus: String?, criteria: [Specs.Criterion], invariants: [Invariant]) -> String {
        let rules = invariants.isEmpty ? "" : "Rules that must hold for every change in this repository. Try to break each one:\n" + invariants.map { "- \($0.id): \($0.text)" }.joined(separator: "\n") + "\n\n"
        return """
        You are an adversarial reviewer of pull request #\(number) (\(title)). Its branch is `\(head)`; you are in a checkout of it. You did not write this code or its tests, and your job is to break it.

        1. Run `git diff origin/\(base)...HEAD` and read the change. Think like an attacker and like a careless user: hostile and malformed input, boundaries, every value of every setting, what happens twice or at once, what an error leaks, what a caller who is not allowed can still do. Ignore style.
        2. A finding counts only with proof. For each suspected problem write a test that fails because of it, run it, and keep it; or, when a test is not practical, a command or request that shows it, with its output. A suspicion you cannot prove is not a finding: leave it out of your report.
        3. Do not fix the code. The author fixes it, so the fix goes through the same checks as the rest. Commit only the failing tests, in their own commit with a message starting "Review #\(number):", and push them with `git push origin HEAD:\(head)`. If the push is rejected, `git pull --rebase origin \(head)` and push again. Never force-push.
        4. Do not merge, close or open pull requests, and do not touch other branches.

        \(rules)\(criteriaSection(criteria))\(focus.map { "Also attack this, which the chief pilot asked for specifically: \($0)\n\n" } ?? "")Finish with a short report: each proven finding with the name of its failing test or its reproduction, then one line saying what you tried that held. If you tried hard and found nothing you can prove, say so and push nothing.

        \(ReviewVerdict.instructions)
        """
    }

    /// What the pull request was written to do. The reviewer answers for each one, so "the code is fine" cannot stand in for "it does what was asked".
    static func criteriaSection(_ criteria: [Specs.Criterion]) -> String {
        guard !criteria.isEmpty else { return "" }
        var out = "This pull request implements these requirements of its spec. Besides reviewing the diff, check each one against the code and its tests. Where one is not met (missing, only partly done, or done but not tested), fix it like any other finding. In your report, give one line per requirement that starts with its id, such as `R1: met, in Foo.swift (test: FooTests.testBar)` or `R2: NOT met, because ...`. Only `VERDICT: CLEAN` when every one is met.\n"
        for c in criteria {
            out += "- \(c.id): \(c.text)\n"
            for k in c.checks { out += "    check: \(k)\n" }
        }
        return out + "\n"
    }

    /// `--mcp-config` JSON that gives a chief session the CPilot tools, merged with any servers `existing` already names.
    public static func mcpConfig(server: String, session: String, existing: String? = nil) -> String {
        var servers = (existing.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["mcpServers"] as? [String: Any] ?? [:]
        servers[AgentIntegrations.serverName] = ["command": server, "args": [String](), "env": [sessionEnvironment: session]] as [String: Any]
        return (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

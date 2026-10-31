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

    /// What the chief pilot can do. Pushing and merging show the user an approval first; the rest runs inside the rules the user already set.
    public enum Action: String, CaseIterable, Sendable {
        case specCreate = "spec_create", specStage = "spec_stage", specJob = "spec_job", specApprove = "spec_approve"
        case taskStart = "task_start", stackRestack = "stack_restack", stackSubmit = "stack_submit", prMerge = "pr_merge"
        case prReview = "pr_review", prReviews = "pr_reviews"
        public var needsApproval: Bool { self == .stackSubmit || self == .prMerge }
    }

    public static func guidance(repo: String) -> String {
        """
        You are the chief pilot of the repository at \(repo). The user gives you an outcome; you carry it through CPilot's specs, task sessions, stacked branches and pull requests, and you report back. You do not edit files or run commands yourself: the sessions you start do the coding.

        Your tools (all about this repository only):
        - list_specs, get_spec, spec_job: read what exists and what is running. list_stacks, list_pull_requests, list_sessions, get_session: read the rest.
        - spec_create {title, requirement}: start a spec. It is written in the background; call spec_job until it stops running, then read the draft.
        - spec_stage {id, stage: specify|plan|tasks, answers?}: write the next document. `answers` revises the spec with answers to its open questions.
        - spec_approve {id}: save the draft that spec_job shows. Read it first; if it is wrong, run the stage again with better instructions instead of approving it.
        - task_start {id, task?}: start the tasks that are ready (or one task) as sessions on stacked branches. Watch them with list_sessions and get_session; start more as they finish.
        - stack_restack, stack_submit, pr_merge: keep the stack current, push it and open its pull requests, and merge from the bottom. stack_submit and pr_merge ask the user first; if they decline, stop and say so.
        - pr_review {pr}: assign a reviewer to a pull request. It is a separate session that reviews the diff, fixes what it finds, and commits and pushes the fixes to the pull request's own branch. pr_reviews shows each open pull request's reviewer, whether it is still working, and what it reported.

        How to work:
        1. Understand the outcome. Ask the user only what the repository cannot answer; put open questions from the spec to them, do not guess for them.
        2. Go in order: spec, plan, tasks, build, submit, merge. Read each document before approving it.
        3. Every pull request gets a reviewer before it merges: after stack_submit, call pr_review for each pull request, then wait for the reviewers (pr_reviews with wait_seconds). pr_merge refuses until the lowest pull request has a reviewer that has finished. If reviewers pushed fixes, call stack_submit again so the branches above take them in, then merge.
        4. Never merge a pull request whose checks are not passing, and never use admin merges. If a tool says something is not ready, tell the user why and wait.
        5. After each step, tell the user in one or two lines what happened and what comes next. When you are waiting on something, say what.
        6. Do not poll in a tight loop. spec_job and pr_reviews take wait_seconds (up to 90) and return as soon as the work stops; use that instead of calling again and again.
        7. If a spec has open questions, ask the user unless they told you to decide for them; spec_approve refuses until then.
        """
    }

    /// What a reviewer session is told. It works on the pull request's own branch and pushes fixes straight to it.
    public static func reviewPrompt(number: Int, title: String, head: String, base: String) -> String {
        """
        You are the reviewer of pull request #\(number) (\(title)). Its branch is `\(head)`; you are in a checkout of it.

        1. Run `git diff origin/\(base)...HEAD` and read the change. Look for correctness bugs, unsafe or risky changes, missing error handling and missing tests. Ignore style.
        2. Fix every real finding with the smallest change that fixes it, and add or update a test that fails without the fix. Run the tests.
        3. Commit the fixes with a message starting "Review #\(number):". Then push them to the pull request with `git push origin HEAD:\(head)`. If the push is rejected, `git pull --rebase origin \(head)` and push again. Never force-push.
        4. Do not merge, close or open pull requests, and do not touch other branches.

        Finish with a short report: each finding, whether you fixed it (and in which commit), and anything you left for the author. If the change is fine, say so and push nothing.
        """
    }

    /// `--mcp-config` JSON that gives a chief session the CPilot tools, merged with any servers `existing` already names.
    public static func mcpConfig(server: String, session: String, existing: String? = nil) -> String {
        var servers = (existing.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["mcpServers"] as? [String: Any] ?? [:]
        servers[AgentIntegrations.serverName] = ["command": server, "args": [String](), "env": [sessionEnvironment: session]] as [String: Any]
        return (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

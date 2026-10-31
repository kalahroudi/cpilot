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

        How to work:
        1. Understand the outcome. Ask the user only what the repository cannot answer; put open questions from the spec to them, do not guess for them.
        2. Go in order: spec, plan, tasks, build, submit, merge. Read each document before approving it.
        3. Never merge a pull request whose checks are not passing, and never use admin merges. If a tool says something is not ready, tell the user why and wait.
        4. After each step, tell the user in one or two lines what happened and what comes next. When you are waiting on something, say what.
        5. Do not poll in a tight loop. Check on running work when the user asks, or when you have nothing else to do.
        """
    }

    /// `--mcp-config` JSON that gives a chief session the CPilot tools, merged with any servers `existing` already names.
    public static func mcpConfig(server: String, session: String, existing: String? = nil) -> String {
        var servers = (existing.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["mcpServers"] as? [String: Any] ?? [:]
        servers[AgentIntegrations.serverName] = ["command": server, "args": [String](), "env": [sessionEnvironment: session]] as [String: Any]
        return (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

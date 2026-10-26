# Roadmap

Ideas we want to build, not promises. Newest first.

## Orchestration

Today you start sessions one at a time and watch them. These ideas make a whole fleet of agents something you steer, not babysit. They build on what is already here: worktrees, specs with tasks, stacks, approvals and the MCP server.

**Fleet board**

- **One board for every session in every repository**, grouped by what they need from you: working, waiting for approval, waiting for an answer, failed, ready to review, ready to merge. Bulk actions: approve the same safe request across sessions, stop all, resume all, archive finished.
- **A budget governor.** Set how many agents may run at once, a time and token budget per session and per day, and a quiet-hours rule. Extra sessions queue instead of starting, and a rate limit pauses the queue and resumes it by itself.

**Many agents on one problem**

- **Race.** Send one prompt to several agents or models, each in its own worktree, then compare their diffs, test results and cost side by side and keep one (or cherry-pick hunks from several).
- **Roles and pipelines.** A task can run as implement, then review, then fix, then verify, with a different agent or model for each step. A review that finds problems sends them back to the implementer automatically, up to a limit you set, then stops and asks you.
- **Parallel spec runs with limits.** Specs already start each task on its own branch. Add a concurrency cap, a dependency-aware scheduler that starts whatever is unblocked, retry with a different agent when a task fails, and a pause-and-redirect control on any running task.
- **Orchestrator sessions.** One session can start, watch, message and stop others through the built-in MCP server, within the same approval rules, so "split this into three parts and ship them as a stack" can run end to end.

**Keeping parallel work from colliding**

- **Conflict forecast.** Watch the files each live worktree changes and warn when two sessions are heading for the same lines, before either opens a pull request. Offer to serialize them or hand one a summary of what the other changed.
- **Ready-to-run worktrees.** A per-repository setup recipe runs in every new worktree: copy `.env` files, install dependencies, pick free ports, start the dev server. A session's preview opens in the app and is torn down with the worktree.
- **Shared context between sessions.** A session can read a sibling's plan and notes (read only), and a finished session leaves a short result others can pick up, so related sessions stop rediscovering the same things.

**Triggers and reach**

- **Start from events.** A labelled GitHub issue, a failing check on your pull request, a review comment, a schedule or a command from the CLI starts a session with the right context, subject to the same approvals.
- **A `cpilot` command line** to start, list, send to and wait on sessions from scripts and CI, mirroring the MCP tools.
- **Approve from your phone.** A push notification with the approval card, so a fleet does not stall while you are away from your desk. Approvals stay signed by your Mac, and Full access is never remote.
- **A cost and time ledger** per session, task, spec and agent, so you can see which agents and prompts earn their cost.

## Local CI

Run a branch's GitHub workflows on your own machine before pushing, from the pull request and session screens.

- **A "Run CI locally" card** listing the jobs in `.github/workflows` for the branch you are on, with each job's runner type.
- **Linux jobs** run through [act](https://github.com/nektos/act) on Colima, in a throwaway worktree so your working folder is untouched. CPilot points act at Colima's Docker socket (`~/.colima/default/docker.sock`) and streams the log live.
- **macOS jobs** (`runs-on: macos-*`) cannot run in a Linux container, so CPilot runs the job's `run:` steps natively in the same throwaway worktree. Steps that use a marketplace action other than checkout are skipped and listed.
- **Failures** offer "Fix it", which starts a session with the failing log.

Limits to design around:

- A local macOS run uses your Mac's Swift and Xcode, not the GitHub runner image, so a pass is a good sign and not a guarantee.
- Secrets and most `uses:` actions are not available locally.
- The result is informational. It does not replace GitHub's checks in the merge gate.

Already in place: `act` and Colima are installed on the maintainer's machine, and CPilot already has a place on the pull request screen for per-PR checks.

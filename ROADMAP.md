# Roadmap

Ideas we want to build, not promises. Newest first.

## Orchestration

Today you start sessions one at a time and watch them. These ideas make a whole fleet of agents something you steer, not babysit. They build on what is already here: worktrees, specs with tasks, stacks, approvals and the MCP server.

**Fleet board**

- **One board for every session in every repository**, grouped by what they need from you: working, waiting for approval, waiting for an answer, failed, ready to review, ready to merge. Bulk actions: stop all, resume all, archive finished. Approvals stay one at a time.
- **A concurrency cap.** Set how many agents may run at once. Extra sessions queue instead of starting, and a rate limit pauses the queue and resumes it by itself.

**Many agents on one problem**

- **Race.** Send one prompt to several agents or models, each in its own worktree, then compare their results in the existing diff view and keep one. The others are discarded with their worktrees.
- **Roles and pipelines.** A task can run as implement, then review, then fix, then verify, with a different agent or model for each step. A review that finds problems sends them back to the implementer automatically, up to a limit you set, then stops and asks you.
- **Parallel spec runs with limits.** Specs already start each task on its own branch. Add a concurrency cap, a dependency-aware scheduler that starts whatever is unblocked, retry with a different agent when a task fails, and a pause-and-redirect control on any running task.
- **Orchestrator sessions.** One session can start, watch, message and stop others through the built-in MCP server, within the same approval rules, a depth limit and a cap on children, so "split this into three parts and ship them as a stack" can run end to end.

**Keeping parallel work from colliding**

- **Conflict forecast.** At the end of each turn, compare the files each live worktree has changed (plain git, no file watching) and warn when two sessions are heading for the same lines, before either opens a pull request. Offer to serialize them or hand one a summary of what the other changed.
- **Ready-to-run worktrees.** A per-repository setup recipe runs in every new worktree: copy `.env` files, install dependencies, pick free ports, and optionally start a dev command that stops with the worktree.

**Triggers and reach**

- **Start from events.** A labelled GitHub issue, a failing check on your pull request, a review comment, a schedule or a command from the CLI starts a session with the right context, subject to the same approvals. GitHub events are found by polling through your own login while the app runs, so there is no webhook server or public address.
- **A `cpilot` command line** to start, list, send to and wait on sessions from scripts and CI, mirroring the MCP tools.
- **Control sessions from your phone.** A small page served by the Mac, off by default, reachable only over Tailscale (no cloud service, no account, nothing to install on the phone beyond adding the page to the Home Screen). Pair a device once with a QR code; each device gets its own revocable token.
  - Start new work any time: pick a known repository, an agent and model, and a prompt, or start from a GitHub issue or a spec task. Every phone-started session gets its own worktree and branch, so your working folder is never touched.
  - Watch sessions by state, read recent messages, send a message, stop one, and allow once or deny an approval card.
  - Guardrails: access is capped at Edit files and Full access still needs Touch ID at the Mac; there is no "always allow" from the phone; only repositories CPilot already knows can be used; new sessions from remote devices are rate limited; every remote action is logged with the device name and the Mac notifies you when one starts.
  - An optional notification (ntfy, which can be self-hosted) says only that a session needs you and links to the page, so no code leaves the Mac.
- **A cost and time ledger** per session, task, spec and agent, so you can see which agents and prompts earn their cost. It uses the usage figures agents already report; an agent that reports none shows time only.

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

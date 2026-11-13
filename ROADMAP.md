# Roadmap

Ideas we want to build, not promises. Newest first.

## Context Lens

See [docs/CONTEXT_LENS.md](docs/CONTEXT_LENS.md): usage tracing per session (context, cache hit rate, tool calls, cost), output gates, tool diet, cost-aware lessons, and before-and-after metrics.

## Orchestration

Today you start sessions one at a time and watch them. These ideas make a whole fleet of agents something you steer, not babysit. They build on what is already here: worktrees, specs with tasks, stacks, approvals and the MCP server.

**Fleet board**

- **One board for every session in every repository**, grouped by what they need from you: working, waiting for approval, waiting for an answer, failed, ready to review, ready to merge. Bulk actions: stop all, resume all, archive finished. Approvals stay one at a time.
- **A concurrency cap.** Set how many agents may run at once. Extra sessions queue instead of starting, and a rate limit pauses the queue and resumes it by itself.

**Many agents on one problem**

- **Race.** Send one prompt to several agents or models, each in its own worktree, then compare their results in the existing diff view and keep one. The others are discarded with their worktrees.
- **Roles and pipelines, the rest.** A task is verified by a deterministic gate and its pull request reviewed (by a model you choose) before it merges. Still to add: choosing a different agent, not just a model, for each step, and sending a review that finds problems back to the implementer's own session instead of fixing them in the reviewer. A review that finds problems sends them back to the implementer automatically, up to a limit you set, then stops and asks you.
- **Parallel spec runs, the rest.** Specs start each task on its own branch, and work that starts by itself respects a cap on agents and a daily budget. Still to add: retry with a different agent when a task fails, and a pause-and-redirect control on any running task.
- **Orchestrator sessions, for any session.** The chief pilot already runs a repository's specs, stacks and pull requests end to end. What is left is letting any session start, watch, message and stop others through the built-in MCP server, with a depth limit and a cap on children.

**Keeping parallel work from colliding**

- **Conflict forecast.** At the end of each turn, compare the files each live worktree has changed (plain git, no file watching) and warn when two sessions are heading for the same lines, before either opens a pull request. Offer to serialize them or hand one a summary of what the other changed.
- **Ready-to-run worktrees.** A per-repository setup recipe runs in every new worktree: copy `.env` files, install dependencies, pick free ports, and optionally start a dev command that stops with the worktree.

**Triggers and reach**

- **More triggers.** Schedules, labelled issues and failing checks are built (Settings, Triggers). Still to come: a review comment on your pull request, and starting a trigger from the command line or CI. GitHub events are found by polling through your own login while the app runs, so there is no webhook server or public address.
- **A `cpilot` command line** to start, list, send to and wait on sessions from scripts and CI, mirroring the MCP tools.
- **Phone control, what is left.** Phone control itself is built (Settings, Remote). Still to come:
  - A second way in: a Cloudflare tunnel with Cloudflare Access in front, for a phone that cannot run Tailscale. The server already listens on loopback only, so this is one more transport.
  - A passkey (Face ID) for approving pushes and merges, instead of only the per-device switch.
  - A last-known view of the board when the Mac is asleep or offline.
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

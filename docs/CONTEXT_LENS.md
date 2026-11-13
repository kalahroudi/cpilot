# Context Lens: plan

Goal: always know where a session's usage goes (context size, cache hit rate, tool calls, cost), then use what is learned to spend less, and show whether each change worked.

## Why: what the maintainer's own transcripts show

Measured from the 57 Claude Code transcripts of this repository (`~/.claude/projects/.../*.jsonl`, one `usage` block per assistant message, deduplicated by message id):

| Session | Calls | Cache read | Cache write | Peak context |
| --- | --- | --- | --- | --- |
| largest | 253 | 113.5M tokens | 0.8M | 859k |
| 2nd | 266 | 79.8M | 1.1M | 628k |
| 3rd | 195 | 47.7M | 0.5M | 484k |

Every call re-reads the whole conversation. 250 calls at a growing 300 to 800k context is where a Max limit goes, not the output (0.1 to 0.6M). Bash is 85 to 95% of tool calls. So the levers are, in order: keep the context small, keep the cache warm, make each tool return less.

## A. Context Lens (measure)

**Source of truth: the transcripts Claude Code already writes**, plus the stream CPilot already reads. No proxy, no new dependency, nothing leaves the Mac.

Open-source work reviewed, and what to take from each (none is Swift, so CPilot ports the definitions rather than embedding them):

| Project | Take |
| --- | --- |
| [context-analyzer](https://github.com/manavgup/context-analyzer) | cost per call versus context size; context growth and cache churn views |
| [claude-session-diagnostics](https://github.com/keziacousins/claude-session-diagnostics) | cache TTL, decay and miss detection, per-request trace |
| [claude-stat](https://github.com/waelmas/claude-stat) | cache-hit % definition: read / (read + creation + uncached input), billed tokens in the denominator |
| [claude-code-stats](https://github.com/AeternaLabsHQ/claude-code-stats) | idle-gap TTL overhead, cache invalidation anomalies |
| [claude-session-analyzer](https://github.com/yonk-labs/claude-session-analyzer) | per-skill and per-prompt cost attribution |
| [LangWatch / Claude Code OpenTelemetry](https://langwatch.ai/claude-code-usage) | later option: Claude Code's native OTel export for sessions CPilot did not start |

Build, in `CPilotKit` (pure, tested) with a small view in the app:

1. **`UsageLedger`**: parses transcript lines into rows: session, message id, model, time, input, cache read, cache write (5m and 1h), output, context size (input + reads + writes), tool names, tool result size. Dedupes streamed duplicates. Stored in its own SQLite file (`usage.db`, next to the memory index, which is rebuilt on its own schedule); incremental by file offset, so a launch reads only what is new.
2. **Per session, live**: context used and a bar toward the window, cache hit %, calls, tokens per turn, a cost estimate from the model's price, and the biggest tool results (what to blame). Shown in the session header and a Lens pane.
3. **Alerts that act**: context above a threshold (default 200k), cache hit below 80% after a gap, idle gap longer than the cache TTL (the next call pays a full rewrite), one tool result above N tokens. Each offers the fix: compact, fork with a digest, or end the session.
4. **Fleet view**: day, week and month by repository, session, model, and by who started it (you, chief pilot, trigger, reviewer). This is the roadmap's "cost and time ledger", now with real tokens.
5. **Limit forecast**: usage so far against the plan's window, using the reset time `UsageLimit` already reads.
6. **MCP**: `usage_report` (read-only) so the chief pilot and agents can see cost per task and stop spending on a stuck one.

## B. Learn and reduce (act)

Ranked by expected effect on the numbers above. Each item ships behind a setting and is measured (see C).

1. **Keep context small** (largest lever).
   - Auto-fork at a threshold: a fresh session seeded by `ContextDigest` plus recalled notes, instead of carrying 600k forward. CPilot already forks; add the trigger and a one-click "continue lean".
   - Use Claude Code's own compaction and context editing (clearing stale tool results) where the CLI exposes it ([context management](https://www.anthropic.com/research/components-of-agent-memory)); otherwise do it by forking.
   - Sub-agents for exploration so the file dumps never enter the main context.
2. **Gate tool output at the CLI** (second lever; Bash is nearly every call).
   - A `PreToolUse` hook, installed per session by CPilot, that routes Bash through an output filter: test runners, `git`, build, `ls`, logs reduced to failures, counts and the first and last lines, with the raw output saved to a file the agent can read on demand. Fails open to raw output. [RTK](https://github.com/rtk-ai/rtk) does this in Rust (claimed 60 to 90%, estimated by characters); evaluate it first, adopt it if it measures well on our own transcripts, and write our own gates only for what it misses (SwiftPM, xcodebuild).
   - Hard cap on any single tool result (head, tail, pointer to the saved full file), recorded in the Lens as "bytes withheld".
   - JSON returns: project to the fields asked for (`gh --json`, `jq` filters) instead of whole payloads.
3. **Typed tools, code mode, search** for CPilot's own MCP server and any MCP a session loads ([advanced tool use](https://www.anthropic.com/engineering/advanced-tool-use)).
   - Tool search: load tool definitions on demand instead of all up front (definitions can cost 50k+ tokens before the first message). Measure the definition tokens per session first; only act if it is large.
   - Code mode: a `search` and an `execute` tool pair so many small calls become one script whose intermediate data never reaches the model. Start with the chief pilot's status and worktree calls, where many small reads are common.
   - Typed results: small, fixed-shape returns (`{ok, failed, first_failure}`) rather than prose.
4. **Cache discipline.**
   - Keep the stable prefix stable: CLAUDE.md, memory notes and tool list in a fixed order; never put timestamps or recalled notes ahead of the conversation.
   - Warn before an idle gap longer than the cache TTL; for scheduled messages, offer to send a short keepalive only when cheaper than a rewrite (the Lens computes both).
   - Do not switch models mid-session without showing that it restarts the cache.
5. **Lighter reading of the web and large files.**
   - Pages: a Markdown-extracting reader instead of a full browser snapshot. Candidates, each with vendor-reported savings that must be verified on our pages: [browser39](https://docs.rs/crate/browser39/1.6.3) (single binary, page to Markdown), [agent-browser](https://glama.ai/mcp/servers/TrueNix/agent-browser) (drives the Chrome already installed), [Lightpanda](https://themenonlab.blog/blog/lightpanda-headless-browser-ai-agents) (Zig engine, JS support still partial). Run the same 10 pages through each and the current approach, compare tokens and fidelity, then pick one.
   - Files: read by range and by symbol; a hook that rejects whole-file reads above a size and says how to read a range.
6. **Learn from the ledger.** The existing lessons and dreams learn from review outcomes. Add a third input, cost: after a run, the lesson prompt also sees the costliest calls ("ran the full test suite 9 times", "read a 4000 line file whole") and may write a note such as "run only the changed package's tests". Same rules as every automated write (quotes must be real, no instructions to the agent, checks, undo). Cost-driven notes carry the evidence (session, call) and are pruned if the metric they target does not move.
7. **Sleep-time work, not live work.** Consolidation (dreams, lessons, index) runs after sessions end on the small model, as [Letta's sleep-time compute](https://www.letta.com/blog/agent-memory) and Anthropic's dreaming describe, never inside a working session's context.

Not doing: a proxy between Claude Code and the API (fragile, and the transcripts already hold the numbers); sending any usage data off the Mac.

## C. Metrics: proving it works

Every change is compared on the same measures, per repository, before and after, with the setting's on and off dates recorded in the ledger so an effect can be attributed.

- Tokens per completed task (a task = one spec task or one chief pilot run), and per merged pull request.
- Median and p95 context size at each call; peak context.
- Cache hit %, and cache-write tokens per session.
- Cost estimate per task and per day; share of the plan window used.
- Tool results: tokens per call, bytes withheld by gates, count of over-limit results.
- Quality guard so savings are not bought with failures: task gate pass rate, retries per task, reviewer open findings. A saving that raises retries is shown as a loss.

A "Did it help?" card per setting compares sessions of 20 or more calls that started before it took effect with those after (median peak context, share above 200k, cost per session, cache hit), and says "not enough data" under 10 sessions a side rather than a percentage. Built for the compaction setting; not yet compared: retries and gate failures (the quality guard), tokens per merged pull request.

## Phases

| Phase | Ships | Done when |
| --- | --- | --- |
| 1 Ledger | `UsageLedger`, importer for existing transcripts, per-session numbers in the header, Lens pane, tests on real transcript fixtures (streamed duplicates, subagents, 1h cache writes) | Numbers match a hand count on 3 transcripts; a 50MB history imports in seconds and incrementally |
| 2 Alerts and fork | context and idle alerts, auto-fork with digest, fleet view, `usage_report` MCP | An 800k session would have been flagged at 200k |
| 3 Gates (revised, see Measured) | a small own hook for fetch/pull/push/`gh run` noise; measure repeated reads and wide ranges before touching reading; RTK, result cap and JSON projection dropped unless the Lens shows a heavy source they fit | The Lens shows tool-result tokens per source falling, with no rise in retries |
| 4 Tool diet (demoted, see Measured) | measure tool definition tokens; tool search and code mode for CPilot's MCP; browser bake-off | Each adopted only if it beats the measured baseline |
| 5 Learning | cost input to lessons, before and after cards, pruning of notes that did not help | A cost lesson is shown with its effect, or removed |

Phase 1 is the first thing to build: nothing else can be judged without it.

**Status.** Phase 1 is built: ledger, importer, header numbers and the Lens pane. Checked on this Mac's real transcripts: for the largest session the ledger and an independent count agree exactly (3,140 calls, 1,385,462k cache read, 966k peak). The import of 1.2 GB took 22 s in a debug build; a first launch now reads only the last 90 days, newest first, and a second read of unchanged files takes 0.03 s. 
Phase 2 is built except two items: alerts (context over 200k, an idle gap that let the cache expire, low cache hit, a huge tool result) with a **Continue lean** fork from a summary, the split by who started the work, and the `usage_report` MCP tool. Still open from phase 2: the cost-per-context-size chart and the limit forecast against the plan window (the reset time is known, the plan's allowance is not exposed, so this needs a decision on what to compare against).

## Measured on this Mac (30 days of transcripts), and what it changed

- **Tool results are 18.4M tokens, 14M of them from Bash.** But they are not what the plan assumed. The largest Bash group is `sed -n` (3.6M tokens, 2,845 calls: the agent reading file ranges) and `grep -n` (1.5M), then `python3 -` (0.7M), `git diff` (0.6M), `git fetch` (0.3M of pure progress noise), `gh run`, `git status`, `git log` (about 0.15M each). Test runners and builds, the home ground of output filters like [RTK](https://github.com/rtk-ai/rtk), are not among the top. **No single result was above 15k tokens**, so a result cap would never have fired.
- **Consequence for phase 3.** A command-output filter could trim roughly 1.2M of the 18M tokens (the git, `gh` and fetch family), a few percent, and its published 60 to 90% does not apply to a workload that is mostly code reading. Phase 3 is therefore not worth a tool that rewrites every Bash call. What it keeps: drop `git fetch`/`pull`/`push` progress and `gh run` noise with a small hook of our own (no third-party binary), and nothing else until the Lens shows a new heavy source. The larger lever is unchanged: the multiplier. A result of 1.3k tokens read on each of the 200 calls after it is 260k tokens; the Lens's context alerts and Continue lean act on that.
- **Every cache write is the one-hour kind** (95M tokens one-hour, none five-minute), and a pause of 5 to 60 minutes was cold only 20 times out of 1,239. The first version of the Lens assumed a five-minute cache and over-counted cold starts (178 in the largest session, 36 once the real lifetime is used). It now reads each session's cache lifetime from what it wrote. Pauses beyond an hour are still cold (11 of 184), and those are what the idle alert is for.
- **Context size is the lever.** 89 of 766 sessions peaked above 200k tokens (14 above 500k), yet calls made above 200k are **65% of all context tokens processed**. Replaying every real call sequence with a reset to a 40k context whenever 200k is reached (an optimistic simulation: it ignores what a summary loses) gives **48% fewer context tokens**. This is why phase 2 (alerts, Continue lean) came first, and why unattended sessions now carry `--autocompact 200k` (Settings, Limits; the chief pilot, tasks and reviewers; your own sessions stay on Claude's default unless you choose). The flag is accepted by Claude Code 2.1.311 in CPilot's headless mode; that it compacts at the chosen size has not been checked on a live 200k conversation, and Claude Code issues report the percentage override misbehaving on 1M windows, so the Lens is where to confirm it: peak context of new unattended sessions should stop passing the setting.
- **Tool definitions are not the problem.** The first call of a session carries about 30k tokens (p50; p10 25k, p90 48k) including the system prompt, CLAUDE.md and the tool list, and MCP tool definitions are already deferred by Claude Code. A tool-search or code-mode build for CPilot's own MCP would save little against a 400k average growth; phase 4's tool diet is demoted to "measure again when the first-call context passes 60k".
- **Reading, measured.** File reads (the Read tool and `sed -n` ranges) are 6,854 calls and 8.3M tokens. **16% of those tokens (1.37M) are the exact same file and range read again in the same session**, and 192 reads over 5k tokens account for another 1.3M. Each repeat also stays in the context for every later call. The candidate is a hook that answers a repeat with "unchanged since you read it at message N" when the file's modification time has not moved, and says so when it has; it needs care (an edit in between must always show the new text), so it waits until the Lens can show repeats per session and confirm the number holds on new sessions.
- **Reading, as first listed.** 2,845 `sed -n` calls and 2,000 `grep -n` calls average 1.3k and 0.7k tokens. Whether those are wasteful (re-reading the same file, wide ranges) is the next thing to measure before changing anything: the ledger will record the command and range for reads, so repeats can be counted.

## Phase 6: security checks and bug hunts on key codebases

A coding session reads a handful of files (median 5). An audit reads everything, across providers (subscription CLIs and API), so what matters changes: the cost is files times calls, and the code is the asset. Levers, in the order they pay, with their state:

1. **Never pay twice for the same question (built, step one).** A scan ledger keyed by repository, file, git content hash, prompt version and model. A re-audit sends only files whose hash changed or are new; a new prompt version or a different model starts afresh, because the answer would differ. File hashes come from `git ls-tree` (no file is read to find out). Out of scope by default: generated, vendored, binary, minified and lock files. Not yet handled: files whose findings depend on a changed neighbour (callers of a changed function), which needs the symbol index below.
2. **Riskiest first, inside a budget (built).** A path-based risk rank (authentication, sessions, crypto, parsing, SQL and shell, uploads, webhooks, payments, admin) orders the work, tests and docs last, so a capped run spends on what matters. A heuristic only: it never decides a file is safe.
3. **Cheap triage, strong confirmation (to build).** Static tools first (CodeQL, Semgrep, a secret scanner, language linters) to find candidates; a small model classifies each candidate; the strong model sees only the survivors, with the surrounding function and its callers, and must produce a failing test or a reproduction (CPilot's adversarial reviewer already works this way). Structured output (a JSON schema) caps what comes back.
4. **Cache the stable prefix (to build).** On the API, one cached prefix (rubric, threat model, repository map) followed by each file's content means the many per-file calls pay a tenth for the shared part; cache writes of an hour suit a run of that length. In Claude Code the transcripts show it already holds (98% from cache), so the work there is keeping the prefix identical across files.
5. **Batch for anything not waiting on you (to build).** The Messages Batches API is half price and stacks with caching; right for nightly or weekly audits, wrong for interactive hunting.
6. **Symbol-level context instead of whole files (to build).** Only the function under test and what it calls and is called by, found from a local symbol index (tree-sitter or the language server) with a ranked repository map for orientation. Cross-session repeats are small (14% of reads), so an index earns its place here, in breadth, not in everyday coding.
7. **Provider routing and measurement (to build).** The Lens reads Claude Code transcripts only. Each provider's usage (Codex, Gemini and others through the agent protocol, or the API's own usage field) needs the same ledger rows, so cost per finding can be compared across providers and models, not just tokens.
8. **What is allowed to leave the machine (to build, matters most for key code).** A per-repository list of allowed providers; secrets and environment files never sent (a secret scan before any send, which the Lens's sensitive-file warning only reports after the fact); a manifest of exactly which files, at which hashes, went to which provider and when; and a note of each provider's retention terms on the repository, since some models are not available under zero data retention.
9. **Stop rules.** A token and dollar budget per run, a cap on calls per file, and a stop when a pass finds nothing new in N files, using the same task budget the gate already has.

What exists today toward this: the read-once guard, the scan ledger above, and a guard that refuses reads of secret-holding files (`.env`, private keys, `.npmrc`, credentials, certificates) before they are sent, tested against a real Claude Code run. It covers plain reads only (Read, cat, sed, head, tail): a program that prints a secret, or a search that matches one, is not stopped, and the other providers (Codex, Gemini and so on) are not covered at all yet, since the hook is Claude Code\'s. A pre-send secret scan of file contents, the per-repository provider list and the manifest are still to build.

## Risks and open questions

- Transcript format is Claude Code's, not a contract: parse defensively, keep fixtures, show "unknown" rather than a wrong number. Streamed messages repeat usage, so dedupe by message id (counting the last, not the first).
- Cost is an estimate: Max is not billed per token, so the Lens shows tokens and a price-equivalent, and the plan window as a share when the CLI reports it.
- Output gates can hide what the agent needs. Fail open, keep the raw output on disk, and measure retries.
- Secrets can appear in transcripts and tool output; the ledger stores sizes and names, not content, except an opt-in preview kept local.
- Vendor savings figures in the sources above are unverified; each is treated as a hypothesis until measured on this repository's own history.

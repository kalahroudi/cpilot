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

1. **`UsageLedger`**: parses transcript lines into rows: session, message id, model, time, input, cache read, cache write (5m and 1h), output, context size (input + reads + writes), tool names, tool result size. Dedupes streamed duplicates. Stored in the existing SQLite index; incremental by file offset, so a launch reads only what is new.
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

A "Before and after" card per setting shows these with the dates it was turned on, and says "not enough data" under 10 tasks rather than a percentage.

## Phases

| Phase | Ships | Done when |
| --- | --- | --- |
| 1 Ledger | `UsageLedger`, importer for existing transcripts, per-session numbers in the header, Lens pane, tests on real transcript fixtures (streamed duplicates, subagents, 1h cache writes) | Numbers match a hand count on 3 transcripts; a 50MB history imports in seconds and incrementally |
| 2 Alerts and fork | context and idle alerts, auto-fork with digest, fleet view, `usage_report` MCP | An 800k session would have been flagged at 200k |
| 3 Gates | evaluate RTK on recorded Bash output (replay, no live risk); hook install; result cap with saved raw output; JSON projection | Replay shows at least 50% fewer tool-result tokens with no failing-test information lost |
| 4 Tool diet | measure tool definition tokens; tool search and code mode for CPilot's MCP; browser bake-off | Each adopted only if it beats the measured baseline |
| 5 Learning | cost input to lessons, before and after cards, pruning of notes that did not help | A cost lesson is shown with its effect, or removed |

Phase 1 is the first thing to build: nothing else can be judged without it.

## Risks and open questions

- Transcript format is Claude Code's, not a contract: parse defensively, keep fixtures, show "unknown" rather than a wrong number. Streamed messages repeat usage, so dedupe by message id (counting the last, not the first).
- Cost is an estimate: Max is not billed per token, so the Lens shows tokens and a price-equivalent, and the plan window as a share when the CLI reports it.
- Output gates can hide what the agent needs. Fail open, keep the raw output on disk, and measure retries.
- Secrets can appear in transcripts and tool output; the ledger stores sizes and names, not content, except an opt-in preview kept local.
- Vendor savings figures in the sources above are unverified; each is treated as a hypothesis until measured on this repository's own history.

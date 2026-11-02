---
name: cpilot
description: Use on macOS to hand work to the user's CPilot app, read what their sessions did, look up their saved project notes, or list pull requests. Uses CPilot through its MCP tools. Also covers installing CPilot.
---

# CPilot

CPilot is a menu bar app that runs AI coding sessions for the user, with notes it keeps per project. Use its tools to see what specs and stacked branches a repository has, to see what sessions exist and what they said, to save a note future sessions should start with, and to start a session the user approves. Prefer these over guessing what the user has been working on.

## Before you act

1. Call `get_status`. If `appRunning` is false, tools that start or message sessions will fail; ask the user to open CPilot.
2. Look before you write: `list_sessions`, then `get_session` for the one that matters, and `search_memory` for notes on the project.

## Changing things

- `start_session` and `send_message` show an approval dialog to the user in CPilot. Say what you are about to ask for first. If the answer is "The user declined", respect it and do not retry.
- You cannot request Full access. Ask for `readOnly`, `askFirst` or `editFiles`.
- `save_memory` writes a note every later session starts with. Save short, durable facts, not transcripts.
- Never call `delete_session` without asking the user, and pass the session's exact title as `confirm_title`.

## Tool reference

| MCP tool | Changes the system |
|---|---|
| `get_status {}` | no |
| `list_sessions {limit?}` | no |
| `get_session {session_id, tail?}` | no |
| `search_memory {query}` | no |
| `list_pull_requests {folder}` | no |
| `list_specs {folder}` | no |
| `get_spec {folder, id, part?}` | no |
| `list_stacks {folder}` | no |
| `save_memory {name, body, project_folder?}` | yes, a note |
| `start_session {folder, message?, access?}` | yes, user approves in the app |
| `send_message {session_id, text}` | yes, user approves in the app |
| `delete_session {session_id, confirm_title}` | yes, ask the user first |

## The chief pilot

Inside a CPilot chief pilot session (opened from the Specs pane) these extra tools drive the repository: `spec_create`, `spec_stage`, `spec_job`, `spec_approve`, `task_start`, `pr_review`, `pr_reviews`, `stack_restack`, `stack_submit` and `pr_merge`. Everywhere else they answer that they are only available there. `stack_submit` and `pr_merge` ask the user in the app; never retry after a decline.

## Installing CPilot (ask the user first)

Only install when `/Applications/CPilot.app` does not exist.

1. `curl -fsSL https://raw.githubusercontent.com/kalahroudi/cpilot/main/scripts/install.sh | bash`
2. The app opens and its first-run setup installs whatever it needs. Ask the user to click through it if it is waiting.
3. Register the MCP server: `claude mcp add cpilot --scope user -- /Applications/CPilot.app/Contents/MacOS/cpilot-mcp`
4. Call `get_status` and report what it says.

---
name: cpilot
description: Use on macOS when <the situation where an agent should reach for CPilot>. Uses the CPilot menu bar app through its MCP tools. Also covers installing CPilot.
---

# CPilot

One paragraph: what CPilot shows or does, and why an agent should use it instead of guessing.

## Before you <do the risky thing>

1. Check first with the read-only tool: `get_status`.
2. Decide using the fields it returns, not assumptions.
3. After any change, verify with the same read-only tool.

## Changing things

- Say what you are about to do, then wait for the result. If a call returns "The user denied this request", respect it and do not retry.
- Never call destructive tools (`delete_thing`) without asking the user first, and pass the exact confirmation argument.

## Tool reference

| MCP tool | Changes the system |
|---|---|
| `get_status {}` | no |
| `delete_thing {name, confirm_name}` | yes, ask the user first |

## Installing CPilot (ask the user first)

Only install when `/Applications/CPilot.app` does not exist.

1. `curl -fsSL https://raw.githubusercontent.com/kalahroudi/cpilot/main/scripts/install.sh | bash`
2. The app opens and its first-run setup installs whatever it needs. Ask the user to click through it if it is waiting.
3. Register the MCP server: `claude mcp add cpilot --scope user -- /Applications/CPilot.app/Contents/MacOS/cpilot-mcp`
4. Call `get_status` and report what it says.

## Install with an AI agent

Paste this into an AI coding agent such as Claude Code. CPilot detects and installs its own prerequisites on first launch, so the agent does not have to:

```text
Install CPilot on this Mac.
1. Run: curl -fsSL https://raw.githubusercontent.com/kalahroudi/cpilot/main/scripts/install.sh | bash
2. CPilot opens and its first-run setup checks what it needs and installs whatever is missing. Tell me to click
   "Set everything up" in that window if it is waiting, and wait until it reports everything is ready.
   If a step needs my password, tell me exactly which command to run in Terminal.
3. Register its MCP server: claude mcp add cpilot --scope user -- /Applications/CPilot.app/Contents/MacOS/cpilot-mcp
4. Call get_status and tell me what it reports.
Never call a destructive tool without asking me first.
```

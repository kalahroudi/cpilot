// SPDX-License-Identifier: Apache-2.0

import Foundation
import CPilotKit

/// `cpilot-mcp --read-once-hook`: a Claude Code PreToolUse hook. It reads the hook's JSON from stdin and, when the call would read a file the conversation already holds unchanged, answers
/// with a refusal that says so. In every other case, and on any error, it prints nothing, which lets the call run.
func runReadOnceHook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any], let tool = obj["tool_name"] as? String, tool == "Read" || tool == "Bash",
          let toolInput = obj["tool_input"] as? [String: Any], let transcriptPath = obj["transcript_path"] as? String else { exit(0) }
    let flags = CommandLine.arguments
    func log(_ record: [String: Any]) {
        if let line = try? JSONSerialization.data(withJSONObject: record), let text = String(data: line, encoding: .utf8) {
            let url = AppPaths().root.appendingPathComponent("read-once.jsonl")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((text + "\n").utf8)); try? h.close() }
            else { try? Data((text + "\n").utf8).write(to: url) }
        }
    }
    if flags.contains("--sensitive"), let why = SensitiveGuard.decide(tool: tool, input: toolInput) {
        print(ReadOnce.hookOutput(reason: why))
        log(["ts": Date().timeIntervalSince1970, "session": obj["session_id"] as? String ?? "", "blocked": "sensitive"])
        exit(0)
    }
    guard flags.contains("--repeats") else { exit(0) }
    let cwd = obj["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    guard let target = ReadTarget.extract(tool: tool, input: toolInput) else { exit(0) }
    let path = target.path.hasPrefix("/") ? target.path : (target.path.hasPrefix("~") ? (target.path as NSString).expandingTildeInPath : cwd + "/" + target.path)
    // Bash reads name the file as typed, so it is resolved here; the transcript holds the same text, so the keys match without it.
    let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { exit(0) }
    let size = (try? handle.seekToEnd()) ?? 0
    let window: UInt64 = 16 * 1024 * 1024
    try? handle.seek(toOffset: size > window ? size - window : 0)
    guard var data = try? handle.readToEnd() else { exit(0) }
    if size > window, let nl = data.firstIndex(of: 0x0A) { data = data.suffix(from: data.index(after: nl)) }
    guard let d = ReadOnce.decide(tool: tool, input: toolInput, transcript: data, modified: modified) else { exit(0) }
    print(ReadOnce.hookOutput(reason: d.reason))
    // What it saved, for the Context Lens: a size and a session, never the file.
    log(["ts": Date().timeIntervalSince1970, "session": obj["session_id"] as? String ?? "", "saved": d.savedChars])
    exit(0)
}

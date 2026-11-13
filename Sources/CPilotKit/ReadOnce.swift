// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Stops the same file from being read into a conversation twice. A file the agent already has, unchanged, is sent again with every later call for nothing: on measured use 42% of what
/// the Read tool returned was a repeat inside one conversation. The decision is made from the conversation's own transcript and fails open: when anything is unclear, the read goes ahead.
public enum ReadOnce {
    public static let marker = "[cpilot read-once]"

    /// A read the transcript shows as completed, with where it happened and what came back.
    struct Prior { var key: String; var ts: Date; var index: Int; var chars: Int; var denied: Bool }

    /// The reason to refuse this call, or nil to let it run. `modified` is the file's modification time now.
    /// - Nothing is refused unless an earlier identical read returned its content, the file has not changed since, the conversation has not shrunk since (which is how compaction shows),
    ///   and that same read was not already refused once (an agent that insists gets it).
    public static func decide(tool: String, input: [String: Any], transcript: Data, modified: Date?, now: Date = .now) -> (reason: String, savedChars: Int)? {
        guard let target = ReadTarget.extract(tool: tool, input: input), let modified else { return nil }
        let key = target.path + "\u{0}" + (target.range ?? "")
        var uses: [String: (key: String, ts: Date, index: Int)] = [:]
        var priors: [Prior] = []
        var lastContext = 0
        var shrunkAt = -1
        var index = 0
        for line in transcript.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.first == 0x7B, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let message = obj["message"] as? [String: Any] else { continue }
            let ts = TranscriptUsage.date(obj["timestamp"] as? String)
            if obj["type"] as? String == "assistant" {
                index += 1
                if obj["isSidechain"] as? Bool != true, let u = message["usage"] as? [String: Any] {
                    let ctx = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
                    if lastContext > 20_000, Double(ctx) < Double(lastContext) * 0.6 { shrunkAt = index }
                    if ctx > 0 { lastContext = ctx }
                }
                for b in message["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                    guard let id = b["id"] as? String, let name = b["name"] as? String, let t = ReadTarget.extract(tool: name, input: b["input"] as? [String: Any] ?? [:]) else { continue }
                    uses[id] = (t.path + "\u{0}" + (t.range ?? ""), ts, index)
                }
            } else if obj["type"] as? String == "user" {
                if (obj["isCompactSummary"] as? Bool) == true { shrunkAt = index }
                for b in message["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
                    guard let id = b["tool_use_id"] as? String, let u = uses[id] else { continue }
                    let failed = (b["is_error"] as? Bool) == true
                    var text = ""
                    if let s = b["content"] as? String { text = s } else if let l = b["content"] as? [[String: Any]] { text = l.compactMap { $0["text"] as? String }.joined() }
                    let size = TranscriptUsage.chars(b["content"])
                    if text.hasPrefix(marker) || text.contains(marker) { priors.append(Prior(key: u.key, ts: u.ts, index: u.index, chars: 0, denied: true)) }
                    else if !failed, size > 0 { priors.append(Prior(key: u.key, ts: u.ts, index: u.index, chars: size, denied: false)) }
                }
            }
        }
        guard let last = priors.last(where: { $0.key == key && !$0.denied }) else { return nil }
        if modified > last.ts { return nil }
        if shrunkAt >= last.index { return nil }
        if priors.contains(where: { $0.key == key && $0.denied && $0.index >= last.index }) { return nil }
        let ago = max(1, index - last.index)
        let what = target.range.map { "\(target.path) (\($0))" } ?? target.path
        return ("\(marker) You already read \(what) \(ago) message\(ago == 1 ? "" : "s") ago in this conversation and it has not changed since, so its content is already above. Use that. If you really need it again, make the same call once more.", last.chars)
    }

    /// The hook's answer for Claude Code: refuse the call and say why.
    public static func hookOutput(reason: String) -> String {
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

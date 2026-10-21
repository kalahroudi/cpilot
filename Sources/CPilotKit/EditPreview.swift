// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What an approval card shows for a file edit, so you can judge the change before allowing it:
/// removed lines, added lines, and for a new file the first lines of its content.
public enum EditPreview {
    public struct Line: Equatable, Sendable { public enum Kind: Sendable { case added, removed, note }; public var kind: Kind; public var text: String }

    public static func lines(tool: String, inputJSON: String, maxLines: Int = 40) -> [Line] {
        guard let d = inputJSON.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        var out: [Line] = []
        func pair(_ old: String, _ new: String) {
            for l in old.components(separatedBy: "\n") { out.append(Line(kind: .removed, text: l)) }
            for l in new.components(separatedBy: "\n") { out.append(Line(kind: .added, text: l)) }
        }
        switch tool {
        case "Edit":
            pair((o["old_string"] as? String) ?? "", (o["new_string"] as? String) ?? "")
            if (o["replace_all"] as? Bool) == true { out.append(Line(kind: .note, text: "Replaces every occurrence in the file")) }
        case "MultiEdit":
            for e in (o["edits"] as? [[String: Any]]) ?? [] {
                pair((e["old_string"] as? String) ?? "", (e["new_string"] as? String) ?? "")
                out.append(Line(kind: .note, text: "…"))
            }
            if out.last?.text == "…" { out.removeLast() }
        case "Write":
            let content = (o["content"] as? String) ?? ""
            let exists = (o["file_path"] as? String).map { FileManager.default.fileExists(atPath: $0) } ?? false
            out.append(Line(kind: .note, text: exists ? "Replaces the whole file" : "New file"))
            for l in content.components(separatedBy: "\n") { out.append(Line(kind: .added, text: l)) }
        default: return []
        }
        if out.count > maxLines {
            let hidden = out.count - maxLines
            out = Array(out.prefix(maxLines)) + [Line(kind: .note, text: "… \(hidden) more lines")]
        }
        return out
    }

    /// Stored on the chat row as plain text: `+ added`, `- removed`, `# note`.
    public static func encode(_ lines: [Line]) -> String {
        lines.map { ($0.kind == .added ? "+ " : $0.kind == .removed ? "- " : "# ") + $0.text }.joined(separator: "\n")
    }

    public static func decode(_ s: String) -> [Line] {
        s.components(separatedBy: "\n").map { l in
            let body = String(l.dropFirst(2))
            return Line(kind: l.hasPrefix("+ ") ? .added : l.hasPrefix("- ") ? .removed : .note, text: body)
        }
    }
}

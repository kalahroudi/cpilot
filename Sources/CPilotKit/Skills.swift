// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Skill: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var detail: String
    public var path: String
    public var scope: String        // "user" or "project"
}

/// Finds the skill folders already on this Mac. Claude loads them by itself; for other agents CPilot can paste a skill's text into the chat.
public enum SkillCatalog {
    public static func discover(project: String?) -> [Skill] {
        var roots: [(URL, String)] = [(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills"), "user")]
        if let p = project { roots.append((URL(fileURLWithPath: p).appendingPathComponent(".claude/skills"), "project")) }
        var out: [Skill] = []
        for (root, scope) in roots {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = d.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let fm = frontmatter(text)
                out.append(Skill(name: fm["name"] ?? d.lastPathComponent, detail: fm["description"] ?? "", path: file.path, scope: scope))
            }
        }
        return out
    }

    /// Reads the simple `key: value` block between the first two `---` lines.
    public static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for l in lines.dropFirst() {
            if l.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let c = l.firstIndex(of: ":"), !l.hasPrefix(" ") else { continue }
            let k = String(l[..<c]).trimmingCharacters(in: .whitespaces)
            var v = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }

    /// The skill's instructions without the frontmatter, ready to paste into a chat with an agent that has no skill support.
    public static func body(of skill: Skill) -> String {
        guard let text = try? String(contentsOfFile: skill.path, encoding: .utf8) else { return "" }
        let parts = text.components(separatedBy: "\n---\n")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "\n---\n") : text
    }
}

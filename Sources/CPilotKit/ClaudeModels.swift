// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The models a Claude session can be started on. The three aliases always exist; anything newer comes from Claude Code's own list,
/// which it keeps in `~/.claude.json` for the signed-in account, so a new model shows up here without a release of this app.
public enum ClaudeModels {
    public struct Option: Hashable, Sendable {
        public var value: String      // what goes after `--model`; "" is Claude's default
        public var label: String
        public var detail: String
        public init(value: String, label: String, detail: String = "") { self.value = value; self.label = label; self.detail = detail }
    }

    public static let aliases: [Option] = [
        Option(value: "", label: "Default", detail: "Whatever Claude Code picks for your account."),
        Option(value: "opus", label: "Opus"), Option(value: "sonnet", label: "Sonnet"), Option(value: "haiku", label: "Haiku"),
    ]

    public static var claudeJSON: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// The aliases, then the extra models Claude Code lists (read from the contents of `.claude.json`). Nothing is added twice.
    public static func options(claudeJSON data: Data?) -> [Option] {
        var out = aliases
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extra = root["additionalModelOptionsCache"] as? [[String: Any]] else { return out }
        for e in extra {
            guard let value = (e["value"] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  !out.contains(where: { $0.value == value }) else { continue }
            let detail = (e["description"] as? String) ?? ""
            let label = (e["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
            // "Fable 5.1 · Most capable…" names the version better than the bare "Fable" label does.
            let version = detail.components(separatedBy: " · ").first.flatMap { $0.hasPrefix(label) ? $0 : nil }
            out.append(Option(value: value, label: version ?? label, detail: detail))
        }
        return out
    }

    public static func current() -> [Option] { options(claudeJSON: try? Data(contentsOf: claudeJSON)) }

    /// The options, plus the one in use when it is a custom id that is not listed (so a typed id never disappears from the picker).
    public static func options(including selected: String, in list: [Option]) -> [Option] {
        selected.isEmpty || list.contains(where: { $0.value == selected }) ? list : list + [Option(value: selected, label: selected, detail: "Custom model")]
    }

    /// How a stored value reads: its label when known, else the value itself.
    public static func label(for value: String, in list: [Option]) -> String {
        list.first { $0.value == value }?.label ?? (value.isEmpty ? "Default" : value)
    }
}

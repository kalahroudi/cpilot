// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The models a Claude session can be started on. The three aliases always exist; anything newer comes from Claude Code's own list,
/// which it keeps in `~/.claude.json` for the signed-in account, so a new model shows up here without a release of this app.
public enum ClaudeModels {
    public struct Option: Hashable, Sendable {
        public var value: String      // what goes after `--model`; "" is Claude's default
        public var label: String
        public var detail: String
        /// Listed under "older models" rather than first.
        public var older: Bool
        public init(value: String, label: String, detail: String = "", older: Bool = false) { self.value = value; self.label = label; self.detail = detail; self.older = older }
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

    /// Claude Code's own catalog of the models this account can use, kept fresh by Claude Code itself (one file per surface: `cc` is the command line, `ccd` the desktop app).
    public static var catalogDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/cache/model-catalog", isDirectory: true) }
    public static var settingsFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    public struct CatalogModel: Equatable, Sendable {
        public var id: String
        public var name: String
        public var shortName: String
        public var detail: String
        public var older: Bool
        public var minVersion: String?
    }

    public struct Catalog: Equatable, Sendable {
        public var surface: String
        public var fetchedAt: Double
        public var models: [CatalogModel]
        /// The model Claude Code itself would use now.
        public var current: String?
    }

    /// One catalog file. Nil when it is not the expected shape.
    public static func parseCatalog(_ data: Data) -> Catalog? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let cat = root["catalog"] as? [String: Any],
              let cfg = cat["config"] as? [String: Any], let list = cfg["models"] as? [[String: Any]] else { return nil }
        let models = list.compactMap { m -> CatalogModel? in
            guard let id = (m["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CatalogModel(id: id, name: name, shortName: (m["short_name"] as? String) ?? name, detail: (m["description"] as? String) ?? "",
                                older: (m["section"] as? String).map { $0 != "main" } ?? false, minVersion: m["min_claude_code_version"] as? String)
        }
        guard !models.isEmpty else { return nil }
        return Catalog(surface: (cat["surface"] as? String) ?? (cfg["id"] as? String) ?? "", fetchedAt: (root["fetchedAt"] as? Double) ?? 0, models: models,
                       current: (cat["state"] as? [String: Any])?["model"] as? String)
    }

    /// The catalog to use: the newest one for the command line, else the newest of any surface.
    static func best(_ catalogs: [Data]) -> Catalog? {
        let all = catalogs.compactMap(parseCatalog)
        return all.filter { $0.surface == "cc" }.max { $0.fetchedAt < $1.fetchedAt } ?? all.max { $0.fetchedAt < $1.fetchedAt }
    }

    /// The options to offer: Default, the catalog's main models by name, anything else Claude Code lists or the user's settings name, then the older models. Without a catalog this is the three aliases
    /// and whatever `.claude.json` lists, as before.
    public static func options(claudeJSON data: Data?, catalogs: [Data], settingsModel: String?) -> [Option] {
        guard let catalog = best(catalogs) else {
            var out = options(claudeJSON: data)
            if let m = settingsModel, !m.isEmpty, !out.contains(where: { $0.value == m }) { out.append(Option(value: m, label: m, detail: "Set in your Claude Code settings")) }
            return out
        }
        let known = Dictionary(catalog.models.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let defaultName = (settingsModel.flatMap { known[$0] ?? $0 }) ?? catalog.current.flatMap { known[$0] ?? $0 }
        var out = [Option(value: "", label: "Default", detail: defaultName.map { "Claude Code's own choice: \($0)." } ?? "Whatever Claude Code picks for your account.")]
        func add(_ o: Option) { if !out.contains(where: { $0.value == o.value }) { out.append(o) } }
        for m in catalog.models where !m.older { add(Option(value: m.id, label: m.name, detail: detailText(m))) }
        // Variants Claude Code lists that the catalog does not (such as a 1M-context build).
        for var o in options(claudeJSON: data).dropFirst(aliases.count) where !catalog.models.contains(where: { $0.id == o.value }) {
            if o.value.hasSuffix("[1m]"), !o.label.contains("1M") { o.label += " (1M context)" }
            add(o)
        }
        if let m = settingsModel, !m.isEmpty, !out.contains(where: { $0.value == m }), !catalog.models.contains(where: { $0.id == m }) { add(Option(value: m, label: m, detail: "Set in your Claude Code settings")) }
        for m in catalog.models where m.older { add(Option(value: m.id, label: m.name, detail: detailText(m), older: true)) }
        return out
    }

    private static func detailText(_ m: CatalogModel) -> String {
        [m.detail, m.minVersion.map { "Needs Claude Code \($0) or newer." }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func current() -> [Option] {
        let files = (try? FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)) ?? []
        let catalogs = files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }
        let settings = (try? Data(contentsOf: settingsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return options(claudeJSON: try? Data(contentsOf: claudeJSON), catalogs: catalogs, settingsModel: settings?["model"] as? String)
    }

    /// The alias words Claude accepts for the newest model of a family.
    static let familyAliases: Set<String> = ["opus", "sonnet", "haiku", "fable"]

    /// The options, plus the one in use when it is a custom id that is not listed (so a typed id never disappears from the picker).
    public static func options(including selected: String, in list: [Option]) -> [Option] {
        selected.isEmpty || list.contains(where: { $0.value == selected }) ? list : list + [Option(value: selected, label: selected, detail: "Custom model")]
    }

    /// How a stored value reads: its label when known, else the value itself. A family alias (`opus`) reads as the newest model of that family when the list has one ("Opus 5.5 (latest)").
    public static func label(for value: String, in list: [Option]) -> String {
        if let o = list.first(where: { $0.value == value }) { return o.label }
        if familyAliases.contains(value.lowercased()), let o = list.first(where: { !$0.older && $0.label.lowercased().hasPrefix(value.lowercased()) }) { return o.label + " (latest)" }
        return value.isEmpty ? "Default" : value
    }

    /// The name for a model id Claude reports it is running (`claude-fable-5-2` or `claude-fable-5-2[1m]`), so the header can say what is really in use.
    public static func name(ofRunning id: String, in list: [Option]) -> String {
        if let o = list.first(where: { $0.value == id }) { return o.label }
        let bare = id.components(separatedBy: "[").first ?? id
        if let o = list.first(where: { $0.value == bare || $0.value.hasPrefix(bare + "[") }) { return o.label + (id.contains("[1m]") ? " (1M context)" : "") }
        return id
    }
}

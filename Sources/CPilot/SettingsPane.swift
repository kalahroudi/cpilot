// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
/// The search box filters every tab at once: a row stays when its name or explanation has every word, a whole group stays when its title does.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    @State private var query = ""
    @State private var found = 1
    enum Tab: Hashable { case general, sessions, access, github, agents, updates, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                SearchBox(prompt: "Search settings", text: $query).frame(width: 240)
            } tabs: {
                if !searching {
                    TabBar(tabs: [(Tab.general, "General"), (Tab.sessions, "Sessions"), (Tab.access, "Access"), (Tab.github, "GitHub"), (Tab.agents, "Agents"), (Tab.updates, "Updates"), (Tab.about, "About")], selection: $tab)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if searching {
                        general; sessions; AccessSettings(); GitHubSettings(); AgentSettings()
                        if found == 0 { Text("No setting matches \"\(query)\".").foregroundStyle(.secondary).font(.system(size: 13)).padding(.top, 8) }
                    } else {
                        switch tab {
                        case .general: general
                        case .sessions: sessions
                        case .access: AccessSettings()
                        case .github: GitHubSettings()
                        case .agents: AgentSettings()
                        case .updates: UpdatesView()
                        case .about: about
                        }
                    }
                }
                .environment(\.settingsQuery, query.trimmingCharacters(in: .whitespaces))
                .onPreferenceChange(SettingsMatchCount.self) { found = $0 }
                .padding(22).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("CPilot \(BuildInfo.current.version) · github.com/kalahroudi/cpilot"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

    /// The app itself: how it starts, looks and tells you things.
    private var general: some View {
        @Bindable var p = prefs
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Startup") {
                SettingRow("Launch at login", "Starts in the menu bar and uses no CPU until you open it.", error: prefs.launchAtLoginError) { toggle(Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })) }
            }
            SettingsGroup("Appearance") {
                SettingRow("Theme", "Applies to the window and the menu bar popover.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                SettingRow("Dock icon", "Keep CPilot in the Dock as well as the menu bar.") { toggle($p.showDockIcon) }
                SettingRow("Sessions as", "Tabs across the top, or a list down the left grouped by project.") { Segmented(options: [(false, "Tabs"), (true, "Side list")], selection: $p.tabsOnSide) }
            }
            SettingsGroup("Notifications") {
                SettingRow("Notify me", "When a session needs approval or finishes while CPilot is in the background.") { toggle($p.notify) }
                SettingRow("Pull request checks", "Tells you when the checks on your open pull requests pass or fail. One request per repository: every minute while checks run, every ten minutes otherwise.") { toggle($p.notifyChecks) }
            }
            SettingsGroup("Performance") {
                SettingRow("Nothing runs while hidden", "No polling or timers while the popover and window are closed, except the pull request check watcher. Sleeping tabs hold no memory.") { Badge(text: "always on", kind: .ok) }
                SettingRow("App memory", "How much memory CPilot uses right now.") { Text(AppMemory.footprint).font(.system(size: 12.5)).foregroundStyle(.secondary) }
            }
        }
    }

    /// Working with agents: sessions, what they remember, specs and capture.
    private var sessions: some View {
        @Bindable var p = prefs
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Sessions") {
                SettingRow("Follow the session", "Opening a session makes its repository the active one, so Specs, Stacks and Pull requests show the repository you are working in.") { toggle($p.followSession) }
                SettingRow("Isolate new sessions in a worktree", "Each session on a new branch gets its own copy of the files, so parallel sessions never collide.") { toggle($p.useWorktrees) }
                SettingRow("Put idle tabs to sleep", "Stops an idle session's agent after this long. It resumes with its full context when you send the next message.") {
                    Segmented(options: [(5, "5 min"), (10, "10 min"), (30, "30 min"), (240, "4 h")], selection: $p.sleepMinutes)
                }
                SettingRow("Recap when you return", "Opening a session you have been away from for a while shows where things stand: the latest ask, what got done, and anything waiting on you.") { toggle($p.recapAuto) }
                if prefs.recapAuto { SettingRow("Let Claude write recaps", "A small, cheap call that rewrites the recap in a few friendly lines. Off keeps it to the plain version built on your Mac.") { toggle($p.recapWithClaude) } }
            }
            SettingsGroup("Specs and stacks") {
                SettingRow("Default autonomy", Autonomy(rawValue: prefs.specAutonomy)?.detail ?? "") {
                    Segmented(options: Autonomy.allCases.map { ($0.rawValue, $0.label) }, selection: $p.specAutonomy)
                }
                SettingRow("Offer \"Merge all as admin\"", "On a stack that GitHub's rules block, merges every open pull request in order past those rules, after one confirmation. Each still needs its checks to pass. Off keeps the one-at-a-time button.") { toggle($p.adminMergeAll) }
                SettingRow("Resolve stack conflicts with Claude", "When a restack stops on a conflict, a session starts by itself in a temporary copy to resolve it. Merge all as admin waits for it and carries on. Off keeps it a button.") { toggle($p.autoResolveConflicts) }
                if prefs.autoResolveConflicts { SettingRow("Wait for a conflict up to", "How long Merge all as admin waits for Claude to resolve a conflict before it stops and leaves the conflict card.") {
                    Segmented(options: [(10, "10 min"), (40, "40 min"), (120, "2 h"), (0, "No limit")], selection: $p.conflictWaitMinutes)
                } }
                SettingRow("Archive finished specs", "A spec moves to its archive folder by itself when its last task merges. Archived specs are not read again and can be restored from the Specs list.") { toggle($p.autoArchiveSpecs) }
            }
            SettingsGroup("Memory") {
                SettingRow("Notes", "Plain Markdown notes every session starts with. Always on. Edit them in the Memory screen.") { Badge(text: "always on", kind: .ok) }
                SettingRow("Recall from earlier sessions", "Finished messages are kept in a small local index on this Mac. A new session starts with the best matches for its first message. Nothing is sent anywhere.") { toggle($p.recall) }
                if prefs.recall { RecallStatsRow() }
                SettingRow("Long-term memory engine", "Optional. Connects a memory engine over MCP so sessions can recall what earlier sessions learned.") {
                    Segmented(options: [("files", "Off"), ("engine", "On")], selection: $p.memoryEngine)
                }
                if prefs.memoryEngine == "engine" { MemoryEngineRow() }
            }
            SettingsGroup("Capture") {
                SettingRow("Capture shortcut", "Control-Option-Command-C drags out a region of the screen and attaches it to the active session.") { toggle($p.captureHotkey) }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(size: 72)).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPilot").font(.system(size: 18, weight: .semibold))
                    Text("Version \(BuildInfo.current.version) · \(BuildInfo.current.shortCommit)").foregroundStyle(.secondary)
                    Text("A superlight menu bar app for running AI coding sessions.").font(.system(size: 12.5))
                }
            }
            HStack(spacing: 10) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/kalahroudi/cpilot")!)
                Link("Report an issue", destination: URL(string: "https://github.com/kalahroudi/cpilot/issues")!)
                Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }.buttonStyle(.link)
                Link("Website", destination: URL(string: "https://kalahroudi.github.io/cpilot/")!)
            }.font(.system(size: 13))
            Text("Licensed under the Apache License 2.0.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct RecallStatsRow: View {
    @State private var counts = Workspace.shared.index.counts()
    var body: some View {
        SettingRow("\(counts.notes) notes and \(counts.chats) message chunks indexed", "Secrets such as API keys are removed before anything is stored. Tool output is never stored.") {
            HStack(spacing: 6) {
                Button("Rebuild") { Workspace.shared.rebuildIndex(); counts = Workspace.shared.index.counts() }.buttonStyle(Pill(kind: .plain))
                Button("Forget chats") { Workspace.shared.index.removeAll(source: "chat"); counts = Workspace.shared.index.counts() }.buttonStyle(Pill(kind: .danger))
            }
        }
    }
}

struct MemoryEngineRow: View {
    @State private var up: Bool?
    var body: some View {
        @Bindable var p = Prefs.shared
        VStack(spacing: 0) {
            SettingRow("Engine address", up == nil ? "Checking…" : up == true ? "Reachable. Each project gets its own memory bank." : "Not reachable. Start the engine, then check again.") {
                HStack(spacing: 6) {
                    TextField("http://localhost:8888", text: $p.memoryEngineURL).textFieldStyle(CPField()).frame(width: 190)
                    AsyncButton("Check") { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) }.buttonStyle(Pill(kind: .plain))
                }
            }
            if up == false {
                SettingRow("Start it with Docker", "Copy this into Terminal. It stores data in its own volume and needs a language model key for extracting memories.") { CopyButton(text: MemoryEngine.dockerCommand, label: "Copy command") }
            }
        }.task { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) }
    }
}

/// What the settings search box holds. Rows and groups read it to hide themselves.
private struct SettingsQueryKey: EnvironmentKey { static let defaultValue = "" }
private struct SettingsGroupMatchedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var settingsQuery: String { get { self[SettingsQueryKey.self] } set { self[SettingsQueryKey.self] = newValue } }
    fileprivate var settingsGroupMatched: Bool { get { self[SettingsGroupMatchedKey.self] } set { self[SettingsGroupMatchedKey.self] = newValue } }
}

/// Every visible row adds one, so a group can tell when nothing in it matches and the pane can say so.
struct SettingsMatchCount: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
}

enum SettingsSearch {
    /// Every word of the query appears in the name or the explanation.
    static func matches(_ query: String, _ title: String, _ detail: String?) -> Bool {
        let hay = (title + " " + (detail ?? "")).lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }
}

struct SettingsGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    @Environment(\.settingsQuery) private var query
    @State private var rows = 1
    init(_ t: String, @ViewBuilder content: () -> C) { title = t; self.content = content() }
    var body: some View {
        let titleMatches = !query.isEmpty && SettingsSearch.matches(query, title, nil)
        let shown = query.isEmpty || titleMatches || rows > 0
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.leading, 4)
            VStack(spacing: 0) { content }.environment(\.settingsGroupMatched, titleMatches).padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
        .onPreferenceChange(SettingsMatchCount.self) { rows = $0 }
        .frame(height: shown ? nil : 0, alignment: .top).clipped().opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
        .padding(.bottom, shown ? 18 : 0)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var error: String?
    var separator = true
    @ViewBuilder var control: Control
    @Environment(\.settingsQuery) private var query
    @Environment(\.settingsGroupMatched) private var groupMatched
    init(_ title: String, _ detail: String?, error: String? = nil, separator: Bool = true, @ViewBuilder _ control: () -> Control) { self.title = title; self.detail = detail; self.error = error; self.separator = separator; self.control = control() }
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13))
            if let d = detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Label and control side by side when there is room; the control drops under the label when there is not,
    /// so text never gets squeezed into a sliver.
    var body: some View {
        if query.isEmpty || groupMatched || SettingsSearch.matches(query, title, detail) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    label.frame(minWidth: 190, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                    control.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) { label.frame(maxWidth: .infinity, alignment: .leading); control }
            }
            .padding(.vertical, 10).overlay(alignment: .top) { if separator { Divider().opacity(0.6) } }
            .preference(key: SettingsMatchCount.self, value: 1)
        }
    }
}

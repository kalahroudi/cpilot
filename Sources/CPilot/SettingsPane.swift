// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    enum Tab: Hashable { case general, access, github, agents, updates, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                EmptyView()
            } tabs: {
                TabBar(tabs: [(Tab.general, "General"), (Tab.access, "Access"), (Tab.github, "GitHub"), (Tab.agents, "Agents"), (Tab.updates, "Updates"), (Tab.about, "About")], selection: $tab)
            }
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .access: AccessSettings()
                    case .github: GitHubSettings()
                    case .agents: AgentSettings()
                    case .updates: UpdatesView()
                    case .about: about
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("CPilot \(BuildInfo.current.version) · github.com/kalahroudi/cpilot"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

    private var general: some View {
        @Bindable var p = prefs
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                SettingsGroup("Startup") {
                    SettingRow("Launch at login", "Starts in the menu bar and uses no CPU until you open it.", error: prefs.launchAtLoginError) { toggle(Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })) }
                }
                SettingsGroup("Appearance") {
                    SettingRow("Theme", "Applies to the window and the menu bar popover.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                    SettingRow("Dock icon", "Keep CPilot in the Dock as well as the menu bar.") { toggle($p.showDockIcon) }
                    SettingRow("Sessions as", "Tabs across the top, or a list down the left grouped by project.") { Segmented(options: [(false, "Tabs"), (true, "Side list")], selection: $p.tabsOnSide) }
                }
                SettingsGroup("Capture") {
                    SettingRow("Capture shortcut", "Control-Option-Command-C drags out a region of the screen and attaches it to the active session.") { toggle($p.captureHotkey) }
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 18) {
                SettingsGroup("Sessions") {
                    SettingRow("Put idle tabs to sleep", "Stops an idle session's agent after this long. It resumes with its full context when you send the next message.") {
                        Segmented(options: [(5, "5 min"), (10, "10 min"), (30, "30 min"), (240, "4 h")], selection: $p.sleepMinutes)
                    }
                    SettingRow("Isolate new sessions in a worktree", "Each session on a new branch gets its own copy of the files, so parallel sessions never collide.") { toggle($p.useWorktrees) }
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
                SettingsGroup("Notifications") {
                    SettingRow("Notify me", "When a session needs approval or finishes while CPilot is in the background.") { toggle($p.notify) }
                }
                SettingsGroup("Performance") {
                    SettingRow("Nothing runs while hidden", "No polling or timers while the popover and window are closed. Sleeping tabs hold no memory.") { Badge(text: "always on", kind: .ok) }
                    SettingRow("App memory", "How much memory CPilot uses right now.") { Text(AppMemory.footprint).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity)
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
                    TextField("http://localhost:8888", text: $p.memoryEngineURL).textFieldStyle(.roundedBorder).frame(width: 190)
                    Button("Check") { Task { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) } }.buttonStyle(Pill(kind: .plain))
                }
            }
            if up == false {
                SettingRow("Start it with Docker", "Copy this into Terminal. It stores data in its own volume and needs a language model key for extracting memories.") { CopyButton(text: MemoryEngine.dockerCommand, label: "Copy command") }
            }
        }.task { up = await MemoryEngine.isReachable(base: Prefs.shared.memoryEngineURL) }
    }
}

struct SettingsGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    init(_ t: String, @ViewBuilder content: () -> C) { title = t; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.leading, 4)
            VStack(spacing: 0) { content }.padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var error: String?
    @ViewBuilder var control: Control
    init(_ title: String, _ detail: String?, error: String? = nil, @ViewBuilder _ control: () -> Control) { self.title = title; self.detail = detail; self.error = error; self.control = control() }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let d = detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            }
            Spacer(minLength: 8)
            control
        }.padding(.vertical, 10).overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import CPilotKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    enum Tab: Hashable { case general, updates, agents, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                EmptyView()
            } tabs: {
                TabBar(tabs: [(Tab.general, "General"), (Tab.updates, "Updates"), (Tab.agents, "Agents (MCP)"), (Tab.about, "About")], selection: $tab)
            }
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .updates: UpdatesView()
                    case .agents: AgentsView()
                    case .about: about
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("CPilot \(BuildInfo.current.version) · github.com/kalahroudi/cpilot"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private var general: some View {
        @Bindable var p = prefs
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                SettingsGroup("Startup") {
                    SettingRow("Launch at login", "Adds the app to Login Items. Turn it off any time.", error: prefs.launchAtLoginError) { Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
                SettingsGroup("Appearance") {
                    SettingRow("Theme", "Applies to the Manager window and the menu bar popover.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                    SettingRow("Dock icon", "Keep the app in the Dock as well as the menu bar.") { Toggle("", isOn: $p.showDockIcon).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 18) {
                SettingsGroup("Performance") {
                    SettingRow("Refresh only when visible", "Nothing is polled while the popover and window are closed. An idle app uses almost no CPU.") { Badge(text: "always on", kind: .ok) }
                    SettingRow("Refresh interval", nil) { Segmented(options: [(2, "2 s"), (5, "5 s"), (15, "15 s")], selection: $p.refreshSeconds) }
                }
                SettingsGroup("Notifications") {
                    SettingRow("Notify when long tasks finish", "Long tasks run in the background.") { Toggle("", isOn: $p.notify).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
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
                    Text("One sentence about the app.").font(.system(size: 12.5))
                }
            }
            HStack(spacing: 10) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/kalahroudi/cpilot")!)
                Link("Report an issue", destination: URL(string: "https://github.com/kalahroudi/cpilot/issues")!)
            }.font(.system(size: 13))
        }
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

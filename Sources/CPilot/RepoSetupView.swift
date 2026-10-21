// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Create or adopt a repository and give it the same sensible defaults every time. Nothing happens until the button is pressed.
struct RepoSetupView: View {
    @State private var folder = UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory()
    @State private var plan = RepoSetupPlan(owner: "", name: "")
    @State private var topics = ""
    @State private var log: [String] = []
    @State private var running = false
    @State private var error: String?
    @State private var account: GitHub.Account?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Repo setup", subtitle: "README, GitHub Pages, a protected main branch and a security scan, in one go")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if account == nil {
                        Label("Sign in to GitHub first. In Terminal run: gh auth login", systemImage: "exclamationmark.triangle").font(.system(size: 12.5))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9))
                    }
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) {
                            SettingsGroup("Repository") {
                                SettingRow("Folder", folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { Button("Choose…") { choose() }.buttonStyle(Pill(kind: .plain)) }
                                SettingRow("Name", "Owner and repository name on GitHub.") {
                                    HStack(spacing: 4) {
                                        TextField("owner", text: $plan.owner).frame(width: 110); Text("/"); TextField("name", text: $plan.name).frame(width: 130)
                                    }.textFieldStyle(.roundedBorder)
                                }
                                SettingRow("Visibility", "Public repositories get every feature on the free plan.") {
                                    Segmented(options: [(true, "Public"), (false, "Private")], selection: $plan.isPublic)
                                }
                                SettingRow("About", "One sentence shown on the repository page.") { TextField("What it does", text: $plan.description).textFieldStyle(.roundedBorder).frame(width: 240) }
                                SettingRow("Topics", "Comma separated tags.") { TextField("swift, macos", text: $topics).textFieldStyle(.roundedBorder).frame(width: 240) }
                            }
                        }.frame(maxWidth: .infinity)
                        VStack(spacing: 18) {
                            SettingsGroup("Files") {
                                SettingRow("README", "Pitch, status and license.") { switchFor($plan.readme) }
                                SettingRow("License", nil) { Segmented(options: RepoSetupPlan.License.allCases.map { ($0, $0.label) }, selection: $plan.license) }
                                SettingRow("GitHub Pages", "A landing page from the docs folder, switched on for you.") { switchFor($plan.pages) }
                            }
                            SettingsGroup("Protection") {
                                SettingRow("Protect main", "Changes go through a pull request. No force pushes, no deleting main, linear history. You can still merge your own work and bypass in an emergency.") { switchFor($plan.protectMain) }
                                SettingRow("Owner can push straight to main", "Off: even you go through a pull request. Turn on only as an emergency hatch.") { switchFor($plan.ownerMayPushDirectly) }
                                SettingRow("Security scan on every PR", "Adds a small workflow, opened as a pull request, that scans each change.") { switchFor($plan.securityScan) }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    HStack {
                        Text(plan.protectMain && !plan.isPublic ? "Rulesets on private repositories need a paid GitHub plan. CPilot tells you if GitHub refuses." : "Everything above is a GitHub setting you can see and change afterwards.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button { run() } label: { if running { ProgressView().controlSize(.small) } else { Text("Create and set up") } }
                            .buttonStyle(Pill(kind: .primary)).disabled(running || plan.owner.isEmpty || plan.name.isEmpty || account == nil)
                    }
                    if !log.isEmpty || error != nil {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, l in Text("✓ " + l).foregroundStyle(Color.green.opacity(0.9)) }
                            if let error { Text("✗ " + error).foregroundStyle(Color.red.opacity(0.9)) }
                        }.font(.system(size: 12, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.terminal, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(22)
            }
        }
        .background(Theme.pane)
        .task {
            account = await GitHub.account()
            if plan.owner.isEmpty { plan.owner = account?.login ?? "" }
            if plan.name.isEmpty { plan.name = URL(fileURLWithPath: folder).lastPathComponent }
        }
    }

    private func switchFor(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

    private func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { folder = u.path; plan.name = u.lastPathComponent }
    }

    private func run() {
        running = true; log = []; error = nil
        plan.topics = topics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let p = plan, f = folder
        Task {
            do {
                try await RepoSetup.run(p, folder: f) { line in Task { @MainActor in log.append(line) } }
                UserDefaults.standard.set(f, forKey: "lastFolder")
            } catch { self.error = UserError.message(for: error, action: "Set up the repository") }
            running = false
        }
    }
}

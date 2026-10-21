// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Set a repository up, or bring an existing one in line: README, license, Pages, a protected main branch and a security scan.
/// It starts from what is really there: values from GitHub for a repository that exists, and suggestions from your own
/// files (README, package.json, project type) for one that does not. Nothing happens until you press the button.
struct RepoSetupView: View {
    let project = Project.shared
    @State private var folder = ""
    @State private var plan = RepoSetupPlan(owner: "", name: "")
    @State private var topics: [String] = []
    @State private var newTopic = ""
    @State private var existsOnGitHub = false
    @State private var fromGitHub = false
    @State private var loading = false
    @State private var log: [String] = []
    @State private var running = false
    @State private var error: String?
    @State private var account: GitHub.Account?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Repo setup", subtitle: "README, GitHub Pages, a protected main branch and a security scan, in one go") { RepoMenu() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if account == nil {
                        Label("Sign in to GitHub first. In Terminal run: gh auth login", systemImage: "exclamationmark.triangle").font(.system(size: 12.5))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if project.current?.environment != nil {
                        Label("Repo setup runs on this Mac. Choose a folder on this Mac to set up.", systemImage: "info.circle").font(.system(size: 12.5))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
                    }
                    banner
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { repositoryCard; VStack(spacing: 18) { filesCard; protectionCard } }
                        VStack(spacing: 18) { repositoryCard; filesCard; protectionCard }
                    }
                    HStack(alignment: .center) {
                        Text(plan.protectMain && !plan.isPublic ? "Rulesets on private repositories need a paid GitHub plan. CPilot tells you if GitHub refuses." : "Everything above is a GitHub setting you can see and change afterwards.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button { run() } label: { if running { ProgressView().controlSize(.small) } else { Text(existsOnGitHub ? "Apply to \(plan.name)" : "Create and set up") } }
                            .buttonStyle(Pill(kind: .primary)).disabled(running || loading || plan.owner.isEmpty || plan.name.isEmpty || account == nil || folder.isEmpty)
                    }
                    if !log.isEmpty || error != nil {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, l in Text("✓ " + l).foregroundStyle(Color.green.opacity(0.9)) }
                            if let error { ErrorLine(text: error) }
                        }.font(.system(size: 12, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.terminal, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(22).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.pane)
        .task { account = AppModel.shared.demo ? AppModel.shared.github : await GitHub.account() }
        .task(id: project.current) { await load() }
    }

    // MARK: Cards

    @ViewBuilder private var banner: some View {
        if loading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the repository…").font(.system(size: 12.5)).foregroundStyle(.secondary) } }
        else if existsOnGitHub {
            Label(fromGitHub ? "\(plan.slug) is already on GitHub. These are its current settings; Apply changes only what you edit." : "\(plan.slug) is already on GitHub.", systemImage: "checkmark.seal")
                .font(.system(size: 12.5)).foregroundStyle(Theme.ok).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
        } else if !folder.isEmpty {
            Label("This folder is not on GitHub yet. About and topics were suggested from your README and project files; edit them freely.", systemImage: "sparkles")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
        }
    }

    private var repositoryCard: some View {
        card("Repository") {
            VStack(alignment: .leading, spacing: 14) {
                FormField("Folder") {
                    HStack {
                        Text(folder.isEmpty ? "Choose a repository above" : folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                        Button("Choose…") { Task { await project.addFolder() } }.buttonStyle(Pill(kind: .plain))
                    }
                }
                FormField("GitHub name", hint: "Owner and repository name.") {
                    HStack(spacing: 6) {
                        TextField("owner", text: $plan.owner).textFieldStyle(CPField()).frame(maxWidth: 190)
                        Text("/").foregroundStyle(.secondary)
                        TextField("name", text: $plan.name).textFieldStyle(CPField())
                    }.disabled(existsOnGitHub)
                }
                FormField("Visibility", hint: "Public repositories get every feature on the free plan.") {
                    Segmented(options: [(true, "Public"), (false, "Private")], selection: $plan.isPublic).disabled(existsOnGitHub)
                }
                FormField("About", hint: "One sentence shown on the repository page.") {
                    TextField("What it does", text: $plan.description, axis: .vertical).textFieldStyle(CPField()).lineLimit(1...3)
                }
                FormField("Topics", hint: "Tags that help people find it. Press Return to add one.") { topicsEditor }
            }
        }
    }

    private var topicsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !topics.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.self) { t in
                        HStack(spacing: 4) {
                            Text(t).font(.system(size: 12))
                            Button { topics.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(t)")
                        }.padding(.horizontal, 9).padding(.vertical, 4).background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                    }
                }
            }
            TextField("Add a topic", text: $newTopic).textFieldStyle(CPField()).onSubmit(addTopic).onChange(of: newTopic) { _, v in if v.hasSuffix(",") || v.hasSuffix(" ") { addTopic() } }
        }
    }

    private var filesCard: some View {
        card("Files") {
            VStack(spacing: 0) {
                SettingRow("README", "Pitch, status and license. Only created if there is none.") { switchFor($plan.readme) }
                SettingRow("License", "Added only if the folder has none.") { Segmented(options: RepoSetupPlan.License.allCases.map { ($0, $0.label) }, selection: $plan.license) }
                SettingRow("GitHub Pages", "A landing page from the docs folder, switched on for you.") { switchFor($plan.pages) }
            }
        }
    }

    private var protectionCard: some View {
        card("Protection") {
            VStack(spacing: 0) {
                SettingRow("Protect main", "Changes go through a pull request. No force pushes, no deleting main, linear history.") { switchFor($plan.protectMain) }
                SettingRow("Owner can push straight to main", "Off: even you go through a pull request. Turn on only as an emergency hatch.") { switchFor($plan.ownerMayPushDirectly) }
                SettingRow("Security scan on every PR", "Adds a small workflow, opened as a pull request, that scans each change.") { switchFor($plan.securityScan) }
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.leading, 4)
            content().padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func switchFor(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

    private func addTopic() {
        for t in newTopic.split(whereSeparator: { ", ".contains($0) }).map({ $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }) where !t.isEmpty && !topics.contains(t) { topics.append(t) }
        newTopic = ""
    }

    // MARK: Loading and running

    private func load() async {
        guard let r = project.current, r.environment == nil else { folder = ""; return }
        if AppModel.shared.demo { folder = r.dir; plan = RepoSetupPlan(owner: "octo", name: "shop"); plan.description = "A small shop API with orders and invoices."; topics = ["typescript", "nodejs", "api"]; return }
        loading = true; defer { loading = false }
        folder = r.dir; log = []; error = nil; fromGitHub = false
        let info = await Git.info(r.dir)
        var p = RepoSetupPlan(owner: account?.login ?? "", name: URL(fileURLWithPath: r.dir).lastPathComponent)
        let suggestion = RepoSetup.suggest(folder: r.dir)
        if let slug = info?.remote, let details = await GitHub.repoDetails(slug) {
            // The repository is on GitHub: show what it has now.
            let parts = slug.split(separator: "/").map(String.init)
            p.owner = parts.first ?? p.owner; p.name = parts.last ?? p.name
            p.description = details.description.isEmpty ? suggestion.description : details.description
            topics = details.topics.isEmpty ? suggestion.topics : details.topics
            p.isPublic = !details.isPrivate
            p.license = RepoSetupPlan.License.allCases.first { $0.rawValue == details.license } ?? .none
            p.pages = details.hasPages; p.protectMain = details.protectedMain
            existsOnGitHub = true; fromGitHub = true
        } else {
            p.description = suggestion.description; topics = suggestion.topics; existsOnGitHub = false
        }
        plan = p
    }

    private func run() {
        running = true; log = []; error = nil
        plan.topics = topics
        let p = plan, f = folder
        Task {
            do { try await RepoSetup.run(p, folder: f) { line in Task { @MainActor in log.append(line) } }; existsOnGitHub = true }
            catch { self.error = AppModel.shared.capture(error, action: "Set up the repository") }
            running = false
        }
    }
}

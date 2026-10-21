// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// The repository you are working in. Specs, Stacks, Pull requests and Repo setup all follow it, so you choose it once.
@MainActor @Observable
final class Project {
    static let shared = Project()
    var current: PRCenter.Repo? { didSet { if current != oldValue { let r = current; Task { await PRCenter.shared.warm(r) } } } }
    private(set) var known: [String] = UserDefaults.standard.stringArray(forKey: "knownRepos") ?? []

    /// Folders of your sessions, folders you added by hand, and the current one.
    func repos() -> [PRCenter.Repo] {
        var seen = Set<PRCenter.Repo>(), out: [PRCenter.Repo] = []
        func add(_ r: PRCenter.Repo) { if seen.insert(r).inserted { out.append(r) } }
        if let c = current { add(c) }
        for m in Workspace.shared.sessions { add(PRCenter.Repo(dir: m.cwd, environment: m.environment)) }
        for d in known { add(PRCenter.Repo(dir: d, environment: nil)) }
        return out
    }

    /// Starts from the session you are in, or the most recent one.
    func ensureDefault() {
        guard current == nil else { return }
        if let s = Workspace.shared.current { current = PRCenter.Repo(dir: s.meta.cwd, environment: s.meta.environment) }
        else { current = repos().first }
    }

    func choose(_ r: PRCenter.Repo) { current = r }

    /// Pick any git folder on this Mac, even one with no session yet.
    func addFolder() async {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Choose"
        p.message = "Choose a git repository"
        guard p.runModal() == .OK, let u = p.url else { return }
        guard await Git.isRepo(u.path) else { AppModel.shared.show("That folder is not a git repository.", error: true); return }
        let root = await Git.info(u.path)?.root ?? u.path
        if !known.contains(root) { known.append(root); UserDefaults.standard.set(known, forKey: "knownRepos") }
        current = PRCenter.Repo(dir: root, environment: nil)
    }
}

/// The one place the repository is chosen, at the top of the side menu so it is there on every pane. Specs, Stacks, Pull requests and
/// Repo setup follow it. Repositories with the same folder name are told apart by their parent folders.
struct RepoSwitcher: View {
    var expanded = true
    let project = Project.shared

    var body: some View {
        let repos = project.repos()
        let labels = RepoLabels.labels(repos.map { RepoRef(dir: $0.dir, environment: $0.environment) }) { Workspace.shared.environment($0)?.name }
        func label(_ r: PRCenter.Repo) -> String { labels[RepoRef(dir: r.dir, environment: r.environment)] ?? r.name }
        return Menu {
            ForEach(repos, id: \.self) { r in
                Button { project.choose(r) } label: { if r == project.current { Label(label(r), systemImage: "checkmark") } else { Text(label(r)) } }
            }
            if !repos.isEmpty { Divider() }
            AsyncButton("Add a folder…") { await project.addFolder() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Theme.accent).frame(width: 22)
                if expanded {
                    Text(project.current.map(label) ?? "Choose a repository").font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
        .menuStyle(.button).buttonStyle(.soft).menuIndicator(.hidden)
        .help(project.current.map { "Repository: \(label($0)). Specs, Stacks and Pull requests follow it." } ?? "Choose a repository")
        .accessibilityLabel("Repository")
        .onAppear { project.ensureDefault() }
    }
}

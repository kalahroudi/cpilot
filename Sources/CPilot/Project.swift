// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// The repository you are working in. Specs, Stacks, Pull requests and Repo setup all follow it, so you choose it once.
@MainActor @Observable
final class Project {
    static let shared = Project()
    var current: PRCenter.Repo? {
        didSet {
            guard current != oldValue else { return }
            // Whatever pane is showing, the open session must belong to the repository, or the Sessions pane comes back with a stranger's chat and no tab.
            Workspace.shared.keepSelectionInRepo()
            if !quiet { let r = current; Task { await PRCenter.shared.warm(r) } }
        }
    }
    private(set) var known: [String] = UserDefaults.standard.stringArray(forKey: "knownRepos") ?? []
    /// The top folder git reports for each folder (by `RepoRef.key`), so a session started in a subfolder is the same repository.
    private(set) var roots: [String: String] = [:]
    private var resolving = false
    /// Set while the repository changes only because you opened a session: nothing is fetched until a pane that needs it is opened.
    private var quiet = false

    /// Folders of your sessions, folders you added by hand, and the current one. Folders inside one repository appear once.
    func repos() -> [PRCenter.Repo] {
        var raw: [RepoRef] = []
        if let c = current { raw.append(RepoRef(dir: c.dir, environment: c.environment)) }
        for m in Workspace.shared.sessions { raw.append(RepoRef(dir: m.cwd, environment: m.environment)) }
        for d in known { raw.append(RepoRef(dir: d)) }
        if raw.contains(where: { roots[$0.key] == nil }) { resolveRoots(raw) }
        return RepoRef.collapse(raw, roots: roots).map { PRCenter.Repo(dir: $0.dir, environment: $0.environment) }
    }

    /// Asks git, once per folder, for its top folder. A folder that is not a repository (or cannot be read) stands for itself.
    private func resolveRoots(_ refs: [RepoRef]) {
        guard !resolving else { return }
        resolving = true
        Task {
            var found: [String: String] = [:]
            for r in refs where roots[r.key] == nil && found[r.key] == nil {
                let env = Workspace.shared.environment(r.environment)
                let top = await Exec.with(env) { await Git.mainRoot(r.dir) }
                let t = top ?? ""
                found[r.key] = t.isEmpty ? r.dir : t
            }
            roots.merge(found) { $1 }
            resolving = false
            Workspace.shared.keepSelectionInRepo()
            // The active repository may itself be a subfolder: move it to the top folder so the menu and the panes agree.
            if let c = current, let root = roots[RepoRef(dir: c.dir, environment: c.environment).key], root != c.dir { current = PRCenter.Repo(dir: root, environment: c.environment) }
        }
    }

    /// Starts from the session you are in, or the most recent one.
    func ensureDefault() {
        guard current == nil else { return }
        if let s = Workspace.shared.current { current = PRCenter.Repo(dir: s.meta.cwd, environment: s.meta.environment) }
        else { current = repos().first }
    }

    /// Whether a session belongs to the active repository (a session in a subfolder counts). Every list of sessions follows the repository.
    func owns(_ m: SessionMeta) -> Bool {
        guard let c = current else { return true }
        guard c.environment == m.environment else { return false }
        let own = RepoRef(dir: m.cwd, environment: m.environment).key
        if let root = roots[own] { return root == c.dir || RepoRef(dir: c.dir, environment: c.environment).contains(root) }
        return RepoRef(dir: c.dir, environment: c.environment).contains(m.cwd)
    }

    func choose(_ r: PRCenter.Repo) { current = r }

    /// You opened a session: its repository becomes the active one. Specs, Stacks and Pull requests load it when you open them.
    func follow(dir: String, environment: String?) {
        let ref = RepoRef(dir: dir, environment: environment)
        let top = roots[ref.key] ?? dir
        let r = PRCenter.Repo(dir: top, environment: environment)
        guard r != current else { return }
        quiet = true; current = r; quiet = false
    }

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

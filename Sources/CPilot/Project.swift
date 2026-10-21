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

/// The repository picker shown in every pane that works on one: it shows which repository is active, not a bare "Repository".
struct RepoMenu: View {
    let project = Project.shared

    var body: some View {
        Menu {
            ForEach(project.repos(), id: \.self) { r in
                Button { project.choose(r) } label: { if r == project.current { Label(r.name, systemImage: "checkmark") } else { Text(r.name) } }
            }
            Divider()
            Button("Add a folder…") { Task { await project.addFolder() } }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text(project.current?.name ?? "Choose a repository").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onAppear { project.ensureDefault() }
    }
}

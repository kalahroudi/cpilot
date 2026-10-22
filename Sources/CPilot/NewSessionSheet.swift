// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Where to work, with which agent, and what it may do. Return starts the session in the last used folder.
struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ws = Workspace.shared
    /// The repository chosen in the side menu comes first; only without one does it fall back to the last folder used.
    @State private var folder = Project.shared.current?.dir ?? UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory()
    @State private var info: RepoInfo?
    @State private var backend: Backend = .claude
    @State private var model = ""
    @State private var access: AccessLevel = Workspace.shared.policy.defaultLevel
    @State private var newBranch = true
    @State private var branch = ""
    @State private var worktree = Prefs.shared.useWorktrees
    @State private var first = ""
    @State private var busy = false
    @State private var error: String?
    @State private var cloneQuery = ""
    @State private var repos: [String] = []
    @State private var showClone = false
    @State private var envId: String? = Project.shared.current.map(\.environment) ?? UserDefaults.standard.string(forKey: "lastEnv").flatMap { Workspace.shared.environment($0) != nil ? $0 : nil }
    @State private var picking = false
    private var env: EnvironmentConfig? { ws.environment(envId) }

    private var folderLabel: String { env == nil ? folder.replacingOccurrences(of: NSHomeDirectory(), with: "~") : folder }
    private var agentName: String { agentOptions.first { $0.0 == backend }?.1 ?? "Claude" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New session").font(.system(size: 18, weight: .semibold))
                Text("\(agentName) on \(env?.name ?? "this Mac") · \(URL(fileURLWithPath: folder).lastPathComponent)").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }

            // What to do comes first: it is the one thing most sessions start with.
            TextField("What should it work on? (optional)", text: $first, axis: .vertical)
                .textFieldStyle(CPField()).lineLimit(3...6).font(.system(size: 13.5))

            group("Where") {
                if !ws.environments.isEmpty {
                    field("Run on") {
                        Segmented(options: [(String?.none, "This Mac")] + ws.environments.map { (String?.some($0.id), $0.name) }, selection: $envId)
                            .onChange(of: envId) { _, _ in
                                folder = env.map { ($0.folders.first ?? $0.remoteHome).replacingOccurrences(of: "~", with: $0.remoteHome) } ?? (UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory())
                                worktree = env == nil ? Prefs.shared.useWorktrees : worktree
                                if env != nil, access == .fullAccess { access = .askFirst }
                                backend = .claude
                            }
                    } note: { env.map { "The agent, files and git run on \($0.name). Approvals and captures stay on this Mac." } }
                    Divider()
                }
                field("Folder") {
                    HStack(spacing: 8) {
                        Text(folderLabel).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        Button("Choose…") { if env != nil { picking = true } else { choose() } }.buttonStyle(Pill(kind: .plain))
                        if env == nil { Button("Clone…") { showClone = true; Task { repos = await GitHub.repos() } }.buttonStyle(Pill(kind: .plain)).help("Clone from GitHub") }
                    }
                } note: {
                    if let info { "Git repository" + (info.remote.map { " · \($0)" } ?? "") + (info.dirty ? " · has uncommitted changes" : " · clean") }
                    else { "Not a git repository. Branches and pull requests are unavailable here." }
                }
            }

            group("Agent and permissions") {
                field("Agent") {
                    // Agents wrap onto more lines as you add them, so the sheet never grows wider than the window.
                    FlowLayout(spacing: 6) {
                        ForEach(agentOptions, id: \.0) { o in
                            Button { backend = o.0 } label: {
                                Text(o.1).font(.system(size: 12, weight: backend == o.0 ? .semibold : .regular)).lineLimit(1)
                                    .padding(.horizontal, 11).padding(.vertical, 4)
                                    .foregroundStyle(backend == o.0 ? Color.primary : .secondary)
                                    .background(backend == o.0 ? Theme.accentSoft : Theme.fill, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(backend == o.0 ? Theme.accent : .clear, lineWidth: 1.2))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if backend.kind == .claude {
                    Divider()
                    field("Model") { Segmented(options: [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")], selection: $model) }
                }
                Divider()
                field("Access") {
                    Segmented(options: AccessLevel.allCases.filter { env == nil || $0 != .fullAccess }.map { ($0, $0.label) }, selection: $access)
                } note: { access.detail }
            }

            if info != nil {
                group("Git") {
                    field("Branch") {
                        Segmented(options: [(true, "New branch"), (false, "Stay on \(info?.branch ?? "current")")], selection: $newBranch)
                        if newBranch { TextField("Name, or leave empty to pick one from your message", text: $branch).textFieldStyle(CPField()).font(.system(size: 12.5, design: .monospaced)) }
                    }
                    if newBranch {
                        Divider()
                        field("Isolate") {
                            Toggle(isOn: $worktree) { Text("Work in its own copy of the files").font(.system(size: 12.5)) }.toggleStyle(.switch).tint(Theme.accent)
                        } note: { "A worktree, so parallel sessions never collide." }
                    }
                }
            }

            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { start() } label: { if busy { ProgressView().controlSize(.small) } else { Text("Start session") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 580)
        .task(id: "\(envId ?? "")|\(folder)") { info = await Exec.with(env) { await Git.info(folder) }; if info == nil { worktree = false } }
        .sheet(isPresented: $picking) { if let e = env { RemoteFolderPicker(env: e, path: folder) { folder = $0 } } }
        .sheet(isPresented: $showClone) { cloneSheet }
    }

    /// A titled card whose rows are separated by hairlines.
    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) { rows() }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }

    /// One row: the name on the left, the control (and a one-line explanation) on the right.
    private func field<C: View>(_ label: String, @ViewBuilder _ control: () -> C, note: () -> String? = { nil }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                control()
                if let n = note() { Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var agentOptions: [(Backend, String)] {
        [(Backend.claude, "Claude")] + ws.acpAgents.map { (Backend.acp($0.id), $0.name) }
    }

    private var cloneSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clone from GitHub").font(.system(size: 15, weight: .semibold))
            SearchBox(prompt: "Search your repositories", text: $cloneQuery)
            List(repos.filter { cloneQuery.isEmpty || $0.localizedCaseInsensitiveContains(cloneQuery) }, id: \.self) { r in
                Button(r) { clone(r) }.buttonStyle(.soft)
            }.frame(height: 240)
            if repos.isEmpty { ProgressView().controlSize(.small) }
            HStack { Text("Into \(Prefs.shared.cloneFolder)").font(.system(size: 11.5)).foregroundStyle(.secondary); Spacer(); Button("Close") { showClone = false }.buttonStyle(Pill(kind: .plain)) }
        }.padding(18).frame(width: 440)
    }

    private func clone(_ slug: String) {
        showClone = false; busy = true
        Task {
            do {
                try? FileManager.default.createDirectory(atPath: Prefs.shared.cloneFolder, withIntermediateDirectories: true)
                folder = try await GitHub.clone(slug, into: Prefs.shared.cloneFolder)
            } catch { self.error = AppModel.shared.capture(error, action: "Clone the repository") }
            busy = false
        }
    }

    private func choose() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: folder)
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }

    private func start() {
        busy = true; error = nil
        if env == nil { UserDefaults.standard.set(folder, forKey: "lastFolder") }
        UserDefaults.standard.set(envId, forKey: "lastEnv")
        if access == .fullAccess, ws.policy.requireTouchIDForFullAccess {
            Biometrics.confirm("Start a session that runs without asking") { ok in if ok { create() } else { busy = false } }
        } else { create() }
    }

    private func create() {
        let name = branch.trimmingCharacters(in: .whitespaces)
        let n = Workspace.NewSession(folder: folder, backend: backend, model: model.isEmpty ? nil : model, access: access,
                                     branch: info != nil && newBranch ? (name.isEmpty ? Git.slugify(first.isEmpty ? "session" : first) : name) : nil,
                                     useWorktree: worktree && newBranch, firstMessage: first, environment: envId)
        Task {
            do { try await ws.create(n); dismiss(); AppDelegate.shared.showManager(pane: .sessions) }
            catch { self.error = AppModel.shared.capture(error, action: "Start the session"); busy = false }
        }
    }
}

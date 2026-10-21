// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Where to work, with which agent, and what it may do. Return starts the session in the last used folder.
struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ws = Workspace.shared
    @State private var folder = UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory()
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
    @State private var envId: String? = UserDefaults.standard.string(forKey: "lastEnv").flatMap { Workspace.shared.environment($0) != nil ? $0 : nil }
    @State private var picking = false
    private var env: EnvironmentConfig? { ws.environment(envId) }

    private var recents: [String] {
        var seen = Set<String>(), out: [String] = []
        for m in ws.sessions where m.environment == envId && !seen.contains(m.cwd) { seen.insert(m.cwd); out.append(m.cwd) }
        return Array(out.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New session").font(.system(size: 17, weight: .semibold))

            if !ws.environments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Environment")
                    Segmented(options: [(String?.none, "This Mac")] + ws.environments.map { (String?.some($0.id), $0.name) }, selection: $envId)
                        .onChange(of: envId) { _, _ in
                            folder = env.map { ($0.folders.first ?? $0.remoteHome).replacingOccurrences(of: "~", with: $0.remoteHome) } ?? (UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory())
                            worktree = env == nil ? Prefs.shared.useWorktrees : worktree
                            if env != nil, access == .fullAccess { access = .askFirst }
                            backend = .claude
                        }
                    if env != nil { Text("The agent, files and git run on \(env!.name). Approvals and captures stay on this Mac.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Working directory")
                HStack {
                    Text(env == nil ? folder.replacingOccurrences(of: NSHomeDirectory(), with: "~") : folder).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…") { if env != nil { picking = true } else { choose() } }.buttonStyle(Pill(kind: .plain))
                    if env == nil { Button("Clone from GitHub…") { showClone = true; Task { repos = await GitHub.repos() } }.buttonStyle(Pill(kind: .plain)) }
                }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                if !recents.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(recents, id: \.self) { r in
                            Button { folder = r } label: { Badge(text: URL(fileURLWithPath: r).lastPathComponent, kind: r == folder ? .accent : .neutral) }.buttonStyle(.plain)
                        }
                    }
                }
                if let info {
                    Text("Git repository" + (info.remote.map { " · \($0)" } ?? "") + (info.dirty ? " · has uncommitted changes" : " · clean"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else { Text("Not a git repository. Branches and pull requests are unavailable here.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }

            if info != nil {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Branch")
                    HStack {
                        Segmented(options: [(true, "New branch"), (false, "Stay on \(info?.branch ?? "current")")], selection: $newBranch)
                        if newBranch { TextField("fix/something", text: $branch).textFieldStyle(CPField()).font(.system(size: 12.5, design: .monospaced)) }
                    }
                    if newBranch {
                        Toggle(isOn: $worktree) {
                            Text("Isolate in a worktree").font(.system(size: 12.5))
                        }.toggleStyle(.switch).tint(Theme.accent)
                        Text("Its own copy of the files, so parallel sessions never collide.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Agent")
                HStack {
                    Segmented(options: agentOptions, selection: $backend)
                    if backend.kind == .claude {
                        Segmented(options: [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")], selection: $model)
                    }
                }
                HStack {
                    Text("Access").font(.system(size: 12.5))
                    Segmented(options: AccessLevel.allCases.filter { env == nil || $0 != .fullAccess }.map { ($0, $0.label) }, selection: $access)
                }
                Text(access.detail).font(.system(size: 11.5)).foregroundStyle(access == .fullAccess ? Theme.danger : .secondary)
            }

            TextField("First message (optional)", text: $first, axis: .vertical).textFieldStyle(CPField()).lineLimit(1...4)
            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { start() } label: { if busy { ProgressView().controlSize(.small) } else { Text("Start session") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
        .task(id: "\(envId ?? "")|\(folder)") { info = await Exec.with(env) { await Git.info(folder) }; if info == nil { worktree = false } }
        .sheet(isPresented: $picking) { if let e = env { RemoteFolderPicker(env: e, path: folder) { folder = $0 } } }
        .sheet(isPresented: $showClone) { cloneSheet }
    }

    private var agentOptions: [(Backend, String)] {
        [(Backend.claude, "Claude")] + ws.acpAgents.map { (Backend.acp($0.id), $0.name) }
    }

    private var cloneSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clone from GitHub").font(.system(size: 15, weight: .semibold))
            SearchBox(prompt: "Search your repositories", text: $cloneQuery)
            List(repos.filter { cloneQuery.isEmpty || $0.localizedCaseInsensitiveContains(cloneQuery) }, id: \.self) { r in
                Button(r) { clone(r) }.buttonStyle(.plain)
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

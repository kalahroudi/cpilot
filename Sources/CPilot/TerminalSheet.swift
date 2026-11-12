// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import SwiftTerm
import CPilotKit

/// A command to try, and the session folder to try it in.
struct TerminalTarget: Identifiable {
    let command: String
    let directory: String
    let env: EnvironmentConfig?
    var id: String { command + "@" + directory }
}

/// An integrated terminal that runs a command from the agent's reply in the session's worktree, then leaves a shell there.
struct TerminalSheet: View {
    let target: TerminalTarget
    @Environment(\.dismiss) private var dismiss
    @State private var runs = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RunnableCommands.shellLine(target.command)).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Text(target.directory).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button("Run again") { runs += 1 }.buttonStyle(.soft).foregroundStyle(Theme.accent)
                if TerminalLaunch.ghosttyInstalled { GhosttyButton(target: target) }
                Button("Close") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
            }.font(.system(size: 12)).padding(12)
            Divider()
            TerminalPane(target: target).id(runs).background(Theme.terminal)
        }.frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 600)
    }
}

struct GhosttyButton: View {
    let target: TerminalTarget
    var body: some View {
        Button("Open in Ghostty") {
            let args = TerminalLaunch.ghosttyOpenArgs(directory: target.directory, command: target.command, env: target.env)
            Task { _ = try? await Shell.run("/usr/bin/open", args) }
        }.buttonStyle(.soft).foregroundStyle(Theme.accent)
    }
}

private struct TerminalPane: NSViewRepresentable {
    let target: TerminalTarget

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let a = TerminalLaunch.argv(directory: target.directory, command: target.command, env: target.env)
        var env = Shell.environment
        env["NO_COLOR"] = nil
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        if let e = target.env { env = env.merging(SSH.environment(for: e)) { _, new in new } }
        view.startProcess(executable: a.executable, args: a.args, environment: env.map { "\($0.key)=\($0.value)" },
                          currentDirectory: target.env == nil ? target.directory : nil)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: ()) { view.terminate() }
}

/// Offers the commands a reply tells you to run. Nothing runs until you press one. A command that names a worktree (`cd <worktree> && …`) runs in that worktree, grouped under the task it belongs to,
/// so you do not have to go to each one. Only this repository's own folders are accepted.
struct RunChips: View {
    let text: String
    let session: SessionController
    @State private var target: TerminalTarget?

    /// The folders a command may name: this session's, and those of the repository's other sessions (their worktrees).
    private var allowed: Set<String> {
        let ws = Workspace.shared
        let mine = ws.sessions.filter { $0.cwd == session.meta.cwd && $0.environment == session.meta.environment }
        return Set(mine.flatMap { [$0.worktree, $0.cwd].compactMap { $0 } } + [session.meta.workingDirectory, session.meta.cwd])
    }

    /// What to call a folder: the session working in it, or the folder's own name.
    private func name(_ dir: String) -> String {
        Workspace.shared.sessions.first { $0.worktree == dir }?.title ?? URL(fileURLWithPath: dir).lastPathComponent
    }

    private func chip(_ c: RunnableCommand) -> some View {
        let t = TerminalTarget(command: c.command, directory: c.directory ?? session.meta.workingDirectory, env: session.env)
        return Button { target = t } label: {
            HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text(RunnableCommands.shellLine(c.command)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1) }
                .padding(.horizontal, 9).padding(.vertical, 4).background(Theme.fill, in: Capsule())
        }.buttonStyle(.soft).foregroundStyle(Theme.accent)
        .help(c.directory == nil ? "Run in a terminal in this session's folder" : "Run in a terminal in \(name(t.directory))")
        .contextMenu { if TerminalLaunch.ghosttyInstalled { Button("Run in Ghostty") { Task { _ = try? await Shell.run("/usr/bin/open", TerminalLaunch.ghosttyOpenArgs(directory: t.directory, command: t.command, env: t.env)) } } } }
    }

    var body: some View {
        let cmds = RunnableCommands.find(in: text, allowedDirectories: allowed)
        if !cmds.isEmpty {
            let here = cmds.filter { $0.directory == nil }
            let folders = cmds.compactMap(\.directory).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            VStack(alignment: .leading, spacing: 8) {
                if !here.isEmpty { FlowLayout(spacing: 6) { ForEach(here) { chip($0) } } }
                ForEach(folders, id: \.self) { dir in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(name(dir)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                            Button("Open here") { target = TerminalTarget(command: "git status", directory: dir, env: session.env) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                                .help(dir)
                        }
                        FlowLayout(spacing: 6) { ForEach(cmds.filter { $0.directory == dir }) { chip($0) } }
                    }
                }
            }.sheet(item: $target) { TerminalSheet(target: $0) }
        }
    }
}

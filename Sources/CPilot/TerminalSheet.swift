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

/// Offers the commands a reply tells you to run. Nothing runs until you press one.
struct RunChips: View {
    let text: String
    let session: SessionController
    @State private var target: TerminalTarget?

    var body: some View {
        let cmds = RunnableCommands.find(in: text)
        if !cmds.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(cmds) { c in
                    let t = TerminalTarget(command: c.command, directory: session.meta.workingDirectory, env: session.env)
                    Button { target = t } label: {
                        HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text(RunnableCommands.shellLine(c.command)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1) }
                            .padding(.horizontal, 9).padding(.vertical, 4).background(Theme.fill, in: Capsule())
                    }.buttonStyle(.soft).foregroundStyle(Theme.accent)
                    .help("Run in a terminal in this session's folder")
                    .contextMenu { if TerminalLaunch.ghosttyInstalled { Button("Run in Ghostty") { Task { _ = try? await Shell.run("/usr/bin/open", TerminalLaunch.ghosttyOpenArgs(directory: t.directory, command: t.command, env: t.env)) } } } }
                }
            }.sheet(item: $target) { TerminalSheet(target: $0) }
        }
    }
}

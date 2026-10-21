// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

/// What agents may do, per project, and a log of every approval.
struct AccessSettings: View {
    let ws = Workspace.shared
    @State private var log: [AuditEntry] = []
    @State private var newPath = ""

    var body: some View {
        @Bindable var w = ws
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup("Default access") {
                SettingRow("For new sessions", "What an agent may do without asking you.") {
                    Segmented(options: AccessLevel.allCases.map { ($0, $0.label) }, selection: Binding(get: { w.policy.defaultLevel }, set: { w.policy.defaultLevel = $0; w.savePolicy() }))
                }
                SettingRow(w.policy.defaultLevel.label, w.policy.defaultLevel.detail) { EmptyView() }
                SettingRow("Ask outside the project folder", "Anything outside the session's folder asks first, whatever the level above.") {
                    toggle(Binding(get: { w.policy.askOutsideProject }, set: { w.policy.askOutsideProject = $0; w.savePolicy() }))
                }
                SettingRow("Touch ID for Full access", "Turning on Full access asks for your fingerprint or password, so an agent can never grant itself more.") {
                    toggle(Binding(get: { w.policy.requireTouchIDForFullAccess }, set: { w.policy.requireTouchIDForFullAccess = $0; w.savePolicy() }))
                }
            }
            SettingsGroup("Project rules") {
                if w.policy.rules.isEmpty { SettingRow("No project rules yet", "Choose \"Always in this project\" on an approval card, or add a folder here.") { EmptyView() } }
                ForEach(w.policy.rules) { rule in RuleRow(rule: rule) }
                SettingRow("Add a project folder", nil) {
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url, !w.policy.rules.contains(where: { $0.path == u.path }) { w.policy.rules.append(AccessRule(path: u.path)); w.savePolicy() }
                    }.buttonStyle(Pill(kind: .plain))
                }
            }
            SettingsGroup("Approvals") {
                if log.isEmpty { SettingRow("Nothing yet", "Every approval and denial is listed here.") { EmptyView() } }
                ForEach(log.prefix(12)) { e in
                    SettingRow("\(e.tool): \(e.summary)", e.ts.formatted(date: .abbreviated, time: .shortened)) { Badge(text: e.outcome, kind: e.outcome.hasPrefix("denied") ? .warn : .ok) }
                }
                SettingRow("Revoke everything", "Forgets all project command rules. Sessions ask again from now on.") {
                    Button("Revoke") { for i in w.policy.rules.indices { w.policy.rules[i].allowCommands = [] }; w.savePolicy() }.buttonStyle(Pill(kind: .danger))
                }
            }
        }.onAppear { log = ws.audit.recent(40) }
    }
}

struct RuleRow: View {
    let rule: AccessRule
    let ws = Workspace.shared
    var body: some View {
        let i = ws.policy.rules.firstIndex(where: { $0.id == rule.id })
        SettingRow(rule.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                   rule.allowCommands.isEmpty ? "No always-allowed commands" : "Always allowed: " + rule.allowCommands.joined(separator: ", ")) {
            HStack(spacing: 6) {
                Menu(rule.level?.label ?? "Default") {
                    Button("Default") { set { $0.level = nil } }
                    ForEach(AccessLevel.allCases.filter { $0 != .fullAccess }) { l in Button(l.label) { set { $0.level = l } } }
                }.menuStyle(.borderlessButton).fixedSize()
                Button { if let i { ws.policy.rules.remove(at: i); ws.savePolicy() } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove rule").accessibilityLabel("Remove rule")
            }
        }
    }
    private func set(_ f: (inout AccessRule) -> Void) {
        if let i = ws.policy.rules.firstIndex(where: { $0.id == rule.id }) { f(&ws.policy.rules[i]); ws.savePolicy() }
    }
}

/// GitHub connection and the command line tools CPilot uses.
struct GitHubSettings: View {
    let model = AppModel.shared
    @State private var installing = false
    @State private var cliMessage: String?

    var body: some View {
        @Bindable var p = Prefs.shared
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup("GitHub account") {
                if let a = model.github {
                    SettingRow("Signed in as \(a.login)", "CPilot uses your GitHub command line login. It stores no token of its own.") { Badge(text: "Connected", kind: .ok) }
                    if !a.scopes.isEmpty { SettingRow("Permissions", a.scopes) { EmptyView() } }
                    SettingRow("Switch or sign out", "Opens Terminal's command to manage accounts.") { CopyButton(text: "gh auth switch", label: "Copy: gh auth switch") }
                } else {
                    SettingRow("Not connected", "Pull requests, cloning and repo setup need GitHub. Run this once in Terminal.") { CopyButton(text: "gh auth login", label: "Copy: gh auth login") }
                    SettingRow("Check again", nil) { Button("Check") { Task { await model.refresh() } }.buttonStyle(Pill(kind: .plain)) }
                }
            }
            SettingsGroup("Pull requests") {
                SettingRow("Scan every PR for security problems", "Runs before CPilot will merge. Proven issues block the merge; unconfirmed leads never do.") { toggle($p.securityScanOnPR) }
                SettingRow("Local model for the deep scan", "Where your local model server answers (mlxplayer uses \(SecurityCage.defaultModelURL)). No API key is needed. With it and Docker or Colima running, findings are proven in a sandbox.") {
                    TextField(SecurityCage.defaultModelURL, text: $p.localModelURL).textFieldStyle(CPField()).frame(width: 220)
                }
                SettingRow("SecurityCage folder", SecurityCage.locate(configured: Prefs.shared.securityCagePath).map { "Found: " + $0.replacingOccurrences(of: "/packages/cli/src/cli.ts", with: "") } ?? SecurityCage.setupHint) {
                    Button("Choose…") {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false
                        if o.runModal() == .OK, let u = o.url { Prefs.shared.securityCagePath = u.path }
                    }.buttonStyle(Pill(kind: .plain))
                }
            }
            SettingsGroup("Folders and tools") {
                SettingRow("Clone repositories into", Prefs.shared.cloneFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Change…") {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false; o.canCreateDirectories = true
                        if o.runModal() == .OK, let u = o.url { Prefs.shared.cloneFolder = u.path }
                    }.buttonStyle(Pill(kind: .plain))
                }
                SettingRow("Command line tools", toolSummary) { EmptyView() }
                SettingRow("Install the cpilot command", cliMessage ?? "Lets you run cpilot new . in Terminal to start a session in the current folder.") {
                    Button(CLIInstaller.installed ? "Reinstall" : "Install") { cliMessage = CLIInstaller.install() }.buttonStyle(Pill(kind: .plain))
                }
            }
        }
    }

    private var toolSummary: String {
        ["git", "gh", "claude", "node", "docker"].map { "\($0) \(Shell.find($0) == nil ? "missing" : "found")" }.joined(separator: " · ")
    }
}

/// Installs a small `cpilot` launcher so sessions can be started from Terminal.
enum CLIInstaller {
    static let path = NSHomeDirectory() + "/.local/bin/cpilot"
    static var installed: Bool { FileManager.default.fileExists(atPath: path) }

    static func install() -> String {
        let script = """
        #!/bin/sh
        # Starts a CPilot session in a folder: cpilot new [folder]
        case "$1" in
          new) dir="${2:-.}"; dir="$(cd "$dir" && pwd)"; open "cpilot://new?folder=$(printf %s "$dir" | sed 's/ /%20/g')" ;;
          *) open -a CPilot ;;
        esac
        """
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").contains(".local/bin")
            return "Installed to ~/.local/bin/cpilot." + (onPath ? "" : " Add ~/.local/bin to your PATH to use it.")
        } catch { return "Could not install: \(error.localizedDescription)" }
    }
}

/// Which agents CPilot can drive, and how other tools connect to CPilot.
struct AgentSettings: View {
    let ws = Workspace.shared
    @State private var registry: [RegistryAgent] = []
    @State private var loadingRegistry = false
    @State private var showRegistry = false
    @State private var custom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup("Agents CPilot can run") {
                SettingRow("Claude", Shell.find("claude").map { "Command line found at \($0). Sessions resume by id with full context." } ?? "Not found. Install the Claude command line first.") {
                    Badge(text: Shell.find("claude") == nil ? "Missing" : "Ready", kind: Shell.find("claude") == nil ? .warn : .ok)
                }
                ForEach(ws.acpAgents) { a in
                    SettingRow(a.name, ([a.command] + a.args).joined(separator: " ")) {
                        Button { ws.acpAgents.removeAll { $0.id == a.id }; ws.saveAgents() } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(a.name)").accessibilityLabel("Remove \(a.name)")
                    }
                }
                SettingRow("Add an agent", "Any agent that speaks the Agent Client Protocol. Pick one from the official list, or enter a command.") {
                    HStack(spacing: 6) {
                        Button("Browse list…") { showRegistry = true; load() }.buttonStyle(Pill(kind: .primary))
                        Button("Custom…") { custom = true }.buttonStyle(Pill(kind: .plain))
                    }
                }
            }
            SettingsGroup("Let other tools use CPilot") {
                SettingRow("Built-in MCP server", "Other apps can list your sessions, read results and start new ones. Anything that changes your computer asks you first.") { EmptyView() }
            }
            AgentsView()
        }
        .sheet(isPresented: $showRegistry) { registrySheet }
        .sheet(isPresented: $custom) { CustomAgentSheet() }
    }

    private func load() {
        guard registry.isEmpty else { return }
        loadingRegistry = true
        Task { registry = await AcpRegistry.load(); loadingRegistry = false }
    }

    private var registrySheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent registry").font(.system(size: 15, weight: .semibold))
            Text("From the official ACP registry. Agents that run through npx or uvx can be added in one click; they download on first use.").font(.system(size: 12)).foregroundStyle(.secondary)
            if loadingRegistry { ProgressView().controlSize(.small) }
            List(registry) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(a.name).font(.system(size: 13, weight: .medium)); Text(a.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    if let c = a.config {
                        if ws.acpAgents.contains(where: { $0.id == a.id }) { Badge(text: "Added", kind: .ok) }
                        else if Shell.find(c.command) == nil { Badge(text: "Needs \(a.needsRuntime ?? c.command)", kind: .warn) }
                        else { Button("Add") { ws.acpAgents.append(c); ws.saveAgents() }.buttonStyle(Pill(kind: .primary)) }
                    } else { Badge(text: "Manual install") }
                }
            }.frame(height: 360)
            HStack { Spacer(); Button("Done") { showRegistry = false }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.defaultAction) }
        }.padding(18).frame(width: 520)
    }
}

struct CustomAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var args = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an agent by command").font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $name).textFieldStyle(CPField())
            TextField("Command, for example npx", text: $command).textFieldStyle(CPField())
            TextField("Arguments, for example -y some-agent --acp", text: $args).textFieldStyle(CPField())
            Text("The command must speak ACP over standard input and output.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Add") {
                    let id = name.lowercased().filter { $0.isLetter || $0.isNumber }
                    Workspace.shared.acpAgents.append(AcpAgentConfig(id: id.isEmpty ? UUID().uuidString : id, name: name, command: command, args: args.split(separator: " ").map(String.init)))
                    Workspace.shared.saveAgents(); dismiss()
                }.buttonStyle(Pill(kind: .primary)).disabled(name.isEmpty || command.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 440)
    }
}

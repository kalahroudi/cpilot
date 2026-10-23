// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }

/// One approval: a plain headline, with the full command behind a "Details" toggle.
struct ApprovalRow: View {
    let entry: AuditEntry
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(entry.headline, entry.ts.formatted(date: .abbreviated, time: .shortened), separator: false) {
                HStack(spacing: 8) {
                    Badge(text: entry.outcome, kind: entry.outcome.hasPrefix("denied") ? .warn : .ok)
                    if entry.summary.count > entry.headline.count {
                        Button(open ? "Hide details" : "Details") { open.toggle() }.buttonStyle(.soft).foregroundStyle(.secondary)
                    }
                }
            }
            if open {
                Text(entry.summary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            Divider()
        }
    }
}

/// What agents may do, per project, and a log of every approval.
struct AccessSettings: View {
    let ws = Workspace.shared
    @State private var log: [AuditEntry] = []
    @State private var newPath = ""
    @State private var showAllApprovals = false

    var body: some View {
        @Bindable var w = ws
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Default access") {
                SettingRow("For new sessions", "What an agent may do without asking you. \(w.policy.defaultLevel.label): \(w.policy.defaultLevel.detail)") {
                    Segmented(options: AccessLevel.allCases.map { ($0, $0.label) }, selection: Binding(get: { w.policy.defaultLevel }, set: { w.policy.defaultLevel = $0; w.savePolicy() }))
                }
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
            if let repos = w.policy.specFullAccessRepos {
                SettingsGroup("Spec sessions with Full access") {
                    ForEach(repos, id: \.self) { r in
                        SettingRow(r.replacingOccurrences(of: NSHomeDirectory(), with: "~"), "Task sessions started from specs here begin with no approval prompts. Each session can still be changed from its own header.") {
                            Button("Turn off") { w.setSpecFullAccess(false, repo: r) }.buttonStyle(Pill(kind: .danger))
                        }
                    }
                }
            }
            SettingsGroup("Approvals") {
                if log.isEmpty { SettingRow("Nothing yet", "Every approval and denial is listed here.") { EmptyView() } }
                ForEach(log.prefix(showAllApprovals ? 40 : 5)) { e in ApprovalRow(entry: e) }
                if log.count > 5 { SettingRow(showAllApprovals ? "Showing the latest \(min(log.count, 40))" : "Showing the latest 5 of \(log.count)", nil) { Button(showAllApprovals ? "Show fewer" : "Show more") { showAllApprovals.toggle() }.buttonStyle(Pill(kind: .plain)) } }
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
                    .buttonStyle(.soft).foregroundStyle(.secondary).help("Remove rule").accessibilityLabel("Remove rule")
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
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("GitHub account") {
                if let a = model.github {
                    SettingRow("Signed in as \(a.login)", "CPilot uses your GitHub command line login. It stores no token of its own.") { Badge(text: "Connected", kind: .ok) }
                    if !a.scopes.isEmpty { SettingRow("Permissions", a.scopes) { EmptyView() } }
                    SettingRow("Switch or sign out", "Opens Terminal's command to manage accounts.") { CopyButton(text: "gh auth switch", label: "Copy: gh auth switch") }
                } else {
                    SettingRow("Not connected", "Pull requests, cloning and repo setup need GitHub. Run this once in Terminal.") { CopyButton(text: "gh auth login", label: "Copy: gh auth login") }
                    SettingRow("Check again", nil) { AsyncButton("Check") { await model.refresh() }.buttonStyle(Pill(kind: .plain)) }
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
    @State private var installing: String?
    @State private var installNotes: [String: String] = [:]
    /// Test results by agent ("claude" for Claude), then by place ("" for this Mac, else the server's id). A nil result is still running.
    @State private var tests: [String: [String: AgentCheck.Result?]] = [:]

    /// Places (agent and place, joined) where a sign-in is waiting on you.
    @State private var signingIn: Set<String> = []
    @State private var claudeSignIn: EnvironmentConfig?
    @State private var agySignIn: AgyTarget?

    /// Runs the agent's own sign-in in one place, then shows the new result.
    private func signIn(_ agent: AcpAgentConfig, place: EnvironmentConfig?) {
        let key = agent.id, pid = place?.id ?? ""
        tests[key]?[pid] = .some(nil); signingIn.insert(key + "|" + pid)
        Task {
            let r = await AgentCheck.signIn(agent, on: place)
            signingIn.remove(key + "|" + pid)
            tests[key]?[pid] = .some(r)
        }
    }

    /// Installs what is missing on the server, then tests again there.
    private func setUp(_ agent: AcpAgentConfig?, on env: EnvironmentConfig) {
        let key = agent?.id ?? "claude"
        tests[key]?[env.id] = .some(nil)
        Task {
            await EnvironmentCenter.shared.run(env, retry: true)
            tests[key]?[env.id] = .some(await AgentCheck.run(agent, on: ws.environment(env.id) ?? env))
        }
    }

    /// Installs agy and its adapter on this Mac, then tests again.
    private func setUpHere(_ agent: AcpAgentConfig) {
        tests[agent.id]?[""] = .some(nil)
        Task {
            do { try await AgyAdapter.install(on: nil) { _ in } } catch { tests[agent.id]?[""] = .some(AgentCheck.Result(state: .failed, detail: error.localizedDescription)); return }
            tests[agent.id]?[""] = .some(await AgentCheck.run(agent, on: nil))
        }
    }

    /// Starts the agent on this Mac and on every server, for real, and records what happened. Never starts a sign-in.
    private func test(_ agent: AcpAgentConfig?) {
        let key = agent?.id ?? "claude"
        guard tests[key]?.values.contains(where: { $0 == nil }) != true else { return }
        let places: [EnvironmentConfig?] = [nil] + ws.environments.map { Optional($0) }
        tests[key] = Dictionary(uniqueKeysWithValues: places.map { ($0?.id ?? "", nil as AgentCheck.Result?) })
        for place in places {
            Task {
                let r = await AgentCheck.run(agent, on: place)
                tests[key]?[place?.id ?? ""] = .some(r)
            }
        }
    }

    private func testButton(_ agent: AcpAgentConfig?) -> some View {
        let running = tests[agent?.id ?? "claude"]?.values.contains(where: { $0 == nil }) == true
        return Button { test(agent) } label: { if running { ProgressView().controlSize(.small) } else { Text("Test") } }
            .buttonStyle(Pill(kind: .plain)).disabled(running).help("Start it here and on every server, and check it is signed in")
    }

    /// One line per place the agent was tested.
    @ViewBuilder private func testResults(_ agent: AcpAgentConfig?) -> some View {
        if let results = tests[agent?.id ?? "claude"] {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(results.keys.sorted { $0.isEmpty ? true : ($1.isEmpty ? false : $0 < $1) }, id: \.self) { place in
                    let r = results[place] ?? nil
                    HStack(alignment: .top, spacing: 8) {
                        switch r?.state {
                        case nil: ProgressView().controlSize(.mini).frame(width: 14)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).frame(width: 14)
                        default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.isEmpty ? "This Mac" : (ws.environment(place)?.name ?? place)).font(.system(size: 12, weight: .medium))
                            Text(r?.detail ?? (signingIn.contains((agent?.id ?? "claude") + "|" + place) ? "Waiting for you to finish signing in, in the browser that opened…" : "Working…")).font(.system(size: 11.5)).foregroundStyle(r == nil || r?.state == .ok ? .secondary : Theme.warn).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            testAction(agent, place: place, state: r?.state)
                        }
                    }
                }
            }.padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    /// What to do about a result that is not ok: sign in, or set the server up.
    @ViewBuilder private func testAction(_ agent: AcpAgentConfig?, place: String, state: AgentCheck.Result.State?) -> some View {
        let env = place.isEmpty ? nil : ws.environment(place)
        switch state {
        case .needsSignIn:
            if let agent, agent.id == AgyAdapter.agentId { Button("Sign in…") { agySignIn = AgyTarget(env: env) }.buttonStyle(Pill(kind: .primary)) }
            else if let agent { Button("Sign in…") { signIn(agent, place: env) }.buttonStyle(Pill(kind: .primary)) }
            else if let env { Button("Sign in…") { claudeSignIn = env }.buttonStyle(Pill(kind: .primary)) }
            else { Text("Run claude in Terminal once to sign in.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        case .notSetUp:
            if let env { Button("Set up on \(env.name)") { setUp(agent, on: env) }.buttonStyle(Pill(kind: .primary)) }
            else if let agent, agent.id == AgyAdapter.agentId { Button("Set up on this Mac") { setUpHere(agent) }.buttonStyle(Pill(kind: .primary)) }
        default: EmptyView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Agents CPilot can run") {
                SettingRow("Claude", Shell.find("claude").map { "Command line found at \($0). Sessions resume by id with full context." } ?? "Not found. Install the Claude command line first.") {
                    HStack(spacing: 8) {
                        Badge(text: Shell.find("claude") == nil ? "Missing" : "Ready", kind: Shell.find("claude") == nil ? .warn : .ok)
                        testButton(nil)
                    }
                }
                testResults(nil)
                ForEach(ws.acpAgents) { a in
                    SettingRow(a.name, ([a.command] + a.args).joined(separator: " ")) {
                        testButton(a)
                        Button { AgentInstaller.remove(a); ws.acpAgents.removeAll { $0.id == a.id }; ws.saveAgents() } label: { Image(systemName: "trash") }
                            .buttonStyle(.soft).foregroundStyle(.secondary).help("Remove \(a.name)").accessibilityLabel("Remove \(a.name)")
                    }
                    testResults(a)
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
        .sheet(item: $claudeSignIn, onDismiss: { test(nil) }) { e in ClaudeSignInSheet(env: e) }
        .sheet(item: $agySignIn, onDismiss: { if let a = ws.acpAgents.first(where: { $0.id == AgyAdapter.agentId }) { test(a) } }) { t in AgySignInSheet(env: t.env) }
    }

    private func load() {
        guard registry.isEmpty else { return }
        loadingRegistry = true
        Task { registry = await AcpRegistry.load(); loadingRegistry = false }
    }

    private var registrySheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent registry").font(.system(size: 15, weight: .semibold))
            Text("From the official ACP registry. Agents that run through npx or uvx are added in one click and download on first use. Native agents (Antigravity, Cursor, goose, OpenCode and others) are downloaded, checked against the registry's checksum and unpacked by CPilot.").font(.system(size: 12)).foregroundStyle(.secondary)
            if loadingRegistry { ProgressView().controlSize(.small) }
            List(registry) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(a.name).font(.system(size: 13, weight: .medium)); Text(a.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    if a.id == AgyAdapter.agentId, let c = a.config {
                        agyControl(a, c)
                    } else if let c = a.config {
                        if ws.acpAgents.contains(where: { $0.id == a.id }) { Badge(text: "Added", kind: .ok) }
                        else if Shell.find(c.command) == nil { Badge(text: "Needs \(a.needsRuntime ?? c.command)", kind: .warn) }
                        else { Button("Add") { ws.acpAgents.append(c); ws.saveAgents() }.buttonStyle(Pill(kind: .primary)) }
                    } else if a.binary != nil { binaryControl(a) }
                    else { Badge(text: "Not for this Mac") }
                }
            }.frame(height: 360)
            HStack { Spacer(); Button("Done") { showRegistry = false }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.defaultAction) }
        }.padding(18).frame(width: 520)
    }
}

extension AgentSettings {
    /// Install, update or show as added an agent that ships as a native download.
    @ViewBuilder func binaryControl(_ a: RegistryAgent) -> some View {
        let existing = ws.acpAgents.first { $0.id == a.id }
        let current = existing.flatMap { AgentInstaller.installedVersion(of: $0) }
        VStack(alignment: .trailing, spacing: 3) {
            if installing == a.id { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").font(.system(size: 11.5)).foregroundStyle(.secondary) } }
            else if existing != nil, current == a.version || current == nil { Badge(text: "Added", kind: .ok) }
            else { Button(existing == nil ? "Install" : "Update to \(a.version)") { install(a) }.buttonStyle(Pill(kind: .primary)).disabled(installing != nil) }
            if let note = installNotes[a.id] { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 220, alignment: .trailing) }
        }
    }

    /// Adds agy: it comes with Node.js, the agy command and CPilot's adapter, installed in ~/.cpilot on this Mac.
    @ViewBuilder func agyControl(_ a: RegistryAgent, _ c: AcpAgentConfig) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if installing == a.id { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(installNotes[a.id] ?? "Installing…").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) } }
            else if ws.acpAgents.contains(where: { $0.id == a.id }) { Badge(text: "Added", kind: .ok) }
            else { Button("Add") { addAgy(a, c) }.buttonStyle(Pill(kind: .primary)).disabled(installing != nil) }
            if installing != a.id, let note = installNotes[a.id] { Text(note).font(.system(size: 11)).foregroundStyle(Theme.warn).multilineTextAlignment(.trailing).frame(maxWidth: 220, alignment: .trailing) }
        }
    }

    private func addAgy(_ a: RegistryAgent, _ c: AcpAgentConfig) {
        installing = a.id; installNotes[a.id] = "Installing…"
        Task {
            do {
                try await AgyAdapter.install(on: nil) { line in Task { @MainActor in installNotes[a.id] = line } }
                ws.acpAgents.removeAll { $0.id == a.id }; ws.acpAgents.append(c); ws.saveAgents()
                installNotes[a.id] = nil
            } catch { installNotes[a.id] = error.localizedDescription }
            installing = nil
        }
    }

    private func install(_ a: RegistryAgent) {
        installing = a.id; installNotes[a.id] = nil
        Task {
            do {
                let done = try await AgentInstaller.install(a)
                ws.acpAgents.removeAll { $0.id == a.id }; ws.acpAgents.append(done.config); ws.saveAgents()
                installNotes[a.id] = done.verified ? "Checksum verified." : "The registry gives no checksum for this download."
            } catch { installNotes[a.id] = error.localizedDescription }
            installing = nil
        }
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

struct AgyTarget: Identifiable { let env: EnvironmentConfig?; var id: String { env?.id ?? "" } }

/// Signs agy in with a Google account: CPilot opens the link agy prints, you paste back the code the page shows.
struct AgySignInSheet: View {
    let env: EnvironmentConfig?
    @Environment(\.dismiss) private var dismiss
    @State private var login: AgyAdapter.Login?
    @State private var url: URL?
    @State private var code = ""
    @State private var starting = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Antigravity on \(env?.name ?? "this Mac")").font(.system(size: 16, weight: .semibold))
            if starting { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking agy for a sign-in link…").font(.system(size: 12)).foregroundStyle(.secondary) } }
            else if let url {
                Text("A browser tab opened. Sign in with your Google account, copy the code the page shows and paste it here.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open the link again") { NSWorkspace.shared.open(url) }.buttonStyle(.soft).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                TextField("Code from the page", text: $code).textFieldStyle(CPField()).onSubmit { Task { await submit() } }
            }
            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { login?.cancel(); dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                if error != nil && url == nil { Button("Try again") { Task { await begin() } }.buttonStyle(Pill(kind: .plain)) }
                if url != nil { AsyncButton { await submit() } label: { if busy { ProgressView().controlSize(.small) } else { Text("Finish") } }.buttonStyle(Pill(kind: .primary)).disabled(busy || code.isEmpty) }
            }
        }.padding(20).frame(width: 460)
        .task { await begin() }
        .onDisappear { login?.cancel() }
    }

    private func begin() async {
        starting = true; error = nil; url = nil; code = ""; defer { starting = false }
        login?.cancel()
        let l = AgyAdapter.Login(env); login = l
        do { let u = try await l.begin(); url = u; NSWorkspace.shared.open(u) } catch { self.error = error.localizedDescription }
    }

    private func submit() async {
        guard let login, !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await login.finish(code: code)
            AppModel.shared.show("Antigravity is signed in on \(env?.name ?? "this Mac")")
            dismiss()
        } catch {
            self.error = error.localizedDescription + " Start again to get a new link."
            url = nil
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Whether each server can be reached right now. Checked when the screen opens, never in the background.
@MainActor @Observable
final class EnvironmentCenter {
    static let shared = EnvironmentCenter()
    enum Status: Equatable { case checking, ok(EnvironmentReport), failed(String) }
    var status: [String: Status] = [:]

    func check(_ env: EnvironmentConfig) {
        status[env.id] = .checking
        Task {
            let (updated, report) = await EnvironmentProbe.connect(env)
            if report.connected {
                if let i = Workspace.shared.environments.firstIndex(where: { $0.id == env.id }) {
                    Workspace.shared.environments[i].active = updated.active; Workspace.shared.environments[i].home = updated.home
                    Workspace.shared.saveEnvironments()
                }
                status[env.id] = .ok(report)
            } else { status[env.id] = .failed(report.error ?? "Could not connect.") }
        }
    }

    func checkAll() { for e in Workspace.shared.environments { check(e) } }
}

struct EnvironmentsView: View {
    let ws = Workspace.shared
    let center = EnvironmentCenter.shared
    @State private var adding = false
    @State private var editing: EnvironmentConfig?
    @State private var editingServer: EnvironmentConfig?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Environments", subtitle: "A machine that owns the agents, files and git for its projects") {
                Button("Add environment") { adding = true }.buttonStyle(Pill(kind: .primary))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        row(icon: "laptopcomputer", title: "This Mac", detail: "\(count(ws.sessions.filter { $0.environment == nil }.count)) · agents: \(localAgents)") { Badge(text: "Connected", kind: .ok) }
                        ForEach(ws.environments) { e in Divider(); serverRow(e) }
                    }.background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it works").font(.system(size: 13, weight: .semibold))
                        Text("CPilot opens a secure shell to the server with your own SSH keys and runs the agent there. Files, git, pull requests and the security scan all run on the server, so they see the real checkout. Approvals and screen captures stay on this Mac. Turn on \"keep sessions running\" and a small helper keeps agents going when your connection drops.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(14).card(padding: 0)
                }.padding(22).frame(maxWidth: 820, alignment: .leading)
            }
        }
        .background(Theme.pane)
        .onAppear { if !AppModel.shared.demo { center.checkAll() } }
        .sheet(isPresented: $adding) { AddEnvironmentSheet() }
        .sheet(item: $editing) { e in RoutesSheet(env: e) }
        .sheet(item: $editingServer) { e in AddEnvironmentSheet(existing: e) }
    }

    private func count(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }

    private var localAgents: String { ["claude", "gh"].filter { Shell.find($0) != nil }.joined(separator: ", ") }

    private func row<T: View>(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 34, height: 34).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13.5, weight: .semibold)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            trailing()
        }.padding(14)
    }

    @ViewBuilder private func serverRow(_ e: EnvironmentConfig) -> some View {
        let st = center.status[e.id]
        VStack(alignment: .leading, spacing: 8) {
            row(icon: e.persistent ? "server.rack" : "terminal", title: e.name,
                detail: "SSH · \(e.target) · \(count(ws.sessions.filter { $0.environment == e.id }.count))" + (e.persistent ? " · keeps running while you are away" : "")) {
                HStack(spacing: 8) {
                    switch st {
                    case .checking, nil: ProgressView().controlSize(.small)
                    case .ok: Badge(text: "Connected", kind: .ok)
                    case .failed: Badge(text: "Offline", kind: .warn)
                    }
                    Button("Routes…") { editing = e }.buttonStyle(Pill(kind: .plain))
                    Menu {
                        Button("Edit…") { editingServer = e }
                        Button("Check again") { center.check(e) }
                        Button(e.persistent ? "Stop keeping sessions running" : "Keep sessions running while I am away") { toggle(e) }
                        Divider()
                        Button("Remove", role: .destructive) { SSHPassword.delete(e.id); ws.environments.removeAll { $0.id == e.id }; ws.saveEnvironments() }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            if case .failed(let msg) = st { Text(msg).font(.system(size: 12)).foregroundStyle(Theme.warn).padding(.horizontal, 60).padding(.bottom, 10) }
            if case .ok(let r) = st, !r.has("claude") { Text("Claude is not installed on this server, so Claude sessions cannot start there.").font(.system(size: 12)).foregroundStyle(Theme.warn).padding(.horizontal, 60).padding(.bottom, 10) }
        }
    }

    private func toggle(_ e: EnvironmentConfig) {
        guard let i = ws.environments.firstIndex(where: { $0.id == e.id }) else { return }
        if e.persistent { ws.environments[i].persistent = false; ws.saveEnvironments(); return }
        Task {
            do { try await Exec.with(e) { try await RemoteHost.install() }; ws.environments[i].persistent = true; ws.saveEnvironments(); AppModel.shared.show("Sessions on \(e.name) now keep running while you are away") }
            catch { AppModel.shared.failQuietly(error, action: "Install the helper") }
        }
    }
}

/// Reorder or add the addresses tried for a server. The first that answers is used; the rest are fallbacks.
struct RoutesSheet: View {
    @State var env: EnvironmentConfig
    @Environment(\.dismiss) private var dismiss
    @State private var newRoute = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routes to \(env.name)").font(.system(size: 16, weight: .semibold))
            Text("CPilot tries these in order and uses the first that answers. Add a Tailscale name as a fallback.").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Array(env.routes.enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("\(i + 1)").font(.system(size: 11)).frame(width: 20, height: 20).background(i == (env.active ?? 0) ? Theme.ok.opacity(0.2) : Theme.fill, in: Circle())
                    Text(r).font(.system(size: 12.5, design: .monospaced))
                    Spacer()
                    Button { if i > 0 { env.routes.swapAt(i, i - 1) } } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).disabled(i == 0)
                    Button { if env.routes.count > 1 { env.routes.remove(at: i) } } label: { Image(systemName: "trash") }.buttonStyle(.plain).disabled(env.routes.count < 2)
                }
            }
            HStack { TextField("user@host or Tailscale name", text: $newRoute).textFieldStyle(CPField()); Button("Add") { if !newRoute.isEmpty { env.routes.append(newRoute); newRoute = "" } }.buttonStyle(Pill(kind: .plain)) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = Workspace.shared.environments.firstIndex(where: { $0.id == env.id }) { env.active = 0; Workspace.shared.environments[i] = env; Workspace.shared.saveEnvironments(); EnvironmentCenter.shared.check(env) }
                    dismiss()
                }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}

struct AddEnvironmentSheet: View {
    var existing: EnvironmentConfig?
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var name = ""
    enum Auth: Hashable { case automatic, password, key }
    @State private var auth: Auth = .automatic
    @State private var password = ""
    @State private var key = ""
    @State private var draftId = UUID().uuidString
    @State private var folders = ""
    @State private var persistent = false
    @State private var checking = false
    @State private var report: EnvironmentReport?
    @State private var checked: EnvironmentConfig?
    @State private var busy = false
    @State private var error: String?
    private let hosts = SSH.configuredHosts()

    init(existing: EnvironmentConfig? = nil) {
        self.existing = existing
        guard let e = existing else { return }
        let t = e.routes.first ?? ""
        let parts = t.split(separator: "@", maxSplits: 1).map(String.init)
        _user = State(initialValue: parts.count == 2 ? parts[0] : "")
        _host = State(initialValue: parts.count == 2 ? parts[1] : t)
        _port = State(initialValue: e.port.map(String.init) ?? "")
        _name = State(initialValue: e.name)
        _auth = State(initialValue: e.usesPassword == true ? .password : ((e.identityFile ?? "").isEmpty ? .automatic : .key))
        _draftId = State(initialValue: e.id)
        _key = State(initialValue: e.identityFile ?? "")
        _folders = State(initialValue: e.folders.joined(separator: ", "))
        _persistent = State(initialValue: e.persistent)
    }

    /// What is passed to ssh: `user@host`, or just the host when no user is given.
    private var target: String {
        let h = host.trimmingCharacters(in: .whitespaces), u = user.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? h : "\(u)@\(h)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add environment" : "Edit \(existing!.name)").font(.system(size: 17, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Host")
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("node-1, node-1.local, an address or a Tailscale name", text: $host).textFieldStyle(CPField())
                            .onChange(of: host) { _, v in
                                report = nil
                                if v.contains("@") { let p = v.split(separator: "@", maxSplits: 1).map(String.init); if p.count == 2 { user = p[0]; host = p[1] } }
                            }
                        if !hosts.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(hosts, id: \.self) { h in
                                    Button { host = h; if name.isEmpty { name = h }; report = nil } label: { Badge(text: h, kind: h == host ? .accent : .neutral) }.buttonStyle(.plain)
                                }
                            }
                            Text("From your ~/.ssh/config").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    label("User")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("The account on the server, for example moram", text: $user).textFieldStyle(CPField()).onChange(of: user) { _, _ in report = nil }
                        Text("Leave empty to use your ssh config, or your Mac username.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label("Name")
                    TextField(host.isEmpty ? "How it appears in CPilot" : host, text: $name).textFieldStyle(CPField())
                }
                GridRow {
                    label("Port")
                    TextField("22", text: $port).textFieldStyle(CPField()).frame(width: 90)
                }
                GridRow {
                    label("Sign in with")
                    VStack(alignment: .leading, spacing: 6) {
                        Segmented(options: [(Auth.automatic, "Automatic"), (.password, "Password"), (.key, "Key file")], selection: $auth).onChange(of: auth) { _, _ in report = nil }
                        switch auth {
                        case .key:
                            HStack {
                                TextField("Path to a private key", text: $key).textFieldStyle(CPField())
                                Button("Choose…") { let p = NSOpenPanel(); p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh"); p.showsHiddenFiles = true; if p.runModal() == .OK { key = p.url?.path ?? "" } }.buttonStyle(Pill(kind: .plain))
                            }
                        case .password:
                            SecureField(existing?.usesPassword == true && SSHPassword.has(draftId) ? "Saved in your Keychain. Type to replace it." : "Password", text: $password).textFieldStyle(CPField()).onChange(of: password) { _, _ in report = nil }
                            Text("Kept in your macOS Keychain and given to SSH only when the server asks. Never written to a file.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        case .automatic:
                            Text("Uses your SSH agent, your ssh config and Tailscale SSH. No key file and no password prompt.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button { Task { await check() } } label: { if checking { ProgressView().controlSize(.small) } else { Text("Check connection") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                Text(target.isEmpty ? "" : "ssh \(target)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let r = report { reportView(r) }
            if let r = report, r.connected {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Folders on this server")
                    TextField("~/projects, ~/work  (comma separated)", text: $folders).textFieldStyle(CPField())
                    Toggle(isOn: $persistent) { Text("Keep sessions running while I am away").font(.system(size: 12.5)) }.toggleStyle(.switch).tint(Theme.accent)
                    Text(r.has("node") ? "Copies a small helper (one Node.js file, no network port) so agents survive a dropped connection."
                         : "Needs Node.js on the server. Install it there to turn this on.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if let error { ErrorLine(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { if existing == nil { SSHPassword.delete(draftId) }; dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { Task { await add() } } label: { if busy { ProgressView().controlSize(.small) } else { Text(existing == nil ? "Add \(name.isEmpty ? (host.isEmpty ? "server" : host) : name)" : "Save") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(busy || host.trimmingCharacters(in: .whitespaces).isEmpty || (existing == nil && report?.connected != true) || (persistent && report?.connected == true && report?.has("node") != true))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 580).fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    @ViewBuilder private func reportView(_ r: EnvironmentReport) -> some View {
        VStack(spacing: 0) {
            line("Connection", r.connected ? "Connected as \(target)" : (r.error ?? "Failed"), r.connected ? .ok : .warn)
            if r.connected {
                Divider(); line("Claude command line", r.tools["claude"] ?? "Not found. Sessions need it on the server.", r.has("claude") ? .ok : .warn)
                Divider(); line("Git", r.tools["git"] ?? "Not found", r.has("git") ? .ok : .warn)
                Divider(); line("GitHub command line", r.has("gh") ? (r.gitHubSignedIn ? "Signed in" : "Found. Run gh auth login on the server.") : "Not found. Needed for pull requests there.", r.gitHubSignedIn ? .ok : .warn)
                Divider(); line("Node.js", r.tools["node"] ?? "Not found. Needed only to keep sessions running.", r.has("node") ? .ok : .neutral)
                Divider(); line("Docker", r.tools["docker"] ?? "Not found. Only needed to prove security findings.", r.has("docker") ? .ok : .neutral)
            }
        }.background(Theme.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }

    private func line(_ t: String, _ d: String, _ k: Badge.Kind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) { Text(t).font(.system(size: 12.5, weight: .medium)); Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8); Badge(text: k == .ok ? "OK" : k == .warn ? "Needs you" : "Optional", kind: k)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func config() -> EnvironmentConfig {
        var e = existing ?? EnvironmentConfig(id: draftId, name: "", routes: [])
        e.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? host.trimmingCharacters(in: .whitespaces) : name.trimmingCharacters(in: .whitespaces)
        if e.routes.isEmpty { e.routes = [target] } else { e.routes[0] = target }
        e.port = Int(port); e.identityFile = auth == .key && !key.isEmpty ? key : nil; e.usesPassword = auth == .password ? true : nil
        e.folders = folders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        e.active = 0
        return e
    }

    private func check() async {
        checking = true; error = nil; defer { checking = false }
        if auth == .password, !password.isEmpty { SSHPassword.set(password, for: draftId) }
        if auth == .password, !SSHPassword.has(draftId) { report = EnvironmentReport(connected: false, error: "Enter the password first."); return }
        let (e, r) = await EnvironmentProbe.connect(config(), acceptNewHostKeys: true)
        checked = e; report = r
        if r.connected, folders.isEmpty, let h = r.home { folders = h + "/projects" }
    }

    private func add() async {
        busy = true; error = nil; defer { busy = false }
        if auth == .password, !password.isEmpty { SSHPassword.set(password, for: draftId) }
        if auth != .password { SSHPassword.delete(draftId) }
        var e = config(); e.home = report?.home ?? existing?.home
        e.persistent = existing?.persistent ?? false
        if persistent, !e.persistent {
            do { try await Exec.with(e) { try await RemoteHost.install() }; e.persistent = true }
            catch { self.error = AppModel.shared.capture(error, action: "Install the helper"); return }
        } else if !persistent { e.persistent = false }
        if let i = Workspace.shared.environments.firstIndex(where: { $0.id == e.id }) { Workspace.shared.environments[i] = e } else { Workspace.shared.environments.append(e) }
        Workspace.shared.saveEnvironments()
        EnvironmentCenter.shared.check(e)
        dismiss()
    }
}

/// Browse folders on a server, since the system file panel only sees this Mac.
struct RemoteFolderPicker: View {
    let env: EnvironmentConfig
    @State var path: String
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dirs: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a folder on \(env.name)").font(.system(size: 15, weight: .semibold))
            HStack {
                Button { path = (path as NSString).deletingLastPathComponent; load() } label: { Image(systemName: "chevron.up") }.buttonStyle(Pill(kind: .plain)).disabled(path == "/")
                Text(path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            List(dirs, id: \.self) { d in Button { path = path == "/" ? "/\(d)" : "\(path)/\(d)"; load() } label: { Label(d, systemImage: "folder") }.buttonStyle(.plain) }.frame(height: 240)
            if let error { ErrorLine(text: error) }
            HStack {
                if !env.folders.isEmpty { FlowLayout(spacing: 6) { ForEach(env.folders, id: \.self) { f in Button { path = f.replacingOccurrences(of: "~", with: env.remoteHome); load() } label: { Badge(text: f, kind: .accent) }.buttonStyle(.plain) } } }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Choose this folder") { onPick(path); dismiss() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 480).onAppear(perform: load)
    }

    private func load() {
        loading = true; error = nil
        let p = path
        Task {
            do {
                let out = try await Exec.with(env) { try await Shell.check("ls", ["-1Ap"], cwd: URL(fileURLWithPath: p), timeout: 20) }
                dirs = out.split(separator: "\n").map(String.init).filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }.filter { !$0.hasPrefix(".") }
            } catch { self.error = "Could not list this folder."; dirs = [] }
            loading = false
        }
    }
}

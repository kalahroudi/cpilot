// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

// MARK: Agents

/// Finds AI agents on this Mac and connects them to the cpilot MCP server with one click.
struct AgentsView: View {
    @State private var statuses: [AgentStatus] = []
    @State private var busy: AgentKind?
    @State private var restartHint: AgentKind?
    @State private var error: String?
    @State private var manual = false
    private let server = AgentIntegrations.serverPath()
    private var serverMissing: Bool { !FileManager.default.isExecutableFile(atPath: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let an AI agent use CPilot").font(.system(size: 15, weight: .semibold))
                    Text("Agents can start and stop the VM, manage containers, stacks, images and volumes, read logs and run commands in containers. Destructive tools need an explicit confirmation.").font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Rescan") { scan() }.buttonStyle(Pill())
            }
            if serverMissing {
                Label("The MCP server was not found at \(server). Move CPilot into Applications to connect agents.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(spacing: 0) {
                ForEach(statuses) { st in
                    row(st)
                    if st.id != statuses.last?.id { Divider() }
                }
                if statuses.isEmpty { SkeletonList(rows: 3) }
            }.padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
            if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
            if let k = restartHint { Label("Restart \(k.name) to load the new tools.", systemImage: "arrow.clockwise").font(.system(size: 12.5)).foregroundStyle(Theme.accent) }
            DisclosureGroup("Set up another agent manually", isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 12) {
                    snippet("Claude Code", "claude mcp add cpilot --scope user -- \"\(server)\"")
                    snippet("Any MCP client (JSON)", "{\n  \"mcpServers\": {\n    \"cpilot\": { \"command\": \"\(server)\" }\n  }\n}")
                }.padding(.top, 8)
            }.font(.system(size: 12.5))
            Text("The server talks over stdio and uses the same code as the app. It works whether or not CPilot is open.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720)
        .onAppear { scan() }
    }

    private func row(_ st: AgentStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(st.kind)).font(.system(size: 15)).frame(width: 26).foregroundStyle(st.detected ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { Text(st.kind.name).font(.system(size: 13, weight: .medium)); badge(st.state) }
                Text(detail(st)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if busy == st.kind { ProgressView().controlSize(.small) }
            else {
                switch st.state {
                case .notDetected: EmptyView()
                case .available: Button("Connect") { run(st.kind, install: true) }.buttonStyle(Pill(kind: .primary)).disabled(serverMissing || busy != nil)
                case .connected: Button("Disconnect") { run(st.kind, install: false) }.buttonStyle(Pill()).disabled(busy != nil)
                case .outdated:
                    HStack(spacing: 6) {
                        Button("Update") { run(st.kind, install: true) }.buttonStyle(Pill(kind: .primary)).disabled(serverMissing || busy != nil)
                        Button("Disconnect") { run(st.kind, install: false) }.buttonStyle(Pill()).disabled(busy != nil)
                    }
                }
            }
        }.padding(.vertical, 11)
    }

    @ViewBuilder private func badge(_ s: AgentStatus.State) -> some View {
        switch s {
        case .notDetected: Badge(text: "Not found")
        case .available: Badge(text: "Found", kind: .accent)
        case .connected: Badge(text: "Connected", kind: .ok)
        case .outdated: Badge(text: "Needs update", kind: .warn)
        }
    }

    private func detail(_ st: AgentStatus) -> String {
        switch st.state {
        case .notDetected: return "Not found on this Mac."
        case .available: return "Found. Not connected to cpilot yet."
        case .connected: return st.kind.needsRestart ? "Connected. Restart the app after changes." : "Connected. cpilot tools are available."
        case .outdated(let old): return "Points to \(old). Update it to use this copy of CPilot."
        }
    }

    private func icon(_ k: AgentKind) -> String {
        switch k {
        case .claudeCode, .geminiCLI, .codexCLI: "terminal"
        case .claudeDesktop: "bubble.left.and.text.bubble.right"
        case .cursor, .windsurf: "chevron.left.forwardslash.chevron.right"
        }
    }

    private func scan() { statuses = AgentIntegrations.scan(serverPath: server) }

    private func run(_ kind: AgentKind, install: Bool) {
        busy = kind; error = nil; restartHint = nil
        Task {
            do {
                if install { try await AgentIntegrations.install(kind, serverPath: server) } else { try await AgentIntegrations.remove(kind) }
                if install && kind.needsRestart { restartHint = kind }
                AppModel.shared.show(install ? "Connected \(kind.name)" : "Disconnected \(kind.name)")
            } catch { self.error = "\(kind.name): \(error.localizedDescription)" }
            scan(); busy = nil
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { SectionLabel(title); Spacer(); CopyButton(text: text, label: "Copy") }
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.88)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Theme.terminal, in: RoundedRectangle(cornerRadius: 10)).textSelection(.enabled)
        }
    }
}

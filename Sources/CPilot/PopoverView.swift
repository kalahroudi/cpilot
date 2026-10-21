// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// The menu bar popover: what needs you, what is running, and a way to start something. Fixed width, height from content.
/// Nothing runs while it is closed (AppDelegate drops the views on close).
struct PopoverView: View {
    let model = AppModel.shared
    let ws = Workspace.shared
    var openManager: (Pane) -> Void
    @State private var quick = ""

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.loadedOnce, model.needsSetup { SetupView(compact: true) }
            else if !model.loadedOnce { SkeletonList(rows: 3).frame(height: 110) }
            else { sessions; quickStart }
            if let task = model.runningTask { TaskStrip(task: task) }
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.pane)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setPopoverVisible(true) }
        .onDisappear { model.setPopoverVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 30)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("CPilot").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    StatusDot(color: ws.attention > 0 ? Theme.warn : ws.runningCount > 0 ? Theme.accent : Theme.ok)
                    Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { CaptureCoordinator.shared.capture(window: false) } label: { Label("Capture", systemImage: "viewfinder") }
                .buttonStyle(Pill(kind: .plain)).help("Capture part of the screen into the active session (⌃⌥⌘C)")
        }
    }

    private var sessions: some View {
        let rows = rowsToShow
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text("No sessions yet. Start one below.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().opacity(0.6) }
                SessionRow(meta: m) { ws.select(m.id); openManager(.sessions) }
            }
        }.background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    /// Sessions that need you first, then what is running, then the latest few. Never an unbounded list.
    private var rowsToShow: [SessionMeta] {
        let live = ws.live
        let attention = live.filter { !$0.pending.isEmpty }.map(\.meta)
        let running = live.filter { $0.isBusy && $0.pending.isEmpty }.map(\.meta)
        var out: [SessionMeta] = []
        for m in attention + running + ws.sessions where !out.contains(where: { $0.id == m.id }) { out.append(m) }
        return Array(out.prefix(5))
    }

    private var quickStart: some View {
        HStack(spacing: 8) {
            TextField("New session in \(URL(fileURLWithPath: lastFolder).lastPathComponent)…", text: $quick).textFieldStyle(CPField()).onSubmit(start)
            Button("Start", action: start).buttonStyle(Pill(kind: .primary)).disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var lastFolder: String { UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory() }

    private func start() {
        let text = quick.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        quick = ""
        let n = Workspace.NewSession(folder: lastFolder, access: ws.policy.defaultLevel, firstMessage: text)
        Task { _ = try? await ws.create(n); openManager(.sessions) }
    }

    private var footer: some View {
        HStack {
            Button("Open CPilot") { openManager(.sessions) }.buttonStyle(Pill(kind: .primary))
            Button("New session…") { Nav.shared.showNewSession = true; openManager(.sessions) }.buttonStyle(Pill(kind: .plain))
            Spacer()
            Button { openManager(.settings) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Quit CPilot").accessibilityLabel("Quit")
        }
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let open: () -> Void
    let ws = Workspace.shared

    var body: some View {
        let c = ws.controller(meta.id)
        Button(action: open) {
            HStack(spacing: 10) {
                dot(c?.state ?? .asleep)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle(c)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let c, !c.pending.isEmpty { Badge(text: "Review", kind: .warn) }
                else if c?.state == .asleep || c == nil { Text("Resume").font(.system(size: 11.5)).foregroundStyle(Theme.accent) }
            }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func subtitle(_ c: SessionController?) -> String {
        let who = meta.backend.kind == .claude ? "Claude" : "Agent"
        if let p = c?.pending.first { return "\(who) wants to \(p.request.tool == "Bash" ? "run" : "use") \(p.request.summary)" }
        switch c?.state {
        case .running: return "\(who) · working"
        default:
            if let h = meta.recapHeadline, !h.isEmpty { return h }
            return "\(who) · \(meta.project) · \(meta.updatedAt.formatted(.relative(presentation: .named)))"
        }
    }

    @ViewBuilder private func dot(_ s: SessionController.RunState) -> some View {
        switch s {
        case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        case .waiting, .reconnecting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
        case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
        case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
        case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

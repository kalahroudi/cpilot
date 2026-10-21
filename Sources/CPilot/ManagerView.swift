// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Panes of the Manager window. Named `Pane`, not `Section`: SwiftUI already has a `Section`.
/// RULE: a pane exists only if it has real content. No placeholder pages, no empty settings tabs.
enum Pane: String, CaseIterable, Identifiable {
    case overview, settings, help
    var id: String { rawValue }
    var title: String { switch self { case .overview: "Overview"; case .settings: "Settings"; case .help: "Help" } }
    var symbol: String { switch self { case .overview: "square.grid.2x2"; case .settings: "gearshape"; case .help: "questionmark.circle" } }
}

@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var pane: Pane = .overview
}

/// The Manager window: a fixed sidebar (collapsible to icons) and a main pane that uses the full width.
struct ManagerView: View {
    var agentsTab = false
    let model = AppModel.shared
    let nav = Nav.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider()
            ZStack {
                Theme.pane
                VStack(spacing: 0) {
                    if let t = model.runningTask { TaskBanner(task: t) }
                    detail
                }
            }
            .overlay(alignment: .bottom) { ToastView() }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { model.setManagerVisible(true) }
    }

    @ViewBuilder private var detail: some View {
        if !model.loadedOnce {
            SkeletonList(rows: 9).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)   // never show a half-loaded page
        } else if model.needsSetup && nav.pane != .settings && nav.pane != .help {
            SetupView().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 40)
        } else {
            switch nav.pane {
            case .overview: OverviewPane()
            case .settings: SettingsPane(initialTab: agentsTab ? .agents : .general)
            case .help: HelpPane()
            }
        }
    }
}

struct Sidebar: View {
    let nav = Nav.shared
    let prefs = Prefs.shared
    var collapsed: Bool { prefs.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { prefs.sidebarCollapsed.toggle() } } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(collapsed ? "Expand sidebar" : "Collapse to icons").accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
            }.padding(.top, 14).padding(.bottom, 12).padding(.horizontal, collapsed ? 0 : 6)
            ForEach([Pane.overview]) { item($0) }
            Spacer()
            ForEach([Pane.settings, .help]) { item($0) }
            if !collapsed {
                Text("App memory \(AppMemory.footprint)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .padding(.top, 20)   // room for the traffic lights
        .frame(width: collapsed ? 62 : 200)
        .background(Theme.sidebar)
    }

    private func item(_ p: Pane) -> some View {
        let on = nav.pane == p
        return Button { nav.pane = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol).font(.system(size: 14)).frame(width: 20)
                if !collapsed {
                    Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    if p == .settings, Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.85))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))   // whole row (incl. padding and empty space) is clickable, not just icon+text
        }
        .buttonStyle(.plain).help(p.title).accessibilityLabel(p.title)
    }
}

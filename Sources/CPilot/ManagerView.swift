// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Panes of the Manager window. Named `Pane`, not `Section`: SwiftUI already has a `Section`.
enum Pane: String, CaseIterable, Identifiable {
    case sessions, pulls, memory, skills, repo, settings, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: "Sessions"; case .pulls: "Pull requests"; case .memory: "Memory"; case .skills: "Skills"
        case .repo: "Repo setup"; case .settings: "Settings"; case .help: "Help"
        }
    }
    var symbol: String {
        switch self {
        case .sessions: "bubble.left.and.text.bubble.right"; case .pulls: "arrow.triangle.pull"; case .memory: "brain"; case .skills: "sparkles"
        case .repo: "shippingbox"; case .settings: "gearshape"; case .help: "questionmark.circle"
        }
    }
}

@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var pane: Pane = .sessions
    var showNewSession = false
}

/// The Manager window: a slim icon rail, then the pane. Sessions are tabs along the top and the chat fills the rest.
struct ManagerView: View {
    var agentsTab = false
    let model = AppModel.shared
    let nav = Nav.shared

    var body: some View {
        HStack(spacing: 0) {
            Rail()
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
        .sheet(isPresented: Bindable(nav).showNewSession) { NewSessionSheet() }
    }

    @ViewBuilder private var detail: some View {
        if !model.loadedOnce {
            SkeletonList(rows: 9).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)
        } else if model.needsSetup && nav.pane != .settings && nav.pane != .help {
            SetupView().padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 40)
        } else {
            switch nav.pane {
            case .sessions: SessionsPane()
            case .pulls: PullRequestsView()
            case .memory: MemoryView()
            case .skills: SkillsView()
            case .repo: RepoSetupView()
            case .settings: SettingsPane(initialTab: agentsTab ? .agents : .general)
            case .help: HelpPane()
            }
        }
    }
}

struct Rail: View {
    let nav = Nav.shared
    let ws = Workspace.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach([Pane.sessions, .pulls, .memory, .skills, .repo]) { item($0) }
            Spacer()
            ForEach([Pane.settings, .help]) { item($0) }
            Text(AppMemory.footprint.replacingOccurrences(of: " MB", with: "")).font(.system(size: 9)).foregroundStyle(.secondary).help("CPilot memory use, in MB")
        }
        .padding(.top, 38).padding(.bottom, 10).padding(.horizontal, 8)
        .frame(width: 56)
        .background(Theme.sidebar)
    }

    private func item(_ p: Pane) -> some View {
        let on = nav.pane == p
        return Button { nav.pane = p } label: {
            Image(systemName: p.symbol).font(.system(size: 15))
                .frame(width: 38, height: 34)
                .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.75))
                .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { badge(p) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(p.title).accessibilityLabel(p.title)
    }

    @ViewBuilder private func badge(_ p: Pane) -> some View {
        if p == .sessions, ws.attention > 0 { Circle().fill(Theme.warn).frame(width: 8, height: 8).offset(x: -2, y: 3) }
        if p == .settings, Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: -2, y: 3) }
    }
}

/// Session tabs across the top; the selected session's chat below. Only the selected tab has a live view.
struct SessionsPane: View {
    let ws = Workspace.shared
    let nav = Nav.shared

    var body: some View {
        if Prefs.shared.tabsOnSide {
            HStack(spacing: 0) {
                SessionSidebar()
                Divider()
                content
            }
        } else {
            VStack(spacing: 0) { TabStrip(); content }
        }
    }

    @ViewBuilder private var content: some View {
        if let s = ws.current { ChatView(session: s).id(s.id) } else { Welcome() }
    }
}

/// Sessions as a list down the left, grouped by project. Same data as the tabs; pick whichever suits how you work.
struct SessionSidebar: View {
    let ws = Workspace.shared
    let nav = Nav.shared
    @State private var query = ""

    private var groups: [(String, [SessionMeta])] {
        let list = ws.sessions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        return Dictionary(grouping: list, by: \.project).map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.1.first?.updatedAt ?? .distantPast) > ($1.1.first?.updatedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { nav.showNewSession = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("New session (⌘N)").accessibilityLabel("New session")
            }.padding(.horizontal, 12).padding(.top, 36).padding(.bottom, 8)
            SearchBox(prompt: "Search", text: $query).padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { project, metas in
                        SectionLabel(project).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                        ForEach(metas) { m in SideRow(meta: m, selected: ws.selected == m.id) }
                    }
                }.padding(.horizontal, 6)
            }
        }
        .frame(width: 220).background(Theme.sidebar.opacity(0.55))
    }
}

struct SideRow: View {
    let meta: SessionMeta
    let selected: Bool
    let ws = Workspace.shared
    var body: some View {
        let c = ws.controller(meta.id)
        Button { ws.select(meta.id) } label: {
            HStack(spacing: 8) {
                switch c?.state ?? .asleep {
                case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                case .waiting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
                case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
                case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
                case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                }
                Text((meta.parentId != nil ? "↳ " : "") + meta.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(selected ? Theme.accent : Color.primary).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            if ws.tabs.contains(meta.id) { Button("Close") { ws.closeTab(meta.id) } }
            Button("Archive") { var m = meta; m.archived = true; ws.save(m); ws.closeTab(meta.id); ws.sessions.removeAll { $0.id == meta.id } }
            Button("Delete…", role: .destructive) { ws.delete(meta.id) }
        }
    }
}

struct TabStrip: View {
    let ws = Workspace.shared
    let nav = Nav.shared

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(ws.tabs, id: \.self) { id in
                        if let c = ws.controller(id) { TabButton(session: c, selected: ws.selected == id) }
                    }
                }
            }
            Button { nav.showNewSession = true } label: { Image(systemName: "plus").font(.system(size: 13)).frame(width: 28, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New session (⌘N)").accessibilityLabel("New session")
            Menu {
                ForEach(ws.sessions.prefix(15)) { m in Button(m.title) { ws.select(m.id) } }
            } label: { Image(systemName: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).fixedSize().help("Earlier sessions")
        }
        .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 0)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabButton: View {
    let session: SessionController
    let selected: Bool
    let ws = Workspace.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            dot
            Text((session.meta.parentId != nil ? "↳ " : "") + session.meta.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Button { ws.closeTab(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(selected || hover ? 1 : 0).accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 200)
        .foregroundStyle(selected ? Color.primary : .secondary)
        .background(selected ? Theme.pane : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).stroke(selected ? Theme.hairline : .clear))
        .offset(y: selected ? 1 : 0)
        .opacity(session.state == .asleep && !selected ? 0.75 : 1)
        .onHover { hover = $0 }
        .onTapGesture { ws.select(session.id) }
        .contextMenu {
            Button("Close tab") { ws.closeTab(session.id) }
            Button("Archive session") { var m = session.meta; m.archived = true; ws.save(m); ws.closeTab(session.id) }
            Button("Delete session…", role: .destructive) { ws.delete(session.id) }
        }
    }

    @ViewBuilder private var dot: some View {
        switch session.state {
        case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        case .waiting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
        case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
        case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
        case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

struct Welcome: View {
    let ws = Workspace.shared
    let nav = Nav.shared
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: AppIcon.image(size: 64)).resizable().frame(width: 64, height: 64)
            Text("Start a session").font(.system(size: 20, weight: .semibold))
            Text("Pick a folder, an agent and how much it may do. Everything resumes later with its context.").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("New session") { nav.showNewSession = true }.buttonStyle(Pill(kind: .primary)).keyboardShortcut("n", modifiers: .command)
            if !ws.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Recent").padding(.bottom, 6)
                    ForEach(ws.sessions.prefix(5)) { m in
                        Button { ws.select(m.id) } label: {
                            HStack { Text(m.title).lineLimit(1); Spacer(); Text(m.project).foregroundStyle(.secondary) }.font(.system(size: 12.5)).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider().opacity(0.5)
                    }
                }.frame(width: 380).padding(.top, 10)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

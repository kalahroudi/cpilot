// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Panes of the Manager window. Named `Pane`, not `Section`: SwiftUI already has a `Section`.
enum Pane: String, CaseIterable, Identifiable {
    case sessions, pulls, stacks, specs, memory, skills, repo, remote, settings, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: "Sessions"; case .pulls: "Pull requests"; case .stacks: "Stacks"; case .specs: "Specs"; case .memory: "Memory"; case .skills: "Skills"
        case .repo: "Repo setup"; case .remote: "Environments"; case .settings: "Settings"; case .help: "Help"
        }
    }
    var symbol: String {
        switch self {
        case .sessions: "bubble.left.and.text.bubble.right"; case .pulls: "arrow.triangle.pull"; case .stacks: "square.stack.3d.up"; case .specs: "doc.text.magnifyingglass"; case .memory: "brain"; case .skills: "sparkles"
        case .repo: "shippingbox"; case .remote: "server.rack"; case .settings: "gearshape"; case .help: "questionmark.circle"
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
        .sheet(item: Bindable(model).errorReport) { ErrorReportSheet(report: $0) }
        .alert("Delete this session?", isPresented: Binding(get: { Workspace.shared.deleteRisk != nil }, set: { if !$0 { Workspace.shared.deleteRisk = nil } }), presenting: Workspace.shared.deleteRisk) { risk in
            Button("Delete anyway", role: .destructive) { Workspace.shared.delete(risk.id) }
            Button("Keep it", role: .cancel) {}
        } message: { Text($0.message) }
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
            case .stacks: StacksView()
            case .specs: SpecsView()
            case .memory: MemoryView()
            case .skills: SkillsView()
            case .repo: RepoSetupView()
            case .remote: EnvironmentsView()
            case .settings: SettingsPane(initialTab: agentsTab ? .agents : .general)
            case .help: HelpPane()
            }
        }
    }
}

/// The side menu. Icons only when collapsed, icons with names when expanded. It is wide enough that the window's red, yellow and
/// green buttons sit fully inside it, and the toggle sits right below them.
struct Rail: View {
    let nav = Nav.shared
    let ws = Workspace.shared
    let prefs = Prefs.shared
    private var expanded: Bool { !prefs.sidebarCollapsed }

    var body: some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: 36)                                   // room for the window buttons
            toggle
            RepoSwitcher(expanded: expanded)
            Spacer().frame(height: 6)
            ForEach([Pane.sessions, .specs, .stacks, .pulls, .memory, .skills, .repo, .remote]) { item($0) }
            Spacer()
            ForEach([Pane.settings, .help]) { item($0) }
            HStack(spacing: 4) {
                Image(systemName: "memorychip").font(.system(size: 10))
                Text(expanded ? "Memory \(AppMemory.footprint)" : AppMemory.footprint.replacingOccurrences(of: " MB", with: ""))
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6).help("CPilot memory use")
        }
        .padding(.bottom, 12).padding(.horizontal, 10)
        .frame(width: expanded ? 212 : 76)
        .background(Theme.sidebar)
        .animation(.easeInOut(duration: 0.16), value: prefs.sidebarCollapsed)
    }

    private var toggle: some View {
        Button { prefs.sidebarCollapsed.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 22)
                if expanded { Text("Menu").font(.system(size: 12.5)); Spacer() }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center).padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.soft).help(expanded ? "Collapse the menu" : "Expand the menu").accessibilityLabel(expanded ? "Collapse the menu" : "Expand the menu")
        .keyboardShortcut("\\", modifiers: .command)
    }

    private func item(_ p: Pane) -> some View {
        let on = nav.pane == p
        return Button { nav.pane = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.symbol).font(.system(size: 15)).frame(width: 22)
                if expanded {
                    Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    badge(p)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.78))
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) { if !expanded { badge(p).offset(x: -4, y: 4) } }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.soft).help(p.title).accessibilityLabel(p.title)
    }

    @ViewBuilder private func badge(_ p: Pane) -> some View {
        if p == .sessions, ws.attention > 0 { Circle().fill(Theme.warn).frame(width: 8, height: 8) }
        if p == .settings, Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
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
        Group { if let s = ws.current { ChatView(session: s).id(s.id) } else { Welcome() } }.animation(.easeOut(duration: 0.15), value: ws.selected)
    }
}

/// Sessions as a list down the left, grouped by project. Same data as the tabs; pick whichever suits how you work.
struct SessionSidebar: View {
    let ws = Workspace.shared
    let nav = Nav.shared
    @State private var query = ""

    private var groups: [(String, [SessionMeta])] {
        let list = ws.sessions.filter { Project.shared.owns($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
        return Dictionary(grouping: list, by: \.project).map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.1.first?.updatedAt ?? .distantPast) > ($1.1.first?.updatedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { nav.showNewSession = true } label: { Image(systemName: "plus") }.buttonStyle(.soft).foregroundStyle(.secondary)
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
                case .waiting, .reconnecting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
                case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
                case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
                case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                }
                Text((meta.parentId != nil ? "↳ " : "") + (ws.environment(meta.environment).map { "\($0.name) · " } ?? "") + meta.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(selected ? Theme.accent : Color.primary).contentShape(Rectangle())
        }.buttonStyle(.soft)
        .contextMenu { SessionMenu(id: meta.id, archived: false) }
    }
}

struct TabStrip: View {
    let ws = Workspace.shared
    let nav = Nav.shared
    @State private var showHistory = false

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
                .buttonStyle(.soft).foregroundStyle(.secondary).help("New session (⌘N)").accessibilityLabel("New session")
            Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)).frame(width: 28, height: 26) }
                .buttonStyle(.soft).foregroundStyle(.secondary).help("All sessions").accessibilityLabel("All sessions")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { SessionHistory { showHistory = false } }
        }
        .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 0)
        .onAppear { ws.ensureSelectedTab() }
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
            Text((session.meta.parentId != nil ? "↳ " : "") + (session.env.map { "\($0.name) · " } ?? "") + session.meta.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Button { ws.closeTab(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14) }
                .buttonStyle(.soft).foregroundStyle(.secondary).opacity(selected || hover ? 1 : 0).accessibilityLabel("Close tab")
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
        .contextMenu { SessionMenu(id: session.id, archived: false) }
    }

    @ViewBuilder private var dot: some View {
        switch session.state {
        case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        case .waiting, .reconnecting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
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
            let waiting = ws.needingYou
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Needs you").padding(.bottom, 6)
                    ForEach(waiting) { m in
                        Button { ws.select(m.id) } label: {
                            HStack(spacing: 8) { Circle().fill(Theme.warn).frame(width: 8, height: 8); Text(m.title).lineLimit(1); Spacer(); Text("Review").foregroundStyle(Theme.accent) }
                                .font(.system(size: 12.5, weight: .medium)).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.soft)
                        Divider().opacity(0.5)
                    }
                }.frame(width: 380).padding(.top, 10)
            }
            let recent = ws.sessions.filter { Project.shared.owns($0) }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Recent").padding(.bottom, 6)
                    ForEach(recent.prefix(5)) { m in
                        Button { ws.select(m.id) } label: {
                            HStack { Text(m.title).lineLimit(1); Spacer(); Text(m.project).foregroundStyle(.secondary) }.font(.system(size: 12.5)).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.soft)
                        Divider().opacity(0.5)
                    }
                }.frame(width: 380).padding(.top, 10)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What can be done to a session, the same in the tab, the sidebar, the history list and the menu bar popover.
struct SessionMenu: View {
    let id: String
    let archived: Bool
    var open: (() -> Void)?
    let ws = Workspace.shared
    var body: some View {
        if let open { Button("Open", action: open) }
        if ws.tabs.contains(id) { Button("Close tab") { ws.closeTab(id) } }
        if archived { Button("Restore") { ws.restore(id) } }
        else { Button("Archive") { ws.archive(id) } }
        Divider()
        Button("Delete", role: .destructive) { ws.requestDelete(id) }
    }
}

/// Every session in one place: search, what is open, what is recent and what is archived, with the same actions as right-click.
struct SessionHistory: View {
    let done: () -> Void
    let ws = Workspace.shared
    @State private var query = ""
    @State private var showArchived = false

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let match: (SessionMeta) -> Bool = { Project.shared.owns($0) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.project.localizedCaseInsensitiveContains(q)) }
        let open = ws.sessions.filter { ws.tabs.contains($0.id) && match($0) }
        let recent = ws.sessions.filter { !ws.tabs.contains($0.id) && match($0) }
        let archived = ws.archived.filter(match)
        VStack(spacing: 0) {
            SearchBox(prompt: "Search sessions", text: $query).padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("Open", open, archived: false)
                    group("Recent", recent, archived: false)
                    if open.isEmpty && recent.isEmpty {
                        Text(q.isEmpty ? "No sessions yet." : "No session matches “\(q)”.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(12)
                    }
                    if !archived.isEmpty {
                        Button { showArchived.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showArchived || !q.isEmpty ? 90 : 0))
                                SectionLabel("Archived (\(archived.count))"); Spacer()
                            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showArchived || !q.isEmpty { ForEach(archived) { HistoryRow(meta: $0, archived: true, done: done) } }
                    }
                }.padding(6)
            }
        }.frame(width: 380, height: 440)
    }

    @ViewBuilder private func group(_ title: String, _ items: [SessionMeta], archived: Bool) -> some View {
        if !items.isEmpty {
            SectionLabel(title).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(items) { HistoryRow(meta: $0, archived: archived, done: done) }
        }
    }
}

struct HistoryRow: View {
    let meta: SessionMeta
    let archived: Bool
    let done: () -> Void
    let ws = Workspace.shared
    @State private var hover = false

    var body: some View {
        let c = ws.controller(meta.id)
        HStack(spacing: 8) {
            Button { if archived { ws.restore(meta.id) } else { ws.select(meta.id) }; done() } label: {
                HStack(spacing: 8) {
                    dot(archived ? .asleep : c?.state ?? .asleep)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((meta.parentId != nil ? "↳ " : "") + meta.title).font(.system(size: 12.5, weight: ws.selected == meta.id ? .semibold : .regular)).lineLimit(1)
                        Text("\(meta.project) · \(meta.updatedAt.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if hover {
                if archived { iconButton("arrow.uturn.backward", "Restore") { ws.restore(meta.id); done() } }
                else {
                    if ws.tabs.contains(meta.id) { iconButton("xmark", "Close tab") { ws.closeTab(meta.id) } }
                    iconButton("archivebox", "Archive") { ws.archive(meta.id) }
                }
                iconButton("trash", "Delete") { ws.requestDelete(meta.id); done() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hover ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hover = $0 }
        .contextMenu { SessionMenu(id: meta.id, archived: archived) }
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.soft).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }

    @ViewBuilder private func dot(_ s: SessionController.RunState) -> some View {
        switch s {
        case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        case .waiting, .reconnecting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
        case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
        case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
        case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Textual
import CPilotKit

/// The main pane: one session's conversation, an inline approval card when the agent needs you, and the composer.
struct ChatView: View {
    let session: SessionController
    let ws = Workspace.shared
    @State private var stickToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(session: session)
            Divider().opacity(0.5)
            if session.recapVisible { RecapCard(session: session).padding(.horizontal, 16).padding(.top, 10) }
            transcript
            TasksStrip(parent: session)
            if session.meta.branch != nil { SessionPRBar(session: session) }
            Composer(session: session)
        }
        .background(Theme.pane)
        .onAppear { session.loadIfNeeded(); session.showRecapIfAway() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.items.isEmpty { EmptyChat(session: session) }
                    ForEach(session.items.filter { $0.parent == nil }) { item in ChatRow(item: item, session: session, children: session.items.filter { $0.parent == item.id }).id(item.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.items.count) { _, _ in scroll(proxy) }
            .onChange(of: session.items.last?.text) { _, _ in scroll(proxy) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

struct ChatHeader: View {
    let session: SessionController
    let ws = Workspace.shared

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.meta.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Badge(text: backendName, kind: .accent)
                    if let e = session.env { Badge(text: e.name, kind: .accent).help("Running on \(e.target)") }
                    Badge(text: session.meta.project, kind: .neutral)
                    if let b = session.meta.branch { Badge(text: b, kind: .neutral) }
                    if session.cost > 0 { Text(String(format: "$%.2f", session.cost)).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            stateView
            ArtifactsButton(session: session)
            MemoryChip(session: session)
            actionsMenu
            accessMenu
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @State private var summarize = false
    @State private var stacking = false
    @State private var stackName = ""

    private var actionsMenu: some View {
        Menu {
            Button("Recap this session") { session.refreshRecap(force: true); session.recapVisible = true }
            if session.meta.branch != nil { Button("Stack a new branch on top…") { stacking = true } }
            Button("Fork this session") { ws.fork(session) }
            Menu("Continue with another agent") {
                if session.meta.backend.kind != .claude { Button("Claude") { ws.fork(session, to: .claude) } }
                ForEach(ws.acpAgents.filter { $0.id != session.meta.backend.acpAgent }) { a in Button(a.name) { ws.fork(session, to: .acp(a.id)) } }
            }
            Divider()
            Button("Make this a spec…") { SpecCenter.shared.fromSession(session); Task { await SpecCenter.shared.open(PRCenter.Repo(dir: session.meta.cwd, environment: session.meta.environment)); Nav.shared.pane = .specs } }
            Button("Save what we learned to memory…") { summarize = true }
            if session.meta.backend.kind == .claude, session.meta.remoteId != nil { Button("Continue in Terminal") { session.openInTerminal() } }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).help("Fork, switch agent, save to memory")
        .sheet(isPresented: $summarize) { SummarizeSheet(session: session) }
        .sheet(isPresented: $stacking) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stack a new branch").font(.system(size: 16, weight: .semibold))
                Text("Creates a branch on top of \(session.meta.branch ?? "this one") with its own session and copy of the files.").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("branch name", text: $stackName).textFieldStyle(CPField())
                HStack { Spacer(); Button("Cancel") { stacking = false }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                    Button("Create") { let n = stackName; stacking = false; Task { do { try await ws.stackOn(session, name: n) } catch { AppModel.shared.failQuietly(error, action: "Stack a branch") } } }
                        .buttonStyle(Pill(kind: .primary)).disabled(stackName.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 420)
        }
    }

    private var backendName: String {
        switch session.meta.backend.kind {
        case .claude: "Claude" + (session.meta.model.map { " · \($0)" } ?? "")
        case .acp: ws.acpAgents.first { $0.id == session.meta.backend.acpAgent }?.name ?? "Agent"
        }
    }

    @ViewBuilder private var stateView: some View {
        switch session.state {
        case .running: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .waiting: Badge(text: "Needs approval", kind: .warn)
        case .reconnecting: Badge(text: "Reconnecting…", kind: .warn)
        case .failed: Badge(text: "Stopped", kind: .danger)
        case .asleep: Text("Asleep · resumes on your next message").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .idle: EmptyView()
        }
    }

    private var accessMenu: some View {
        let level = ws.policy.level(for: session.meta)
        return Menu {
            ForEach(AccessLevel.allCases) { l in
                Button { AccessGate.set(l, for: session) } label: {
                    Label(l.label, systemImage: l == level ? "checkmark" : "")
                }
            }
        } label: {
            Label(level.label, systemImage: level == .fullAccess ? "exclamationmark.shield" : "lock.shield")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(level == .fullAccess ? Theme.danger : Theme.ok)
        .help(level.detail)
    }
}

/// Turning on Full access needs a fingerprint or password, so an agent can never grant itself more.
@MainActor enum AccessGate {
    static func set(_ level: AccessLevel, for session: SessionController) {
        if level == .fullAccess, session.env != nil { session.addNotice("Full access is not available on servers. Agents there always ask first."); return }
        guard level == .fullAccess, Workspace.shared.policy.requireTouchIDForFullAccess else { session.setAccess(level); return }
        Biometrics.confirm("Allow \"\(session.meta.title)\" to run without asking") { ok in if ok { session.setAccess(.fullAccess) } }
    }
}

struct EmptyChat: View {
    let session: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should we work on?").font(.system(size: 18, weight: .semibold))
            Text("\(session.meta.project) · \(session.meta.branch ?? "current branch"). Attach a screenshot, error or link with the capture shortcut.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }.padding(.top, 60)
    }
}

// MARK: Rows

struct ChatRow: View {
    let item: ChatItem
    let session: SessionController
    var children: [ChatItem] = []

    var body: some View {
        switch item.kind {
        case .user: UserBubble(item: item).frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant: AssistantText(text: item.text, streaming: item.status == .running, project: session.meta.cwd)
        case .thinking: ThinkingRow(item: item)
        case .tool: ToolCard(item: item, children: children)
        case .permission: ApprovalCard(item: item, session: session)
        case .notice: Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct UserBubble: View {
    let item: ChatItem
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !item.attachments.isEmpty { AttachmentStrip(attachments: item.attachments, removable: nil) }
            if !item.text.isEmpty {
                Text(item.text).font(.system(size: 13.5)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14))
                    .foregroundStyle(Theme.onAccent)
            }
        }.frame(maxWidth: 620, alignment: .trailing)
    }
}

struct AssistantText: View {
    let text: String
    let streaming: Bool
    var project: String?
    @State private var hover = false
    var body: some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.system(size: 13.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(streaming && text.isEmpty ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if hover, !streaming, !text.isEmpty {
                    Button { Workspace.shared.remember(text, project: project) } label: { Label("Remember", systemImage: "brain") }
                        .buttonStyle(Pill(kind: .plain)).help("Save this reply as a note for future sessions")
                }
            }
            .onHover { hover = $0 }
            .contextMenu { Button("Remember this") { Workspace.shared.remember(text, project: project) } }
    }
}

struct ThinkingRow: View {
    let item: ChatItem
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(item.status == .running ? "Thinking…" : "Thought", systemImage: "brain").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct ToolCard: View {
    let item: ChatItem
    var children: [ChatItem] = []
    @State private var open = false
    private var isAgent: Bool { item.title == "Agent" || item.title == "Task" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if !item.text.isEmpty || !children.isEmpty { open.toggle() } } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(item.title ?? "Tool").font(.system(size: 12, weight: .semibold))
                    Text(item.detail ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isAgent { Badge(text: "Sub-agent", kind: .accent); Text("\(children.filter { $0.kind == .tool }.count) steps").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if !item.text.isEmpty || !children.isEmpty { Image(systemName: open || (isAgent && item.status == .running) ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if (open || (isAgent && item.status == .running)) && !children.isEmpty {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(children) { c in
                        if c.kind == .tool {
                            HStack(spacing: 6) {
                                Image(systemName: c.status == .failed ? "xmark.circle.fill" : c.status == .running ? "circle.dotted" : "checkmark.circle.fill").font(.system(size: 10))
                                    .foregroundStyle(c.status == .failed ? Theme.danger : c.status == .running ? Color.secondary : Theme.ok)
                                Text(c.title ?? "Tool").font(.system(size: 11.5, weight: .medium))
                                Text(c.detail ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } else if c.kind == .assistant {
                            Text(c.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if open {
                ScrollView([.horizontal, .vertical]) {
                    Text(item.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.white.opacity(0.85)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220).background(Theme.terminal)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.system(size: 12))
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 12))
        }
    }
}

/// The one-time approval card. Allow once is the default; wider choices are one click away and always logged.
struct ApprovalCard: View {
    let item: ChatItem
    let session: SessionController

    var body: some View {
        let pending = item.status == .pending
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: pending ? "hand.raised.fill" : (item.status == .allowed ? "checkmark.shield" : "xmark.shield"))
                    .foregroundStyle(pending ? Theme.warn : (item.status == .allowed ? Theme.ok : Theme.danger))
                Text(pending ? "Allow \(item.title ?? "this")?" : (item.status == .allowed ? "Allowed" : "Denied")).font(.system(size: 13, weight: .semibold))
                if !pending, let d = item.detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                if pending { Badge(text: "Needs approval", kind: .warn) }
            }
            Text(item.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
            if let p = item.preview { EditPreviewView(lines: EditPreview.decode(p)) }
            if pending {
                if let p = item.detail { Text(p).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    Button("Allow once") { session.resolve(reqId, allow: true, scope: .once) }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                    Button("Allow for session") { session.resolve(reqId, allow: true, scope: .session) }.buttonStyle(Pill(kind: .plain))
                    if item.title == "Bash" { Button("Always in this project") { session.resolve(reqId, allow: true, scope: .project) }.buttonStyle(Pill(kind: .plain)) }
                    Spacer()
                    Button("Deny") { session.resolve(reqId, allow: false, scope: .once) }.buttonStyle(Pill(kind: .danger))
                }
            }
        }
        .padding(12)
        .background(pending ? Theme.warnSoft : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pending ? Theme.warn : Theme.hairline))
    }

    private var reqId: String { String(item.id.dropFirst(5)) }   // "perm-" prefix
}

// MARK: Attachments

struct AttachmentStrip: View {
    let attachments: [Attachment]
    var removable: ((Attachment) -> Void)?
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(attachments) { a in
                HStack(spacing: 6) {
                    thumb(a)
                    Text(a.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    if let r = removable {
                        Button { r(a) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove attachment")
                    }
                }
                .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                .help(a.source.map { "From \($0)" } ?? a.value)
            }
        }
    }

    @ViewBuilder private func thumb(_ a: Attachment) -> some View {
        if a.kind == .image, let img = NSImage(contentsOfFile: a.value) {
            Image(nsImage: img).resizable().scaledToFill().frame(width: 40, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            let label = a.kind == .link ? "URL" : a.kind == .file ? "FILE" : "TXT"
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 30, height: 28).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Wraps its children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: Composer

struct Composer: View {
    @Bindable var session: SessionController
    @FocusState private var focused: Bool
    @State private var delegate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                AttachmentStrip(attachments: session.attachments) { a in session.attachments.removeAll { $0.id == a.id } }
            }
            if !slashMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slashMatches.prefix(6)) { sk in
                        Button { pick(sk) } label: {
                            HStack { Image(systemName: "sparkles").foregroundStyle(Theme.accent); Text(sk.name).font(.system(size: 12.5, weight: .medium)); Text(sk.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1); Spacer() }
                                .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("Message \(session.meta.backend.kind == .claude ? "Claude" : "the agent")…  / for skills, ⌘V pastes images", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...10).focused($focused)
                .onSubmit { if let first = slashMatches.first { pick(first) } else if session.canSend, !session.isBusy { session.send() } }
            HStack(spacing: 8) {
                Menu {
                    Button("Capture a region…") { CaptureCoordinator.shared.capture(into: session, window: false) }
                    Button("Capture a window…") { CaptureCoordinator.shared.capture(into: session, window: true) }
                    Button("Add the front browser page") { CaptureCoordinator.shared.addBrowserPage(to: session) }
                    Button("Add clipboard") { CaptureCoordinator.shared.addClipboard(to: session) }
                    Divider()
                    Button("Add a file…") { addFile() }
                    Divider()
                    Button("Delegate to a new task…") { delegate = true }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("Attach a screenshot, snippet, link or file")
                SkillMenu(session: session)
                Spacer()
                if session.isBusy {
                    Button { session.interrupt() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(Pill(kind: .plain))
                } else {
                    Button("Send") { session.send() }.buttonStyle(Pill(kind: .primary)).disabled(!session.canSend).keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.6) : Theme.hairline))
        .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .onPasteCommand(of: [.image, .fileURL]) { providers in CaptureCoordinator.shared.paste(providers, into: session) }
        .dropDestination(for: URL.self) { urls, _ in CaptureCoordinator.shared.addFiles(urls, to: session); return !urls.isEmpty }
        .onAppear { focused = true }
        .onChange(of: session.draft) { _, _ in session.saveDraftSoon() }
        .sheet(isPresented: $delegate) { DelegateSheet(parent: session) }
    }

    /// Typing "/" lists the skills on this Mac; picking one asks for it by name (or pastes its instructions for agents without skills).
    private var slashMatches: [Skill] {
        let d = session.draft
        guard d.hasPrefix("/"), !d.contains(" "), !d.contains("\n") else { return [] }
        let q = d.dropFirst().lowercased()
        return SkillCatalog.discover(project: session.meta.cwd).filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    private func pick(_ sk: Skill) {
        session.draft = session.meta.backend.kind == .claude ? "Use the \(sk.name) skill. " : SkillCatalog.body(of: sk) + "\n\n"
    }

    private func addFile() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { CaptureCoordinator.shared.addFiles(p.urls, to: session) }
    }
}

struct SkillMenu: View {
    let session: SessionController
    var body: some View {
        let skills = SkillCatalog.discover(project: session.meta.cwd)
        if !skills.isEmpty {
            Menu {
                ForEach(skills) { s in
                    Button(s.name) {
                        // Claude loads skills itself when asked by name; other agents get the instructions pasted in.
                        session.draft += session.meta.backend.kind == .claude ? "Use the \(s.name) skill. " : SkillCatalog.body(of: s)
                    }.help(s.detail)
                }
            } label: { Image(systemName: "sparkles") }
                .menuStyle(.borderlessButton).fixedSize().help("Use a skill")
        }
    }
}

/// The proposed change of a file edit, drawn like a diff, so an approval is an informed one.
struct EditPreviewView: View {
    let lines: [EditPreview.Line]
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6) {
                        Text(l.kind == .added ? "+" : l.kind == .removed ? "−" : " ").foregroundStyle(l.kind == .added ? Color.green : Color.red)
                        Text(l.text.isEmpty ? " " : l.text).foregroundStyle(l.kind == .note ? Color.white.opacity(0.5) : Color.white.opacity(0.9))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5, design: .monospaced)).padding(.horizontal, 8)
                    .background(l.kind == .added ? Color.green.opacity(0.16) : l.kind == .removed ? Color.red.opacity(0.18) : .clear)
                }
            }.frame(minWidth: 300, alignment: .leading).padding(.vertical, 4)
        }
        .frame(maxHeight: 200).background(Theme.terminal).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

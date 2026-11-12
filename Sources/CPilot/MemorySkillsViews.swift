// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Notes the agents carry between sessions: plain Markdown files, global or per project.
struct MemoryView: View {
    let ws = Workspace.shared
    @State private var notes: [MemoryNote] = []
    @State private var query = ""
    @State private var selection: MemoryNote.ID?
    @State private var scope = MemoryStore.globalScope
    @State private var title = ""
    @State private var text = ""
    /// A note being written that is not saved yet. Without it the editor would look the same whether or not New note was pressed.
    @State private var creating = false
    @FocusState private var titleFocus: Bool
    /// The hash of the text the editor was loaded with. Saving quotes it, so a note someone else changed in the meantime is not overwritten without a word.
    @State private var baseHash: String?
    @State private var clash: Clash?
    @State private var problem: String?
    @State private var showHistory = false

    private struct Clash { var message: String; var current: MemoryNote? }

    private var projects: [(String, String)] {
        var seen = Set<String>(), out: [(String, String)] = [(MemoryStore.globalScope, "All projects")]
        for m in ws.sessions {
            let s = MemoryStore.scope(forProject: m.cwd)
            if seen.insert(s).inserted { out.append((s, m.project)) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Memory", subtitle: "Notes every session starts with. Plain Markdown files you can edit anywhere. \(budget)") {
                HStack(spacing: 8) {
                    let deleted = ws.memory.allDeletedNotes()
                    if !deleted.isEmpty {
                        Menu("Deleted notes") {
                            ForEach(deleted, id: \.name) { d in
                                Button("Restore \(d.name)") {
                                    if let last = ws.memory.history(scope: d.scope, name: d.name).first(where: { !$0.deleted }) { _ = ws.memory.restore(scope: d.scope, name: d.name, version: last.id) }
                                    reload()
                                }
                            }
                        }.menuStyle(.button).fixedSize()
                    }
                    AsyncButton("Dream now") {
                        guard let r = Project.shared.current, r.environment == nil else { AppModel.shared.show("Open a repository on this Mac first.", error: true); return }
                        let o = await Dreamer.shared.dream(repo: r.dir, manual: true)
                        AppModel.shared.show(o.message, error: { if case .failed = o { return true } else { return false } }())
                    }.buttonStyle(Pill(kind: .plain))
                    Button("New note") { startNote() }.buttonStyle(Pill(kind: .primary))
                }
            }
            DreamsPanel()
            HSplitView {
                VStack(spacing: 8) {
                    SearchBox(prompt: "Search notes", text: $query).padding([.horizontal, .top], 10)
                    List(filtered, selection: $selection) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.name).font(.system(size: 13, weight: .medium))
                            Text(n.scope == MemoryStore.globalScope ? "All projects" : n.scope).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.tag(n.id)
                    }.listStyle(.plain)
                }.frame(minWidth: 220, maxWidth: 300)
                if selection == nil, !creating {
                    VStack(spacing: 8) {
                        Image(systemName: "brain").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("Pick a note to edit it, or write a new one").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("Notes are loaded at the start of every session, so keep them short and true. You can also save any message from a chat with Remember.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                        Button("New note") { startNote() }.buttonStyle(Pill(kind: .primary))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minWidth: 340)
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Title", text: $title).textFieldStyle(CPField()).focused($titleFocus)
                        Dropdown(options: projects.map { ($0.0, $0.1) }, selection: $scope).frame(width: 170)
                    }
                    TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                    if let c = clash {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(c.message).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if let cur = c.current { Button("Show their version") { text = cur.body; baseHash = cur.hash; clash = nil }.buttonStyle(Pill(kind: .plain)) }
                                Button("Save anyway") { save(overwrite: true) }.buttonStyle(Pill(kind: .plain))
                                Text("The other version stays in History.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                    HStack {
                        if let sel = selection, let n = notes.first(where: { $0.id == sel }) {
                            Button("Delete") { ws.memory.delete(scope: n.scope, name: n.name); selection = nil; creating = false; clash = nil; reload() }.buttonStyle(Pill(kind: .danger))
                            Button("History") { showHistory.toggle() }.buttonStyle(Pill(kind: .plain))
                                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                                    MemoryHistoryList(scope: n.scope, name: n.name) { restored in
                                        showHistory = false; text = restored.body; baseHash = restored.hash; clash = nil; reload()
                                    }
                                }
                        }
                        Spacer()
                        Button("Save") { save() }.buttonStyle(Pill(kind: .primary)).disabled(title.isEmpty || text.isEmpty)
                    }
                }.padding(14).frame(minWidth: 340)
                }
            }
        }
        .background(Theme.pane)
        .onAppear(perform: reload)
        .onChange(of: selection) { _, id in
            clash = nil; problem = nil
            if let n = notes.first(where: { $0.id == id }) { creating = false; title = n.name; text = n.body; scope = n.scope; baseHash = n.hash }
        }
    }

    /// An empty editor for a note of the repository you are in (or all projects without one), with the cursor in the title.
    private func startNote() {
        selection = nil; creating = true; title = ""; text = ""; baseHash = nil; clash = nil; problem = nil
        scope = Project.shared.current.map { MemoryStore.scope(forProject: $0.dir) } ?? MemoryStore.globalScope
        titleFocus = true
    }

    /// Saves the editor. A note that changed since it was opened (an agent, a finished run, another editor) is not replaced unless `overwrite` says so; either way the old text is kept in History.
    private func save(overwrite: Bool = false) {
        let editing = notes.first { $0.id == selection }
        let sameNote = editing.map { $0.scope == scope && $0.name == MemoryStore.safeName(title) } ?? false
        let expect: MemoryExpect = overwrite ? .anything : sameNote ? (baseHash.map { .hash($0) } ?? .anything) : .absent
        switch ws.memory.write(scope: scope, name: title, body: text, expect: expect, actor: "you", reason: "Edited in Memory") {
        case .saved(let n): clash = nil; problem = nil; creating = false; baseHash = n.hash; selection = n.id
        case .conflict(let now):
            clash = Clash(message: sameNote ? (now == nil ? "This note was deleted while you were editing it." : "This note changed while you were editing it, by an agent, a finished run or another editor.")
                                            : "A note with this title already exists here.", current: now)
        case .failed, .rejected: problem = "Could not save the note."
        }
        reload()
    }

    /// Sessions load notes up to a cap, so show how close you are.
    private var budget: String {
        let used = notes.reduce(0) { $0 + $1.body.count }
        return "\(used.formatted()) characters saved; a session loads up to \(MemoryStore.defaultLimit.formatted())."
    }

    private var filtered: [MemoryNote] { query.isEmpty ? notes : notes.filter { ($0.name + $0.body).localizedCaseInsensitiveContains(query) } }
    private func reload() { notes = ws.memory.allNotes(); ws.refreshRemembered() }
}

/// The saved versions of one note, newest first, each with who wrote it and why. Restoring one adds a new version; nothing is ever rewritten.
private struct MemoryHistoryList: View {
    let scope: String
    let name: String
    let restored: (MemoryNote) -> Void
    @State private var versions: [MemoryVersion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History of \(name)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(versions) { v in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(v.actor) · \(v.date, style: .relative) ago").font(.system(size: 12.5, weight: .medium))
                                Text(v.deleted ? "Deleted" : v.reason.isEmpty ? String(v.body.prefix(80)) : v.reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if !v.deleted, v.id != versions.first?.id {
                                Button("Restore") {
                                    if case .saved(let n) = Workspace.shared.memory.restore(scope: scope, name: name, version: v.id) { restored(n) }
                                }.buttonStyle(Pill(kind: .plain))
                            }
                        }
                    }
                }
            }.frame(maxHeight: 300)
        }
        .padding(14).frame(width: 340)
        .onAppear { versions = Workspace.shared.memory.history(scope: scope, name: name) }
    }
}

/// Skills already on this Mac. Claude loads them itself; this lists them and shows what each does.
struct SkillsView: View {
    @State private var skills: [Skill] = []
    @State private var query = ""
    @State private var creating = false
    @State private var extending: Skill?
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Skills", subtitle: "Found in ~/.claude/skills and each project's .claude/skills") {
                HStack(spacing: 8) {
                    SearchBox(prompt: "Search skills", text: $query).frame(width: 220)
                    Button("Refresh") { skills = SkillCatalog.discover(project: Workspace.shared.current?.meta.cwd) }.buttonStyle(Pill(kind: .plain))
                    Button("New skill") { creating = true }.buttonStyle(Pill(kind: .primary))
                }
            }
            ScrollView {
                VStack(spacing: 10) {
                    if skills.isEmpty { Text("No skills found yet.").foregroundStyle(.secondary).padding(30) }
                    ForEach(skills.filter { query.isEmpty || ($0.name + $0.detail).localizedCaseInsensitiveContains(query) }) { s in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(s.name).font(.system(size: 14, weight: .semibold))
                                Badge(text: s.scope)
                                Spacer()
                                Button("Add to skill") { extending = s }.buttonStyle(Pill(kind: .plain))
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) }.buttonStyle(Pill(kind: .plain))
                            }
                            Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.card()
                    }
                }.padding(22).frame(maxWidth: .infinity)
            }
        }
        .background(Theme.pane)
        .sheet(isPresented: $creating) { NewSkillSheet() }
        .sheet(item: $extending) { ExtendSkillSheet(skill: $0) }
        .onAppear { skills = SkillCatalog.discover(project: Workspace.shared.current?.meta.cwd) }
    }
}

/// Describe a skill in plain words; Claude's own skill-creator builds it in a chat you can keep refining.
struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var idea = ""
    @State private var forProject = false
    @State private var busy = false
    @State private var stage = ""
    @State private var failure: ErrorReport?
    private var project: String? { Workspace.shared.current?.meta.cwd }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New skill").font(.system(size: 17, weight: .semibold))
            Text("Say what the skill should do and when Claude should use it. Claude will use its skill creator to write it, ask you what it needs, and test it with you in a chat.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $idea).font(.system(size: 12.5)).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Picker("Save to", selection: $forProject) {
                Text("All my projects (~/.claude/skills)").tag(false)
                if let project { Text("This project (\((project as NSString).lastPathComponent))").tag(true) }
            }.pickerStyle(.radioGroup)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small); Text(stage).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction).disabled(busy)
                AsyncButton { await start() } label: { Text(busy ? "Starting…" : "Create with Claude") }
                    .buttonStyle(Pill(kind: .primary)).disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $failure) { ErrorReportSheet(report: $0) }
    }

    private func start() async {
        busy = true; defer { busy = false }
        stage = "Opening a session for Claude…"
        let home = NSHomeDirectory()
        let root = forProject ? (project ?? home) : home
        let target = forProject ? "\(root)/.claude/skills" : "\(home)/.claude/skills"
        let prompt = """
        Create a new Claude Code skill with the skill-creator skill (use the Skill tool). If it is not available, write it yourself: a folder with a SKILL.md that has `name` and `description` frontmatter (say what it does and when to use it) followed by the instructions.
        Save it as a new folder inside \(target) and do not touch other skills there. Ask me anything you need, then show me what you made.

        What the skill should do:
        \(idea)
        """
        do {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            try await Workspace.shared.create(.init(folder: root, access: .editFiles, firstMessage: prompt))
            Nav.shared.pane = .sessions
            AppModel.shared.show("Claude is starting the skill creator")
            dismiss()
        } catch { failure = ErrorReport(error, action: "Start the skill creator") }
    }
}

/// Teach an existing skill something new, from what you just learned in a repo or from a note you write.
struct ExtendSkillSheet: View {
    let skill: Skill
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var fromSession = true
    @State private var busy = false
    @State private var stage = ""
    @State private var failure: ErrorReport?
    private var current: SessionController? { Workspace.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to \(skill.name)").font(.system(size: 17, weight: .semibold))
            Text("Claude reads the skill, then adds what is new without rewriting what is already there. You review the change in the chat.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $note).font(.system(size: 12.5)).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                .disabled(busy).opacity(busy ? 0.6 : 1)
            if let current {
                Toggle("Also learn from my current session: \(current.meta.title)", isOn: $fromSession).disabled(busy)
            }
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small); Text(stage).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction).disabled(busy)
                AsyncButton { await start() } label: { Text(busy ? "Starting…" : "Update with Claude") }
                    .buttonStyle(Pill(kind: .primary)).disabled(busy || (note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(fromSession && current != nil)))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $failure) { ErrorReportSheet(report: $0) }
    }

    private func start() async {
        busy = true; defer { busy = false }
        stage = fromSession && current != nil ? "Reading your session…" : "Preparing the update…"
        await Task.yield()
        let dir = (skill.path as NSString).deletingLastPathComponent
        let learned: String
        if fromSession, let c = current {
            c.loadIfNeeded()
            let digest = ContextDigest.handoff(ContextDigest.build(items: c.items), from: c.meta.title)
            learned = "Lessons from my recent work in \(c.meta.cwd). Keep only what is general and reusable, never project secrets or one-off details:\n\(digest)\n\n"
        } else { learned = "" }
        let prompt = """
        Improve my existing Claude Code skill "\(skill.name)" at \(dir). Read its SKILL.md and any files next to it first (use the skill-creator skill if available). Add what is new below as concise instructions in the right place, merge with similar guidance instead of repeating it, keep the frontmatter valid, and do not delete or rewrite what already works. Then show me the diff of what you changed.

        \(learned)\(note)
        """
        stage = "Opening a session for Claude…"
        do {
            try await Workspace.shared.create(.init(folder: dir, access: .editFiles, firstMessage: prompt))
            Nav.shared.pane = .sessions
            AppModel.shared.show("Claude is reading \(skill.name) and will show you the change")
            dismiss()
        } catch { failure = ErrorReport(error, action: "Start the skill update") }
    }
}

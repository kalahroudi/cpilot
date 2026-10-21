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
                Button("New note") { selection = nil; title = ""; text = "" }.buttonStyle(Pill(kind: .primary))
            }
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Title", text: $title).textFieldStyle(CPField())
                        Dropdown(options: projects.map { ($0.0, $0.1) }, selection: $scope).frame(width: 170)
                    }
                    TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                    HStack {
                        if let sel = selection, let n = notes.first(where: { $0.id == sel }) {
                            Button("Delete") { ws.memory.delete(scope: n.scope, name: n.name); selection = nil; reload() }.buttonStyle(Pill(kind: .danger))
                        }
                        Spacer()
                        Button("Save") { if let n = ws.memory.save(scope: scope, name: title, body: text) { selection = n.id }; reload() }
                            .buttonStyle(Pill(kind: .primary)).disabled(title.isEmpty || text.isEmpty)
                    }
                }.padding(14).frame(minWidth: 340)
            }
        }
        .background(Theme.pane)
        .onAppear(perform: reload)
        .onChange(of: selection) { _, id in
            if let n = notes.first(where: { $0.id == id }) { title = n.name; text = n.body; scope = n.scope }
        }
    }

    /// Sessions load notes up to a cap, so show how close you are.
    private var budget: String {
        let used = notes.reduce(0) { $0 + $1.body.count }
        return "\(used.formatted()) characters saved; a session loads up to 6,000."
    }

    private var filtered: [MemoryNote] { query.isEmpty ? notes : notes.filter { ($0.name + $0.body).localizedCaseInsensitiveContains(query) } }
    private func reload() { notes = ws.memory.allNotes() }
}

/// Skills already on this Mac. Claude loads them itself; this lists them and shows what each does.
struct SkillsView: View {
    @State private var skills: [Skill] = []
    @State private var query = ""
    @State private var creating = false
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
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) { Text(s.name).font(.system(size: 13, weight: .semibold)); Badge(text: s.scope) }
                                Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) }.buttonStyle(Pill(kind: .plain))
                        }.card()
                    }
                }.padding(22).frame(maxWidth: 820)
            }
        }
        .background(Theme.pane)
        .sheet(isPresented: $creating) { NewSkillSheet() }
        .onAppear { skills = SkillCatalog.discover(project: Workspace.shared.current?.meta.cwd) }
    }
}

/// Describe a skill in plain words; Claude's own skill-creator builds it in a chat you can keep refining.
struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var idea = ""
    @State private var forProject = false
    @State private var busy = false
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { Task { await start() } } label: { if busy { ProgressView().controlSize(.small) } else { Text("Create with Claude") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .sheet(item: $failure) { ErrorReportSheet(report: $0) }
    }

    private func start() async {
        busy = true; defer { busy = false }
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
            dismiss()
        } catch { failure = ErrorReport(error, action: "Start the skill creator") }
    }
}

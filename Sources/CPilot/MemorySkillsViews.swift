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
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Skills", subtitle: "Found in ~/.claude/skills and each project's .claude/skills") {
                SearchBox(prompt: "Search skills", text: $query).frame(width: 220)
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
        .onAppear { skills = SkillCatalog.discover(project: Workspace.shared.current?.meta.cwd) }
    }
}

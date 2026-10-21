// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// A small chip in the chat header: how many notes this session started with, and what did not fit.
struct MemoryChip: View {
    let session: SessionController
    @State private var open = false

    var body: some View {
        let plan = Workspace.shared.memory.plan(forProject: session.meta.cwd)
        let engine = Prefs.shared.memoryEngine == "engine"
        if !plan.included.isEmpty || !plan.dropped.isEmpty || engine {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain").font(.system(size: 10))
                    Text(plan.included.isEmpty && engine ? "Memory engine" : "\(plan.included.count) notes")
                    if !plan.dropped.isEmpty { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.fill, in: Capsule())
            }
            .buttonStyle(.plain).help("Notes this session started with")
            .popover(isPresented: $open, arrowEdge: .bottom) { MemoryPlanView(plan: plan, engine: engine).padding(14).frame(width: 300) }
        }
    }
}

struct MemoryPlanView: View {
    let plan: MemoryStore.Plan
    let engine: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This session started with").font(.system(size: 13, weight: .semibold))
            if plan.included.isEmpty { Text("No notes yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(plan.included) { n in Label(n.name, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.ok) }
            if !plan.dropped.isEmpty {
                Divider()
                Text("Left out, because notes are capped").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                ForEach(plan.dropped) { n in Label(n.name, systemImage: "minus.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("Shorten or delete older notes in the Memory screen so these fit.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if engine { Divider(); Text("The memory engine is also connected, so the agent can recall earlier sessions.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }
}

/// Turns a session into a note: Claude drafts a few durable facts from the conversation, you edit and save.
struct SummarizeSheet: View {
    let session: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var working = true
    @State private var error: String?
    @State private var forProject = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save what this session learned").font(.system(size: 16, weight: .semibold))
            Text("A draft from the conversation. Keep only durable facts: how to run things, decisions and why, mistakes to avoid.").font(.system(size: 12)).foregroundStyle(.secondary)
            if working { HStack { ProgressView().controlSize(.small); Text("Drafting…").font(.system(size: 12)).foregroundStyle(.secondary) } }
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.system(size: 12.5, design: .monospaced)).frame(height: 190).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            Toggle("Only for \(session.meta.project)", isOn: $forProject).toggleStyle(.switch).tint(Theme.accent)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button("Save note") { Workspace.shared.remember(text, project: forProject ? session.meta.cwd : nil, name: title); dismiss() }
                    .buttonStyle(Pill(kind: .primary)).disabled(title.isEmpty || text.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .task { await draft() }
    }

    private func draft() async {
        let digest = ContextDigest.build(items: session.items, budget: 12000)
        guard !digest.isEmpty else { working = false; error = "There is nothing to summarize yet."; return }
        let prompt = "From this conversation summary, write a short note for future sessions in this project. Reply with a title on the first line, a blank line, then at most 8 bullet points of durable facts (how to build or test, decisions and reasons, pitfalls). No preamble.\n\n\(digest)"
        if let out = await ClaudeOneShot.run(prompt, in: session.meta.workingDirectory, timeout: 120) {
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            title = (parts.first ?? "").replacingOccurrences(of: "# ", with: "")
            text = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = session.meta.title; text = digest
            error = "Claude could not draft this, so the raw summary is below. Trim it before saving."
        }
        working = false
    }
}

/// "Where things stand", shown at the top of a session you have come back to.
struct RecapCard: View {
    let session: SessionController
    @State private var save = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Recap").font(.system(size: 13, weight: .semibold))
                Text(session.meta.updatedAt.formatted(.relative(presentation: .named))).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if session.recapBusy { ProgressView().controlSize(.mini) }
                Spacer()
                Button { session.refreshRecap(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Write the recap again").accessibilityLabel("Refresh recap")
                Button { session.dismissRecap() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss recap")
            }
            if let text = session.meta.recap, let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(md).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Pick up where we left off") { session.dismissRecap() }.buttonStyle(Pill(kind: .primary))
                Button("Save to memory…") { save = true }.buttonStyle(Pill(kind: .plain))
            }
        }
        .padding(12)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
        .sheet(isPresented: $save) { SummarizeSheet(session: session) }
    }
}

/// Start a task from this session: it begins with a summary of the conversation so far and can run alongside it.
struct DelegateSheet: View {
    let parent: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var backend: Backend = .claude
    @State private var worktree = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delegate to a new task").font(.system(size: 16, weight: .semibold))
            Text("The task starts with a summary of this session and runs on its own. Bring its result back when it is done.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $prompt).font(.system(size: 13)).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            HStack {
                Text("Agent").font(.system(size: 12.5))
                Segmented(options: [(Backend.claude, "Claude")] + Workspace.shared.acpAgents.map { (Backend.acp($0.id), $0.name) }, selection: $backend)
            }
            Toggle("Own copy of the files (worktree)", isOn: $worktree).toggleStyle(.switch).tint(Theme.accent)
            Text("Keeps the task from editing the same files as this session. Needs a git repository.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
                Button { start() } label: { if busy { ProgressView().controlSize(.small) } else { Text("Start task") } }
                    .buttonStyle(Pill(kind: .primary)).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500)
    }

    private func start() {
        busy = true
        Task {
            do { try await Workspace.shared.delegate(from: parent, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), backend: backend, worktree: worktree); dismiss() }
            catch { self.error = UserError.message(for: error, action: "Start the task"); busy = false }
        }
    }
}

/// Tasks spun off from this session: where each stands, a way to open it, and a way to bring its result back.
struct TasksStrip: View {
    let parent: SessionController
    let ws = Workspace.shared

    var body: some View {
        let kids = ws.children(of: parent.id)
        if !kids.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(kids) { k in
                    let c = ws.controller(k.id)
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        switch c?.state ?? .asleep {
                        case .running: ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                        case .waiting, .reconnecting: Circle().fill(Theme.warn).frame(width: 8, height: 8)
                        case .failed: Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        case .idle: Circle().fill(Theme.ok).frame(width: 8, height: 8)
                        case .asleep: Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                        Text(k.title).font(.system(size: 12)).lineLimit(1)
                        if c?.state == .waiting { Badge(text: "Needs approval", kind: .warn) }
                        Spacer()
                        Button("Open") { ws.select(k.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                        Button("Bring result back") { ws.bringBack(k, into: parent) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.sidebar.opacity(0.5))
        }
    }
}

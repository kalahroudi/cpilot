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
        if let out = try? await Shell.check("claude", ["-p", "--model", "haiku", prompt], cwd: URL(fileURLWithPath: session.meta.workingDirectory), timeout: 120) {
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

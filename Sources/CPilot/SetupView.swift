// SPDX-License-Identifier: MIT

import SwiftUI
import CPilotKit

/// First-run guide. Detects every prerequisite, installs what it can with one button, and turns the rest
/// into copyable commands or links. Shown instead of empty screens until everything is ready.
struct SetupView: View {
    let model = AppModel.shared
    var compact = false
    private var state: SetupState { model.setupState }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let's get CPilot ready").font(.system(size: compact ? 15 : 18, weight: .semibold))
                Text("CPilot found what is missing and can set up most of it for you.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(state.items) { item in
                    step(item)
                    if item.id != state.items.last?.id { Divider() }
                }
            }.padding(.horizontal, 12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))

            // Manual steps: anything the app cannot do itself is shown here with a command to copy or a link to open.
            ForEach(state.missing.filter(manualStep)) { item in manual(item) }

            if state.canAutoInstall {
                HStack(spacing: 10) {
                    Button { model.setUpEverything() } label: {
                        HStack(spacing: 6) { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? "Setting up…" : "Set everything up") }
                    }.buttonStyle(Pill(kind: .primary)).disabled(model.busy)
                    if model.busy, let t = model.runningTask { Text(t.lines.last ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !state.manualCommand.isEmpty {
                    HStack(spacing: 6) {
                        Text("Or run it yourself:").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text(state.manualCommand).font(.system(size: 11.5, design: .monospaced))
                        CopyButton(text: state.manualCommand, label: "Copy command")
                    }
                }
            }
            Button("I did it, check again") { Task { await model.refresh() } }.buttonStyle(Pill())
        }.frame(maxWidth: 520, alignment: .leading)
    }

    private func manualStep(_ item: Prereq) -> Bool {
        switch item.install {
        case .command, .link: return true
        case .brew: return false
        case .none: return false
        }
    }

    @ViewBuilder private func manual(_ item: Prereq) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.title) needs you").font(.system(size: 13, weight: .semibold))
            Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch item.install {
            case .command(let cmd):
                HStack {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    CopyButton(text: cmd, label: "Copy command")
                }
                Text("It may ask for your password, so run it in Terminal where you can see it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .link(let url):
                if let u = URL(string: url) { Link("Open the download page", destination: u).font(.system(size: 12.5)) }
            default: EmptyView()
            }
        }.card()
    }

    private func step(_ item: Prereq) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isMet ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isMet ? Theme.ok : .secondary).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium))
                Text(item.isMet ? "Ready" : item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 9)
    }
}

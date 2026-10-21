// SPDX-License-Identifier: MIT

import SwiftUI
import CPilotKit

/// The menu bar popover: glanceable status, a few quick actions, a way into the Manager. Fixed width, height from content.
/// Keep it light: no lists that grow without bound, and nothing runs while it is closed (AppDelegate drops the views on close).
struct PopoverView: View {
    let model = AppModel.shared
    var openManager: (Pane) -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            if model.loadedOnce, model.needsSetup { SetupView(compact: true) }
            else if !model.loadedOnce { SkeletonList(rows: 4).frame(height: 140) }
            else { content }
            if let task = model.runningTask { TaskStrip(task: task) }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.pane)                                   // an opaque themed background: the popover must follow the app theme
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setPopoverVisible(true) }
        .onDisappear { model.setPopoverVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(size: 34)).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("CPilot").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 6) {
                    StatusDot(color: model.busy ? Theme.warn : Theme.ok)
                    Text(model.runningTask.map { $0.title + "…" } ?? model.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // REPLACE: stat cards, a short list, quick actions.
            Text("Nothing to show yet.").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var footer: some View {
        HStack {
            Button("Open CPilot") { openManager(.overview) }.buttonStyle(Pill(kind: .primary))
            Spacer()
            Button { openManager(.settings) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Quit CPilot").accessibilityLabel("Quit")
        }
    }
}

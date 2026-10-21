// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

// Shared window chrome: pane header, task banner, toast, memory readout.

/// Title, optional subtitle, trailing controls, then optional tabs. Used by every pane so they all look the same.
struct PaneHeader<Trailing: View, Tabs: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var tabs: Tabs
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 19, weight: .semibold))
                    if let s = subtitle { Text(s).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer()
                trailing
            }
            tabs
        }
        .padding(.horizontal, 22).padding(.top, 38).padding(.bottom, Tabs.self == EmptyView.self ? 12 : 0)
        .background(Theme.pane)
        .overlay(alignment: .bottom) { Divider() }
    }
}
extension PaneHeader where Tabs == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) { self.init(title: title, subtitle: subtitle, trailing: trailing, tabs: { EmptyView() }) }
}
extension PaneHeader where Trailing == EmptyView, Tabs == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, tabs: { EmptyView() }) }
}

/// Resident memory of this app, shown in the sidebar so the "light" claim is visible.
enum AppMemory {
    static var megabytes: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static var footprint: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? "\(Int(info.phys_footprint / 1_048_576)) MB" : "–"
    }
}

/// Banner for the running background task; expands to show its log.
struct TaskBanner: View {
    let task: BackgroundTask
    @State private var open = false
    var body: some View {
        VStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(task.title).font(.system(size: 12.5, weight: .medium))
                    Text(task.lines.last ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.soft)
            if open {
                ScrollView { Text(task.lines.suffix(60).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    .frame(height: 140).background(Theme.terminal)
            }
        }.background(Theme.accentSoft)
    }
}

/// Compact one-line version of the task banner, for the popover.
struct TaskStrip: View {
    let task: BackgroundTask
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(task.title).font(.system(size: 12, weight: .medium))
            Text(task.lines.last ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }.padding(8).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToastView: View {
    let model = AppModel.shared
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 10) {
                Text(t.message).font(.system(size: 12.5)).lineLimit(3)
                if let r = t.report { Button("Details") { model.showDetails(r) }.buttonStyle(.link).font(.system(size: 12.5, weight: .semibold)) }
            }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(t.isError ? Theme.danger : Color.primary)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
        }
    }
}

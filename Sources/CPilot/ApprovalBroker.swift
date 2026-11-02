// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CPilotKit

/// Approvals that other apps (the MCP server) or the chief pilot ask for. Each is a card on the Mac and, when remote access is on, on the paired phones;
/// the first answer wins and the other card goes away. An approval nobody answers is denied after three minutes.
/// This is not a modal dialog: a modal one blocks the main actor, so nothing else could answer it.
@MainActor @Observable
final class ApprovalBroker {
    static let shared = ApprovalBroker()
    static let timeout: TimeInterval = 180

    struct Request: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// Pushes and merges: a phone may answer only if you allowed that for it.
        let high: Bool
        let created: Date
    }

    private(set) var pending: [Request] = []
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]

    func ask(_ title: String, detail: String, high: Bool = false) async -> Bool {
        let r = Request(id: UUID().uuidString, title: title, detail: detail, high: high, created: .now)
        pending.append(r)
        ApprovalPanel.shared.refresh()
        AlertCenter.shared.alert(.needs, title: "Approval needed", body: title, tag: "approval-\(r.id)")
        return await withCheckedContinuation { c in
            waiters[r.id] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.timeout))
                self?.answer(r.id, allow: false)
            }
        }
    }

    /// False when the approval was already answered or timed out.
    @discardableResult
    func answer(_ id: String, allow: Bool) -> Bool {
        guard let c = waiters.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        c.resume(returning: allow)
        ApprovalPanel.shared.refresh()
        return true
    }
}

/// A small floating panel that lists the waiting approvals. It appears when there is one and goes away when there is none.
@MainActor
final class ApprovalPanel {
    static let shared = ApprovalPanel()
    private var panel: NSPanel?

    func refresh() {
        let broker = ApprovalBroker.shared
        if broker.pending.isEmpty { panel?.orderOut(nil); return }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: [.titled, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "CPilot needs an answer"
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: ApprovalCards())
            panel = p
        }
        guard let p = panel else { return }
        if !p.isVisible {
            if let screen = NSScreen.main { p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 440, y: screen.visibleFrame.maxY - 220)) }
            p.orderFrontRegardless()
        }
    }
}

private struct ApprovalCards: View {
    let broker = ApprovalBroker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(broker.pending) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.title).font(.system(size: 13, weight: .semibold))
                    Text(r.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack {
                        Button("Allow once") { broker.answer(r.id, allow: true) }.buttonStyle(Pill(kind: .primary))
                        Button("Deny") { broker.answer(r.id, allow: false) }.buttonStyle(Pill(kind: .plain))
                    }
                }
                if r.id != broker.pending.last?.id { Divider() }
            }
        }
        .padding(16).frame(width: 420, alignment: .leading)
    }
}

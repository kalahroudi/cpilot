// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// One decision put to you, in the same words every time: what, why it matters, what CPilot recommends, and what each answer does. The evidence is there if you want it.
struct ProposalCard: View {
    let proposal: Proposal
    var approveLabel = "Approve"
    var declineLabel = "Not now"
    var heading: String?
    let approve: () -> Void
    let decline: () -> Void
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading { Text(heading).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text(proposal.what).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            line("Why it matters", proposal.why)
            line("Recommended", proposal.recommendation)
            HStack(alignment: .top, spacing: 16) {
                line("If you approve", proposal.ifApprove, secondary: true)
                line("If you decline", proposal.ifDecline, secondary: true)
            }
            if !proposal.evidence.isEmpty {
                DisclosureGroup("Evidence (\(proposal.evidence.count))", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, e in
                            Text(e).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 4)
                }.font(.system(size: 12))
            }
            HStack {
                Button(approveLabel, action: approve).buttonStyle(Pill(kind: .primary))
                Button(declineLabel, action: decline).buttonStyle(Pill(kind: .plain))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func line(_ label: String, _ text: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text).font(.system(size: 12.5)).foregroundStyle(secondary ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Memory changes that dreams proposed and are waiting for you, and the ones they made on their own, each with Undo.
struct DreamsPanel: View {
    @State private var open: [Proposal] = []
    @State private var recent: [Proposal] = []
    @State private var message: String?

    var body: some View {
        Group {
            if !open.isEmpty || !recent.isEmpty || message != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if !open.isEmpty { Text("Needs you").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                    ForEach(open) { p in
                        ProposalCard(proposal: p, heading: "Notes for \(p.scope)") {
                            Task { message = await Dreamer.shared.approve(p.id, by: "you"); reload() }
                        } decline: { Dreamer.shared.decline(p.id); reload() }
                    }
                    if !recent.isEmpty {
                        Text("Made by dreams").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, open.isEmpty ? 0 : 4)
                        ForEach(recent) { p in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.what).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                                    Text(p.why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Button("Undo") { message = Dreamer.shared.undo(p.id); reload() }.buttonStyle(Pill(kind: .plain))
                            }
                        }
                    }
                    if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.warn) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.pane)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: Dreamer.changed)) { _ in reload() }
    }

    private func reload() {
        let all = Workspace.shared.proposals.all().filter { $0.kind == "dream" }
        open = all.filter(\.isOpen)
        recent = Array(all.filter { $0.status == .applied }.suffix(5).reversed())
    }
}

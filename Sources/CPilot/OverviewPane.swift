// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// REPLACE with the app's main screen. Keep: PaneHeader on top, content in a ScrollView, cards for groups.
struct OverviewPane: View {
    let model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Overview", subtitle: model.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .standard))" })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        StatusDot(color: model.busy ? Theme.warn : Theme.ok)
                        Text(model.status).font(.system(size: 14, weight: .medium))
                    }.card(padding: 14)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Plain-language help and a glossary. Every option in Settings that introduces a term gets an entry here.
struct HelpPane: View {
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Help")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What is CPilot?").font(.system(size: 14, weight: .semibold))
                    Text("Describe the app in two sentences, then list the terms it uses.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The text field used everywhere: a clear box with a hairline border that lights up when you are typing in it.
struct CPField: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FieldBox { configuration.textFieldStyle(.plain) }
    }
}

private struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    @FocusState private var focused: Bool
    var body: some View {
        content
            .font(.system(size: 13)).focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 1.5 : 1))
    }
}

/// A choice from a short list, drawn like a field with a chevron, instead of the plain system pop-up.
struct Dropdown<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var placeholder = "Choose…"

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button { selection = o.0 } label: { if o.0 == selection { Label(o.1, systemImage: "checkmark") } else { Text(o.1) } }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? placeholder).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(options.contains { $0.0 == selection } ? Color.primary : Color.secondary)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button).buttonStyle(.soft).menuIndicator(.hidden)
    }
}

/// Label above a full-width control, for forms where the control needs room (names, descriptions, lists).
struct FormField<C: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var content: C
    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> C) { self.title = title; self.hint = hint; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            content
            if let h = hint { Text(h).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

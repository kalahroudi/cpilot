// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CPilotKit

/// Textual also defines `Attachment`; this makes the session attachment the one the app means.
typealias Attachment = CPilotKit.Attachment
import AppKit

// MARK: Copy

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Small copy icon. Shows a check for a moment after copying.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var done = false
    var body: some View {
        Button {
            Clipboard.copy(text)
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done = false }
        } label: {
            Image(systemName: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(done ? Theme.ok : .secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Help

/// "?" button that explains a term in plain language.
struct HelpTip: View {
    let title: String
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Text("?").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What is \(title)?")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 280)
        }
    }
}

// MARK: Badges and chips

struct Badge: View {
    enum Kind { case ok, warn, neutral, accent, danger }
    let text: String
    var kind: Kind = .neutral
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
    }
    private var fg: Color { switch kind { case .ok: Theme.ok; case .warn: Theme.warn; case .neutral: .secondary; case .accent: Theme.accent; case .danger: Theme.danger } }
    private var bg: Color { switch kind { case .ok: Theme.ok.opacity(0.14); case .warn: Theme.warnSoft; case .neutral: Theme.fill; case .accent: Theme.accentSoft; case .danger: Theme.dangerSoft } }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

// MARK: Bars

struct UsageBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }.frame(height: height)
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            let pts = values.isEmpty ? [0, 0] : values
            let mx = max(pts.max() ?? 1, 0.0001)
            let step = g.size.width / CGFloat(max(pts.count - 1, 1))
            let line = Path { p in
                for (i, v) in pts.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: g.size.height - CGFloat(v / mx) * (g.size.height - 2) - 1)
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            ZStack {
                Path { p in
                    p.addPath(line)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath()
                }.fill(tint.opacity(0.14))
                line.stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}

// MARK: Tabs

struct TabBar<T: Hashable>: View {
    let tabs: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 20) {
            ForEach(tabs, id: \.0) { tab in
                Button { selection = tab.0 } label: {
                    Text(tab.1).font(.system(size: 13, weight: selection == tab.0 ? .semibold : .regular))
                        .foregroundStyle(selection == tab.0 ? Theme.accent : .secondary)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { if selection == tab.0 { Rectangle().fill(Theme.accent).frame(height: 2) } }
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// Compact segmented pill used inside cards.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                Button { selection = o.0 } label: {
                    Text(o.1).font(.system(size: 12, weight: selection == o.0 ? .semibold : .regular))
                        .lineLimit(1).fixedSize()   // never let a segment wrap inside a narrow settings column
                        .padding(.horizontal, 11).padding(.vertical, 3)
                        .foregroundStyle(selection == o.0 ? Color.primary : .secondary)
                        .background(selection == o.0 ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(selection == o.0 ? 0.15 : 0), radius: 1, y: 1)
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Theme.fill, in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: Search, paging

struct SearchBox: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Pager: View {
    let total: Int
    let noun: String
    @Binding var page: Int
    let pageSize: Int
    var pages: Int { max(1, Int((Double(total) / Double(pageSize)).rounded(.up))) }
    var body: some View {
        HStack {
            let first = total == 0 ? 0 : page * pageSize + 1
            let last = min(total, (page + 1) * pageSize)
            Text("Showing \(first)–\(last) of \(total) \(noun) · \(pageSize) per page").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous page")
            Text("Page \(page + 1) of \(pages)").font(.system(size: 12)).foregroundStyle(.secondary)
            Button { page = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).accessibilityLabel("Next page")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 22).padding(.vertical, 7)
    }
}

// MARK: Loading

/// Pulsing placeholder rows shown until real data has arrived, so a page never appears half loaded.
struct SkeletonList: View {
    var rows = 6
    @State private var on = false
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<rows, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5).fill(Theme.fill).frame(height: 14)
                    .frame(maxWidth: i % 3 == 1 ? .infinity : 520, alignment: .leading)
            }
        }
        .padding(22)
        .opacity(on ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
        .accessibilityLabel("Loading")
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// Pill button. Reads the environment's enabled state, so a disabled button looks disabled (a plain
/// `ButtonStyle` does not do that by itself).
struct Pill: ButtonStyle {
    enum Kind { case primary, plain, danger }
    var kind: Kind = .plain
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, kind: kind) }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size: 12.5, weight: kind == .primary ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke))
                .opacity(enabled && configuration.isPressed ? 0.85 : 1)
        }
        private var foreground: Color {
            guard enabled else { return Color.secondary.opacity(0.75) }
            return kind == .primary ? Theme.onAccent : kind == .danger ? Theme.danger : Color.primary
        }
        private var background: Color {
            guard enabled else { return Theme.fill }
            return kind == .primary ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Theme.card
        }
        private var stroke: Color {
            guard enabled else { return .clear }
            return kind == .primary ? .clear : (kind == .danger ? Theme.danger.opacity(0.4) : Theme.hairline.opacity(2))
        }
    }
}

/// Dims anything custom-drawn (icon buttons, tiles) when it is disabled.
struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.4) }
}
extension View { func dimWhenDisabled() -> some View { modifier(DimWhenDisabled()) } }

// SPDX-License-Identifier: Apache-2.0

import AppKit

/// CPilot's mark: a "C" with a paper-plane dart leaving through its opening, the pilot heading out.
/// One drawing, used by the app icon and the menu bar glyph so they always match.
enum Mark {
    enum Style { case solid, outline, dashed }

    /// Draws into `rect` in a flipped (top-left origin) context.
    static func draw(in rect: NSRect, color: NSColor, style: Style = .solid, plane: Bool = true) {
        let c = NSPoint(x: rect.midX - rect.width * 0.03, y: rect.midY)
        let r = rect.width * 0.37
        let lw = rect.width * (style == .solid ? 0.15 : 0.11)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: 52, endAngle: 308, clockwise: false)
        arc.lineWidth = lw; arc.lineCapStyle = .round
        if style == .dashed { arc.setLineDash([lw * 1.3, lw * 1.1], count: 2, phase: 0) }
        color.setStroke(); color.setFill()
        arc.stroke()
        guard plane else { return }
        // The dart: tip to the right, notched tail, sitting in the gap of the C.
        let u = rect.width
        let dart = NSBezierPath()
        dart.move(to: NSPoint(x: c.x + u * 0.30, y: c.y))
        dart.line(to: NSPoint(x: c.x - u * 0.13, y: c.y - u * 0.17))
        dart.line(to: NSPoint(x: c.x - u * 0.045, y: c.y))
        dart.line(to: NSPoint(x: c.x - u * 0.13, y: c.y + u * 0.17))
        dart.close(); dart.lineJoinStyle = .round
        dart.lineWidth = u * 0.03
        dart.fill(); dart.stroke()
    }
}

// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The menu bar glyph: a "C" ring with a small centre dot. Always a template image so macOS tints it for light and dark bars.
/// State is encoded in the SHAPE, never in colour: filled when a session is working, outline when idle, dashed while busy.
enum StatusIcon {
    enum State { case active, idle, busy, attention }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let c = NSPoint(x: 9, y: 9)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 6, startAngle: 40, endAngle: 320, clockwise: false)
            arc.lineCapStyle = .round
            NSColor.black.setStroke(); NSColor.black.setFill()
            switch state {
            case .idle: arc.lineWidth = 1.6; arc.stroke()
            case .busy: arc.lineWidth = 1.6; arc.setLineDash([3, 2.2], count: 2, phase: 0); arc.stroke()
            case .active, .attention: arc.lineWidth = 2.6; arc.stroke(); NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
            }
            if state == .attention { NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }
}

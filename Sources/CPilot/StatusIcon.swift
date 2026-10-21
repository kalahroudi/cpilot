// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The menu bar glyph. Always a template image so macOS tints it for light and dark bars.
/// Encode state in the SHAPE (filled / outline / dashed), never in colour: template images have no colour.
/// REPLACE the drawing with the app's own mark.
enum StatusIcon {
    enum State { case active, idle, busy }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
            NSColor.black.setFill(); NSColor.black.setStroke()
            switch state {
            case .active: ring.fill()
            case .idle: ring.lineWidth = 1.5; ring.stroke()
            case .busy: ring.lineWidth = 1.5; ring.setLineDash([3, 2], count: 2, phase: 0); ring.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

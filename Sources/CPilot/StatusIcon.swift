// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The menu bar glyph: a "C" ring with a small centre dot. Always a template image so macOS tints it for light and dark bars.
/// State is encoded in the SHAPE, never in colour: filled when a session is working, outline when idle, dashed while busy.
enum StatusIcon {
    enum State { case active, idle, busy, attention }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let mark = rect.insetBy(dx: 0.5, dy: 0.5)
            switch state {
            case .idle: Mark.draw(in: mark, color: .black, style: .outline, plane: false)
            case .busy: Mark.draw(in: mark, color: .black, style: .dashed)
            case .active, .attention: Mark.draw(in: mark, color: .black, style: .solid)
            }
            if state == .attention { NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The app icon, drawn in code so the build needs no image tools and stays crisp at every size.
enum AppIcon {
    /// - padded: leave the transparent margin macOS expects around Dock icons (824 of 1024).
    static func image(size: CGFloat, padded: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / 1024
            let inset: CGFloat = padded ? 100 : 0
            let tile = NSRect(x: inset * s, y: inset * s, width: (1024 - 2 * inset) * s, height: (1024 - 2 * inset) * s)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2246, yRadius: tile.width * 0.2246)
            // Night-sky gradient, a soft horizon glow at the bottom, then the mark.
            NSGradient(starting: NSColor(srgbRed: 0.40, green: 0.38, blue: 0.98, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.12, blue: 0.45, alpha: 1))?
                .draw(in: shape, angle: -62)
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0), NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0.5)])?
                .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height * 0.5), angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            let markRect = tile.insetBy(dx: tile.width * 0.16, dy: tile.width * 0.16)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = tile.width * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -tile.width * 0.015); shadow.set()
            Mark.draw(in: markRect, color: .white)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Writes an .iconset folder for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                          ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let tiff = image(size: px, padded: true).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
        }
    }
}

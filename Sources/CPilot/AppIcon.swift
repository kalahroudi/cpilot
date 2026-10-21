// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The app icon, drawn in code so the build needs no image tools and stays crisp at every size.
/// REPLACE the gradient and glyph with the app's own mark (keep the structure: squircle tile, padded Dock variant).
enum AppIcon {
    /// - padded: leave the transparent margin macOS expects around Dock icons (824 of 1024).
    static func image(size: CGFloat, padded: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / 1024
            let inset: CGFloat = padded ? 100 : 0
            let tile = NSRect(x: inset * s, y: inset * s, width: (1024 - 2 * inset) * s, height: (1024 - 2 * inset) * s)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2246, yRadius: tile.width * 0.2246)
            NSGradient(starting: NSColor(srgbRed: 0.078, green: 0.439, blue: 0.486, alpha: 1), ending: NSColor(srgbRed: 0.027, green: 0.165, blue: 0.216, alpha: 1))?
                .draw(in: shape, angle: -55)
            let d = tile.width * 0.42
            let dot = NSBezierPath(ovalIn: NSRect(x: tile.midX - d / 2, y: tile.midY - d / 2, width: d, height: d))
            NSColor.white.setFill(); dot.fill()
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

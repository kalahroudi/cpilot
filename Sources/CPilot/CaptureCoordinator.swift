// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Carbon.HIToolbox
import LocalAuthentication
import UniformTypeIdentifiers
import CPilotKit

/// Fingerprint or password prompt, used before turning on Full access.
enum Biometrics {
    @MainActor static func confirm(_ reason: String, done: @escaping @MainActor (Bool) -> Void) {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in Task { @MainActor in done(ok) } }
    }
}

/// Turns screenshots, selected text, copied things and the front browser page into attachments on the active session.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private let ws = Workspace.shared

    private func target(_ s: SessionController?) -> SessionController? {
        s ?? ws.current ?? ws.live.first
    }

    private func attach(_ a: Attachment, to s: SessionController?) {
        guard let t = target(s) else { AppModel.shared.show("Open a session first, then capture again.", error: true); return }
        t.attachments.append(a)
        if s == nil { AppDelegate.shared.showManager(); ws.select(t.id) }
    }

    func capture(into s: SessionController? = nil, window: Bool) {
        Task {
            if s == nil { for w in NSApp.windows where w.isVisible && !(w is NSPanel) { w.orderBack(nil) } }   // get out of the way
            guard let a = await Capture.screenshot(window: window, to: AppPaths().capturesDir) else { NSApp.activate(ignoringOtherApps: true); return }
            var kept = a
            if let t = target(s) {
                let dest = ws.store.attachmentsDir(t.id).appendingPathComponent(URL(fileURLWithPath: a.value).lastPathComponent)
                try? FileManager.default.moveItem(atPath: a.value, toPath: dest.path)
                kept.value = dest.path
            }
            attach(kept, to: s)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func addBrowserPage(to s: SessionController?) {
        Task {
            guard let page = await Capture.frontBrowserPage() else { AppModel.shared.show("No supported browser page is in front.", error: true); return }
            attach(Capture.link(title: page.title, url: page.url, source: page.app), to: s)
        }
    }

    func addClipboard(to s: SessionController?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { addFiles(urls, to: s); return }
        if let img = NSImage(pasteboard: pb), let png = img.pngData() { saveImage(png, to: s); return }
        if let text = pb.string(forType: .string), !text.isEmpty {
            if let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true {
                attach(Capture.link(title: u.host ?? text, url: u.absoluteString, source: "Clipboard"), to: s)
            } else { attach(Capture.snippet(text, source: "Clipboard"), to: s) }
        } else { AppModel.shared.show("The clipboard is empty.", error: true) }
    }

    /// Copies whatever is selected in the front app (needs the Accessibility permission, which macOS asks for once).
    func addSelection(to s: SessionController?) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { AppModel.shared.show("Allow CPilot in Privacy & Security → Accessibility, then try again.", error: true); return }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            e?.flags = .maskCommand; e?.post(tap: .cghidEventTap)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard pb.changeCount != before, let text = pb.string(forType: .string), !text.isEmpty else { AppModel.shared.show("Nothing was selected.", error: true); return }
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            attach(Capture.snippet(text, source: app), to: s)
        }
    }

    func paste(_ providers: [NSItemProvider], into s: SessionController, preferFile: Bool = false) {
        for p in providers {
            let isFile = p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !(preferFile && isFile) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = NSImage(data: data)?.pngData() else { return }
                    Task { @MainActor in self.saveImage(png, to: s) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in self.addFiles([url], to: s) } } }
            }
        }
    }

    /// Dropped items: files keep their path (images included); images with no file behind them (from a browser or Photos) are saved as pasted ones.
    func drop(_ providers: [NSItemProvider], into s: SessionController) -> Bool {
        var took = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                paste([p], into: s, preferFile: true)
            }
        }
        return took
    }

    func addFiles(_ urls: [URL], to s: SessionController?) {
        for u in urls {
            let isImage = UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false
            attach(Attachment(kind: isImage ? .image : .file, title: u.lastPathComponent, value: u.path, source: "File"), to: s)
        }
    }

    private func saveImage(_ png: Data, to s: SessionController?) {
        guard let t = target(s) else { return }
        let url = ws.store.attachmentsDir(t.id).appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).png")
        try? png.write(to: url)
        attach(Attachment(kind: .image, title: "Pasted image", value: url.path, source: "Clipboard"), to: s)
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let t = tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A system-wide shortcut (Control-Option-Command-C) through Carbon, which needs no permission and stays reliable.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ on: Bool, action: @escaping @MainActor () -> Void) {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        guard on else { return }
        Hotkey.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in Task { @MainActor in Hotkey.action?() }; return noErr }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4350_4C54), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }
    nonisolated(unsafe) private static var action: (@MainActor () -> Void)?
}

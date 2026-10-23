// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit
import CPilotKit

/// What the render window shows: a file in the session's folder, read here or over SSH.
struct RenderTarget: Identifiable {
    let file: ArtifactFile
    let root: String
    let env: EnvironmentConfig?
    var id: String { file.path }
}

/// Draws a page, vector image, PDF or picture the agent wrote, so you can see it without reaching the folder.
struct RenderSheet: View {
    let target: RenderTarget
    @Environment(\.dismiss) private var dismiss
    @State private var reloads = 0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(Artifacts.display(target.file.path, root: target.root)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button("Reload") { reloads += 1 }.buttonStyle(.soft).foregroundStyle(Theme.accent).keyboardShortcut("r", modifiers: .command)
                if target.env == nil {
                    Button("Open in browser") { NSWorkspace.shared.open(URL(fileURLWithPath: target.file.path)) }.buttonStyle(.soft).foregroundStyle(Theme.accent)
                }
                Button("Close") { dismiss() }.buttonStyle(Pill(kind: .plain)).keyboardShortcut(.cancelAction)
            }.font(.system(size: 12)).padding(12)
            Divider()
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { RenderedFile(target: target, reloads: reloads, error: $error).id(reloads) }
        }.frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 700)
    }
}

private struct RenderedFile: NSViewRepresentable {
    let target: RenderTarget
    let reloads: Int
    @Binding var error: String?

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        load(web)
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}

    private func load(_ web: WKWebView) {
        let f = target.file
        if target.env == nil {
            let url = URL(fileURLWithPath: f.path)
            guard FileManager.default.fileExists(atPath: f.path) else { error = "This file no longer exists."; return }
            // Read access to the whole folder so a page's own images, styles and scripts resolve.
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: target.root))
            return
        }
        // On a server the file is fetched once (capped) and handed over as data.
        Task { @MainActor in
            do {
                let size = Int(try await Exec.with(target.env) { try await Shell.check("stat", ["-c", "%s", f.path], timeout: 20) }.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                guard size <= 8_000_000 else { error = "This file is too large to render from a server."; return }
                let b64 = try await Exec.with(target.env) { try await Shell.check("base64", [f.path], timeout: 60) }
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { error = "Could not read this file."; return }
                web.load(data, mimeType: Self.mime(f.path), characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
            } catch { self.error = "Could not read this file." }
        }
    }

    static func mime(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}

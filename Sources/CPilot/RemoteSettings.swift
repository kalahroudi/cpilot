// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import CPilotKit

/// Settings, Remote: turn phone access on, pair a phone with a QR code, and see or revoke the paired devices.
struct RemoteSettings: View {
    let prefs = Prefs.shared
    let server = RemoteServer.shared
    @State private var devices: [RemoteDevice] = []
    @State private var pairing: (code: String, until: Date)?
    @State private var now = Date()

    var body: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Phone access") {
                SettingRow("Control CPilot from your phone", "Starts a small web server on this Mac that only your tailnet can reach, over HTTPS through Tailscale. Nothing is opened to the internet. You need Tailscale on this Mac and on the phone, with MagicDNS and HTTPS turned on for your tailnet.") {
                    Toggle("", isOn: Binding(get: { prefs.remoteEnabled }, set: { on in prefs.remoteEnabled = on; Task { on ? await server.start() : await server.stop() } }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingRow("Address", statusDetail, error: failure) {
                    if let url = server.url { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }.buttonStyle(Pill(kind: .plain)) }
                }
            }
            if server.url != nil {
                SettingsGroup("Pair a phone") {
                    SettingRow("Pair a new device", "Asks for your fingerprint or password, then shows one QR code that opens CPilot on the phone and signs it in. It works once and for two minutes. If you cannot scan it, open the address and type the code.") {
                        Button("Show pairing code") { Biometrics.confirm("Pair a phone with CPilot") { ok in if ok { makeCode() } } }.buttonStyle(Pill(kind: .primary))
                    }
                    if let pairing, pairing.until > now, let url = server.url {
                        HStack(alignment: .center, spacing: 16) {
                            if let img = Self.qr("\(url.absoluteString)/#pair=\(pairing.code)") { Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Scan with the phone's camera").font(.system(size: 13, weight: .medium))
                                Text("Address  \(url.absoluteString)").font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("Code  \(pairing.code)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("An iPhone's Home Screen icon keeps its own sign-in. If you add the page to the Home Screen and it asks to pair again, make a new code and type it in.").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("Expires in \(Int(pairing.until.timeIntervalSince(now))) seconds").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.vertical, 12)
                    }
                }
            }
            SettingsGroup("Paired devices") {
                if devices.isEmpty { SettingRow("No devices yet", "A paired phone appears here. Revoking one signs it out at once.") { EmptyView() } }
                ForEach(devices) { d in
                    SettingRow(d.name, "Paired \(d.createdAt.formatted(date: .abbreviated, time: .omitted))" + (d.lastSeen.map { ", last seen \($0.formatted(.relative(presentation: .named)))" } ?? "")) {
                        HStack(spacing: 10) {
                            Toggle("Approve push and merge", isOn: Binding(get: { d.canApprove }, set: { on in setApprove(d, on) })).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 12))
                            Button("Revoke") { server.devices.revoke(d.id); reload() }.buttonStyle(Pill(kind: .danger))
                        }
                    }
                }
            }
            SettingsGroup("What a phone can do") {
                SettingRow("Limits", "A phone can start sessions (at most Edit files, in their own worktree, only in repositories CPilot knows), message and stop sessions, talk to the chief pilot, and allow a tool request once. It cannot turn on Full access or allow \"always\". Pushing and merging can be approved from a phone only if you switch that on for it here. Every action is written to the audit log with the device's name.") { EmptyView() }
                SettingRow("Keeps this Mac awake", "While phone access is on and an agent is working, the Mac does not go to sleep on its own. Closing the lid still sleeps it.") { EmptyView() }
            }
        }
        .task { while !Task.isCancelled { reload(); now = Date(); try? await Task.sleep(for: .seconds(1)) } }
    }

    private var statusDetail: String {
        switch server.status {
        case .off: "Off."
        case .starting: "Starting…"
        case .on(let u): u.absoluteString
        case .failed: "Not running."
        }
    }
    private var failure: String? { if case .failed(let why) = server.status { return why }; return nil }

    private func reload() { devices = server.devices.all }
    private func makeCode() { pairing = (server.devices.makeCode(), Date().addingTimeInterval(RemoteDeviceStore.codeLifetime)) }

    private func setApprove(_ d: RemoteDevice, _ on: Bool) {
        if !on { server.devices.setCanApprove(d.id, false); reload(); return }
        Biometrics.confirm("Let \(d.name) approve pushes and merges") { ok in if ok { server.devices.setCanApprove(d.id, true); reload() } }
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

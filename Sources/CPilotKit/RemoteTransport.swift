// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How the phone reaches the remote listener, which itself only ever listens on 127.0.0.1. A transport publishes that port and says where it can be opened.
/// Tailscale is the only one today; another (a Cloudflare tunnel) is one more conformance, with no change to the server.
public protocol RemoteTransport: Sendable {
    var name: String { get }
    /// Publishes `port`; returns the address a phone opens.
    func start(port: Int) async throws -> URL
    func stop() async
}

public enum TailscaleError: Error, LocalizedError, Equatable {
    case notInstalled, notRunning, noName, failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Tailscale is not installed. Install it from tailscale.com and sign in."
        case .notRunning: "Tailscale is installed but not connected. Open it and sign in."
        case .noName: "Tailscale did not report a name for this Mac. Turn on MagicDNS and HTTPS certificates for your tailnet."
        case .failed(let why): "Tailscale could not publish the port: \(why)"
        }
    }
}

/// `tailscale serve` terminates HTTPS on the tailnet and forwards to the loopback port, so nothing is public and the phone gets a real certificate.
public struct TailscaleTransport: RemoteTransport {
    public let name = "Tailscale"
    public init() {}

    /// The Mac's tailnet name from `tailscale status --json` (its `Self.DNSName`, without the trailing dot), or nil when not connected.
    public static func dnsName(fromStatus json: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        if let state = o["BackendState"] as? String, state != "Running" { return nil }
        guard let me = o["Self"] as? [String: Any], var n = me["DNSName"] as? String, !n.isEmpty else { return nil }
        if n.hasSuffix(".") { n.removeLast() }
        return n
    }

    public static func serveArguments(port: Int) -> [String] { ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"] }
    public static func resetArguments() -> [String] { ["serve", "--https=443", "off"] }

    private static func executable() -> String? {
        Shell.find("tailscale") ?? ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { executable() != nil }

    public func start(port: Int) async throws -> URL {
        guard let tool = Self.executable() else { throw TailscaleError.notInstalled }
        let status = try await Shell.run(tool, ["status", "--json"])
        guard let host = Self.dnsName(fromStatus: Data(status.stdout.utf8)) else { throw status.ok ? TailscaleError.noName : TailscaleError.notRunning }
        let serve = try await Shell.run(tool, Self.serveArguments(port: port), timeout: 30)
        guard serve.ok else { throw TailscaleError.failed(String((serve.stderr.isEmpty ? serve.stdout : serve.stderr).prefix(300))) }
        guard let url = URL(string: "https://\(host)") else { throw TailscaleError.noName }
        return url
    }

    public func stop() async {
        guard let tool = Self.executable() else { return }
        _ = try? await Shell.run(tool, Self.resetArguments(), timeout: 15)
    }
}

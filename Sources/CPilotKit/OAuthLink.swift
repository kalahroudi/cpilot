// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A sign-in link an agent printed. The agent is waiting on `callbackPort` (on its own machine) for the browser to be sent back there.
public struct OAuthLink: Equatable, Sendable {
    public var url: URL
    public var callbackPort: Int?

    /// The first web link in `text` (terminal colour codes and hyperlink wrappers are skipped), with the local port its `redirect_uri` points to.
    public static func find(in text: String) -> OAuthLink? {
        // A hyperlink wrapper holds the address itself, so keep it as text before the other codes are dropped.
        var clean = text.replacingOccurrences(of: "\u{1B}\\]8;[^;\u{07}\u{1B}]*;([^\u{07}\u{1B}]*)(?:\u{07}|\u{1B}\\\\)", with: " $1 ", options: .regularExpression)
        for pattern in ["\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", "\u{1B}\\[[0-?]*[ -/]*[@-~]"] {
            clean = clean.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        guard let r = clean.range(of: #"https?://[^\s<>"'`\\^{}|]+"#, options: .regularExpression), let url = URL(string: String(clean[r])), url.host?.isEmpty == false else { return nil }
        return OAuthLink(url: url, callbackPort: callbackPort(of: url))
    }

    public static func callbackPort(of url: URL) -> Int? {
        let names: Set<String> = ["redirect_uri", "redirect_url", "redirecturi", "redirecturl"]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where names.contains(item.name.lowercased()) {
            guard let v = item.value, let redirect = URL(string: v), let host = redirect.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
                  let port = redirect.port, (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }
}

/// Like `ssh -L port:127.0.0.1:port`: while it runs, the sign-in page's redirect to localhost on this Mac reaches the agent on the server.
public final class SSHForward: @unchecked Sendable {
    private let process = Process()

    public init(_ e: EnvironmentConfig, port: Int) throws {
        process.executableURL = URL(fileURLWithPath: SSH.executable)
        process.arguments = SSH.baseArgs(e, shareConnection: false) + ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "\(port):127.0.0.1:\(port)", e.target]
        process.environment = SSH.environment(for: e)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }

    public func stop() { if process.isRunning { process.terminate() } }
}

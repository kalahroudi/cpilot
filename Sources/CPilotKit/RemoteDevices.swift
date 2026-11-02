// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// A phone (or any browser) that was paired with this Mac. Only a hash of its token is kept, so the file cannot be used to sign in.
public struct RemoteDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var createdAt: Date
    public var lastSeen: Date?
    /// May answer the approvals that push or merge. Off until you turn it on at the Mac.
    public var canApprove: Bool
}

/// The paired devices, the one-time pairing codes, and the limits on what a device may do. Thread safe.
public final class RemoteDeviceStore: @unchecked Sendable {
    public static let codeLifetime: TimeInterval = 120
    private let url: URL?
    private let lock = NSLock()
    private var devices: [RemoteDevice]
    private var codes: [String: Date] = [:]
    private var failures: [Date] = []
    private var starts: [String: [Date]] = [:]

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL? = AppPaths().root.appendingPathComponent("remote-devices.json")) {
        self.url = url
        devices = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([RemoteDevice].self, from: $0) } ?? []
    }

    public static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    public var all: [RemoteDevice] { lock.lock(); defer { lock.unlock() }; return devices.sorted { $0.createdAt < $1.createdAt } }

    // MARK: Pairing

    /// A code the Mac shows as a QR code. It works once and only for two minutes.
    public func makeCode(now: Date = .now) -> String {
        lock.lock(); defer { lock.unlock() }
        codes = codes.filter { $0.value > now }
        let code = Self.random(12)
        codes[code] = now.addingTimeInterval(Self.codeLifetime)
        return code
    }

    public enum PairError: Error, Equatable { case badCode, locked }

    /// Trades a pairing code for a device token (shown once). Too many wrong codes in a minute lock pairing for a while.
    public func pair(code: String, name: String, now: Date = .now) -> Result<(device: RemoteDevice, token: String), PairError> {
        lock.lock(); defer { lock.unlock() }
        failures = failures.filter { now.timeIntervalSince($0) < 60 }
        if failures.count >= 5 { return .failure(.locked) }
        codes = codes.filter { $0.value > now }
        guard codes.removeValue(forKey: code) != nil else { failures.append(now); return .failure(.badCode) }
        let token = Self.random(32)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteDevice(id: Self.random(6), name: clean.isEmpty ? "Phone" : String(clean.prefix(40)), tokenHash: Self.hash(token), createdAt: now, lastSeen: now, canApprove: false)
        devices.append(device)
        save()
        return .success((device, token))
    }

    // MARK: Using a token

    /// The device a token belongs to, if any. Compares hashes, so the comparison does not depend on the token's content.
    public func device(for token: String?, now: Date = .now) -> RemoteDevice? {
        guard let token, !token.isEmpty else { return nil }
        let h = Self.hash(token)
        lock.lock(); defer { lock.unlock() }
        guard let i = devices.firstIndex(where: { $0.tokenHash == h }) else { return nil }
        // Written out at most once a minute, so a busy phone does not rewrite the file on every request.
        if devices[i].lastSeen.map({ now.timeIntervalSince($0) > 60 }) ?? true { devices[i].lastSeen = now; save() }
        return devices[i]
    }

    public func revoke(_ id: String) { lock.lock(); devices.removeAll { $0.id == id }; starts[id] = nil; save(); lock.unlock() }

    public func setCanApprove(_ id: String, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].canApprove = on; save() }
    }

    /// Session starts per device per hour. Returns false once the device is over its limit.
    public func allowStart(device id: String, limit: Int = 10, now: Date = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var l = (starts[id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard l.count < limit else { starts[id] = l; return false }
        l.append(now); starts[id] = l
        return true
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

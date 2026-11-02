// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// What a browser gives a page when it subscribes to push: where to send, and the keys that make only that browser able to read it.
public struct PushSubscription: Codable, Equatable, Sendable {
    public var endpoint: String
    /// The browser's public key (65 bytes, base64url) and its 16-byte authentication secret.
    public var p256dh: String
    public var auth: String
    public init(endpoint: String, p256dh: String, auth: String) { self.endpoint = endpoint; self.p256dh = p256dh; self.auth = auth }

    /// Push services a browser can legitimately hand out. Anything else is refused, so a paired device cannot make the Mac send requests to an address of its choosing.
    static let serviceSuffixes = ["googleapis.com", "push.services.mozilla.com", "push.apple.com", "notify.windows.com"]

    /// A usable subscription: a known push service over HTTPS (or this Mac's own loopback, for development), a real public key and a 16-byte secret.
    public func isAcceptable(allowLoopback: Bool = false) -> Bool {
        guard let url = URL(string: endpoint), let host = url.host?.lowercased() else { return false }
        let known = url.scheme == "https" && Self.serviceSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        let loop = allowLoopback && url.scheme == "http" && (host == "127.0.0.1" || host == "localhost")
        guard known || loop else { return false }
        guard let pub = Base64URL.decode(p256dh), pub.count == 65, (try? P256.KeyAgreement.PublicKey(x963Representation: pub)) != nil else { return false }
        return Base64URL.decode(auth)?.count == 16
    }

    /// The origin of the push service, which is the audience of the VAPID token.
    public var audience: String? {
        guard let u = URL(string: endpoint), let scheme = u.scheme, let host = u.host else { return nil }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }
}

/// Web Push message encryption (RFC 8291, with the aes128gcm content coding of RFC 8188): one record, readable only by the subscribed browser.
public enum WebPush {
    public enum Failure: Error, Equatable { case badKey, tooLong, badMessage }
    static let recordSize = 4096
    /// Plaintext that fits in the one record, leaving room for the tag and the delimiter.
    public static let maxPayload = recordSize - 16 - 1

    struct Keys { var ecdh: Data; var cek: Data; var nonce: Data }

    private static func derive(shared: Data, auth: Data, salt: Data, uaPublic: Data, asPublic: Data) -> Keys {
        let prkKey = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: shared), salt: auth)
        let keyInfo = Data("WebPush: info\0".utf8) + uaPublic + asPublic
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prkKey, info: keyInfo, outputByteCount: 32)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        return Keys(ecdh: shared, cek: cek.withUnsafeBytes { Data($0) }, nonce: nonce.withUnsafeBytes { Data($0) })
    }

    /// The request body for one message. `senderKey` and `salt` are random unless a test fixes them.
    public static func encrypt(_ payload: Data, to sub: PushSubscription, senderKey: P256.KeyAgreement.PrivateKey = .init(), salt: Data? = nil) throws -> Data {
        guard payload.count <= maxPayload else { throw Failure.tooLong }
        guard let uaPublic = Base64URL.decode(sub.p256dh), let auth = Base64URL.decode(sub.auth), auth.count == 16,
              let uaKey = try? P256.KeyAgreement.PublicKey(x963Representation: uaPublic),
              let shared = try? senderKey.sharedSecretFromKeyAgreement(with: uaKey) else { throw Failure.badKey }
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let asPublic = senderKey.publicKey.x963Representation
        let k = derive(shared: shared.withUnsafeBytes { Data($0) }, auth: auth, salt: salt, uaPublic: uaPublic, asPublic: asPublic)
        let sealed = try AES.GCM.seal(payload + Data([0x02]), using: SymmetricKey(data: k.cek), nonce: AES.GCM.Nonce(data: k.nonce))
        var header = salt
        header.append(contentsOf: withUnsafeBytes(of: UInt32(recordSize).bigEndian) { Array($0) })
        header.append(UInt8(asPublic.count))
        return header + asPublic + sealed.ciphertext + sealed.tag
    }

    /// Reads a message the way the browser does. Only tests need this.
    public static func decrypt(_ body: Data, receiverKey: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        guard body.count > 86 + 16 else { throw Failure.badMessage }
        let salt = body.prefix(16), idLen = Int(body[20])
        guard body.count > 21 + idLen + 16, let asKey = try? P256.KeyAgreement.PublicKey(x963Representation: body[21..<(21 + idLen)]),
              let shared = try? receiverKey.sharedSecretFromKeyAgreement(with: asKey) else { throw Failure.badMessage }
        let k = derive(shared: shared.withUnsafeBytes { Data($0) }, auth: auth, salt: Data(salt), uaPublic: receiverKey.publicKey.x963Representation, asPublic: Data(body[21..<(21 + idLen)]))
        let rest = body[(21 + idLen)...]
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: k.nonce), ciphertext: rest.dropLast(16), tag: rest.suffix(16))
        var plain = try AES.GCM.open(box, using: SymmetricKey(data: k.cek))
        guard let end = plain.lastIndex(where: { $0 != 0 }), plain[end] == 0x02 else { throw Failure.badMessage }
        plain.removeSubrange(end...)
        return plain
    }

    static func keysForTesting(senderKey: P256.KeyAgreement.PrivateKey, receiver: PushSubscription, salt: Data) -> (ecdh: Data, cek: Data, nonce: Data)? {
        guard let ua = Base64URL.decode(receiver.p256dh), let auth = Base64URL.decode(receiver.auth),
              let uaKey = try? P256.KeyAgreement.PublicKey(x963Representation: ua), let s = try? senderKey.sharedSecretFromKeyAgreement(with: uaKey) else { return nil }
        let k = derive(shared: s.withUnsafeBytes { Data($0) }, auth: auth, salt: salt, uaPublic: ua, asPublic: senderKey.publicKey.x963Representation)
        return (k.ecdh, k.cek, k.nonce)
    }
}

/// The Mac's identity toward push services (RFC 8292): a key made once and kept in a file only you can read. Browsers subscribe to its public half,
/// so only this Mac can send them messages.
public struct VAPIDKeys: Sendable {
    public let key: P256.Signing.PrivateKey
    public init(key: P256.Signing.PrivateKey = .init()) { self.key = key }

    /// The public key a page passes to `pushManager.subscribe`, 65 bytes, base64url.
    public var publicKey: String { Base64URL.encode(key.publicKey.x963Representation) }

    public static func loadOrCreate(at url: URL = AppPaths().root.appendingPathComponent("vapid.key")) -> VAPIDKeys {
        if let text = try? String(contentsOf: url, encoding: .utf8), let raw = Base64URL.decode(text), let k = try? P256.Signing.PrivateKey(rawRepresentation: raw) { return VAPIDKeys(key: k) }
        let keys = VAPIDKeys()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Base64URL.encode(keys.key.rawRepresentation).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return keys
    }

    /// The `Authorization` header value for one push service. `subject` says who is sending (an https address or mailto).
    public func authorization(audience: String, subject: String, now: Date = .now, lifetime: TimeInterval = 12 * 3600) throws -> String {
        func part(_ o: [String: Any]) throws -> String { Base64URL.encode(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) }
        let input = try part(["typ": "JWT", "alg": "ES256"]) + "." + part(["aud": audience, "exp": Int(now.timeIntervalSince1970 + lifetime), "sub": subject])
        let sig = try key.signature(for: Data(input.utf8)).rawRepresentation
        return "vapid t=\(input).\(Base64URL.encode(sig)), k=\(publicKey)"
    }
}

public enum PushResult: Equatable, Sendable {
    case sent
    /// The browser unsubscribed or the subscription expired: forget it.
    case gone
    case failed(String)
}

public enum WebPushSender {
    public static func send(_ message: Data, to sub: PushSubscription, keys: VAPIDKeys, subject: String, ttl: Int = 3600, session: URLSession = .shared) async -> PushResult {
        guard let url = URL(string: sub.endpoint), let audience = sub.audience else { return .failed("Bad endpoint.") }
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.httpBody = try WebPush.encrypt(message, to: sub)
            req.setValue(try keys.authorization(audience: audience, subject: subject), forHTTPHeaderField: "Authorization")
            req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(String(ttl), forHTTPHeaderField: "TTL")
            req.setValue("high", forHTTPHeaderField: "Urgency")
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299: return .sent
            case 404, 410: return .gone
            default: return .failed("The push service answered \(code).")
            }
        } catch { return .failed(error.localizedDescription) }
    }
}

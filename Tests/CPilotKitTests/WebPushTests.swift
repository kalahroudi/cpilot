// SPDX-License-Identifier: Apache-2.0

import XCTest
import CryptoKit
@testable import CPilotKit

final class WebPushTests: XCTestCase {
    // The example in RFC 8291, section 5 and appendix A.
    private let uaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
    private let uaPublic = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    private let asPrivate = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
    private let asPublic = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
    private let authSecret = "BTBZMqHH6r4Tts7J_aSIgg"
    private let salt = "DGv6ra1nlYgDCS1FRnbzlw"
    private let body = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    private var sub: PushSubscription { PushSubscription(endpoint: "https://push.example/x", p256dh: uaPublic, auth: authSecret) }
    private func key(_ s: String) throws -> P256.KeyAgreement.PrivateKey { try P256.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Base64URL.decode(s))) }

    func testKeyDerivationMatchesTheRFCStepByStep() throws {
        let sender = try key(asPrivate)
        XCTAssertEqual(Base64URL.encode(sender.publicKey.x963Representation), asPublic)
        let k = try XCTUnwrap(WebPush.keysForTesting(senderKey: sender, receiver: sub, salt: XCTUnwrap(Base64URL.decode(salt))))
        XCTAssertEqual(Base64URL.encode(k.ecdh), "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs")
        XCTAssertEqual(Base64URL.encode(k.cek), "oIhVW04MRdy2XN9CiKLxTg")
        XCTAssertEqual(Base64URL.encode(k.nonce), "4h_95klXJ5E_qnoN")
    }

    func testEncryptedBodyIsExactlyTheRFCExample() throws {
        let out = try WebPush.encrypt(Data("When I grow up, I want to be a watermelon".utf8), to: sub, senderKey: key(asPrivate), salt: XCTUnwrap(Base64URL.decode(salt)))
        XCTAssertEqual(Base64URL.encode(out), body)
    }

    func testTheBrowserCanReadWhatWasSent() throws {
        let receiver = try key(uaPrivate), auth = try XCTUnwrap(Base64URL.decode(authSecret))
        XCTAssertEqual(String(decoding: try WebPush.decrypt(XCTUnwrap(Base64URL.decode(body)), receiverKey: receiver, auth: auth), as: UTF8.self), "When I grow up, I want to be a watermelon")
        // a fresh random sender and salt
        let msg = Data(#"{"title":"CPilot needs you","body":"Edit in parley · naïve ✓"}"#.utf8)
        let sent = try WebPush.encrypt(msg, to: sub)
        XCTAssertEqual(try WebPush.decrypt(sent, receiverKey: receiver, auth: auth), msg)
        XCTAssertNotEqual(sent, try WebPush.encrypt(msg, to: sub), "each message uses its own sender key and salt")
    }

    func testWrongReceiverOrTamperedMessageIsRefused() throws {
        let auth = try XCTUnwrap(Base64URL.decode(authSecret))
        var sent = try WebPush.encrypt(Data("hello".utf8), to: sub)
        XCTAssertThrowsError(try WebPush.decrypt(sent, receiverKey: P256.KeyAgreement.PrivateKey(), auth: auth))
        sent[sent.count - 3] ^= 0xFF
        XCTAssertThrowsError(try WebPush.decrypt(sent, receiverKey: key(uaPrivate), auth: auth))
        XCTAssertThrowsError(try WebPush.encrypt(Data(repeating: 65, count: WebPush.maxPayload + 1), to: sub))
        XCTAssertNoThrow(try WebPush.encrypt(Data(repeating: 65, count: WebPush.maxPayload), to: sub))
        XCTAssertThrowsError(try WebPush.encrypt(Data("x".utf8), to: PushSubscription(endpoint: "https://push.example", p256dh: "AAAA", auth: authSecret)))
    }

    func testVAPIDTokenVerifiesAndCarriesTheClaims() throws {
        let keys = VAPIDKeys()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = try keys.authorization(audience: "https://web.push.apple.com", subject: "https://mac.tail.ts.net", now: now)
        XCTAssertTrue(header.hasPrefix("vapid t=")); XCTAssertTrue(header.hasSuffix(", k=\(keys.publicKey)"))
        let jwt = String(header.dropFirst("vapid t=".count).split(separator: ",")[0]).split(separator: ".").map(String.init)
        XCTAssertEqual(jwt.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Base64URL.decode(jwt[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://web.push.apple.com"); XCTAssertEqual(claims["sub"] as? String, "https://mac.tail.ts.net")
        XCTAssertEqual(claims["exp"] as? Int, 1_800_000_000 + 12 * 3600)
        let pub = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Base64URL.decode(keys.publicKey)))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Base64URL.decode(jwt[2])))
        XCTAssertTrue(pub.isValidSignature(sig, for: Data((jwt[0] + "." + jwt[1]).utf8)))
        XCTAssertFalse(pub.isValidSignature(sig, for: Data((jwt[0] + "." + jwt[1] + "x").utf8)))
    }

    func testVAPIDKeyIsKeptAndReused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vapid-\(UUID().uuidString).key")
        let a = VAPIDKeys.loadOrCreate(at: url), b = VAPIDKeys.loadOrCreate(at: url)
        XCTAssertEqual(a.publicKey, b.publicKey)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(Base64URL.decode(a.publicKey)?.count, 65)
    }

    func testOnlyRealPushServicesAreAccepted() {
        func s(_ endpoint: String, p: String? = nil, a: String? = nil) -> PushSubscription { PushSubscription(endpoint: endpoint, p256dh: p ?? uaPublic, auth: a ?? authSecret) }
        XCTAssertTrue(s("https://fcm.googleapis.com/fcm/send/abc").isAcceptable())
        XCTAssertTrue(s("https://web.push.apple.com/QGxyz").isAcceptable())
        XCTAssertTrue(s("https://updates.push.services.mozilla.com/wpush/v2/x").isAcceptable())
        XCTAssertTrue(s("https://wns2-par02p.notify.windows.com/w/?token=x").isAcceptable())
        XCTAssertFalse(s("https://evil.example/fcm.googleapis.com").isAcceptable())
        XCTAssertFalse(s("https://googleapis.com.evil.example/x").isAcceptable())
        XCTAssertFalse(s("http://fcm.googleapis.com/x").isAcceptable())
        XCTAssertFalse(s("https://192.168.1.5/x").isAcceptable())
        XCTAssertFalse(s("http://127.0.0.1:9999/x").isAcceptable(), "loopback only when development allows it")
        XCTAssertTrue(s("http://127.0.0.1:9999/x").isAcceptable(allowLoopback: true))
        XCTAssertFalse(s("https://fcm.googleapis.com/x", p: "AAAA").isAcceptable())
        XCTAssertFalse(s("https://fcm.googleapis.com/x", a: "AAAA").isAcceptable())
        XCTAssertEqual(s("https://web.push.apple.com/x").audience, "https://web.push.apple.com")
        XCTAssertEqual(s("http://127.0.0.1:9999/x").audience, "http://127.0.0.1:9999")
    }
}

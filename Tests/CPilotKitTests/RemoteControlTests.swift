// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class RemoteControlTests: XCTestCase {
    private func raw(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    func testParsesRequestWithQueryHeadersAndBody() {
        let body = #"{"a":1}"#
        let r = HTTPParser.parse(raw("POST /v1/sessions?after=3&q=a%20b HTTP/1.1\nHost: x\nAuthorization: Bearer abc\nContent-Length: \(body.count)\n\n\(body)"))
        guard case .request(let req) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(req.method, "POST"); XCTAssertEqual(req.path, "/v1/sessions")
        XCTAssertEqual(req.query["after"], "3"); XCTAssertEqual(req.query["q"], "a b")
        XCTAssertEqual(req.token, "abc"); XCTAssertEqual(req.json["a"] as? Int, 1)
    }

    func testWaitsForTheWholeBodyAndRefusesHugeOnes() {
        XCTAssertEqual(HTTPParser.parse(raw("POST / HTTP/1.1\nContent-Length: 10\n\nabc")), .incomplete)
        XCTAssertEqual(HTTPParser.parse(raw("POST / HTTP/1.1\nContent-Length: 9999999\n\n")), .tooLarge)
        XCTAssertEqual(HTTPParser.parse(raw("POST / HTTP/1.1\nContent-Length: -4\n\n")), .bad)
        XCTAssertEqual(HTTPParser.parse(Data("garbage\r\n\r\n".utf8)), .bad)
    }

    func testTokenFromCookie() {
        let req = HTTPRequest(method: "GET", path: "/", headers: ["cookie": "a=1; cpilot_token=tok123; b=2"])
        XCTAssertEqual(req.token, "tok123")
        XCTAssertNil(HTTPRequest(method: "GET", path: "/").token)
    }

    func testResponseCarriesSafetyHeaders() {
        let text = String(decoding: HTTPResponse.error(403, "no").serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        XCTAssertTrue(text.contains("X-Frame-Options: DENY")); XCTAssertTrue(text.contains("Cache-Control: no-store"))
    }

    func testPairingCodeWorksOnceAndExpires() {
        let s = RemoteDeviceStore(url: nil)
        let t0 = Date()
        let code = s.makeCode(now: t0)
        guard case .success(let paired) = s.pair(code: code, name: " Mo's phone ", now: t0 + 5) else { return XCTFail() }
        XCTAssertEqual(paired.device.name, "Mo's phone"); XCTAssertFalse(paired.device.canApprove)
        XCTAssertEqual(s.device(for: paired.token)?.id, paired.device.id)
        XCTAssertEqual(s.pair(code: code, name: "again", now: t0 + 6).failureValue, .badCode)
        let late = s.makeCode(now: t0)
        XCTAssertEqual(s.pair(code: late, name: "x", now: t0 + RemoteDeviceStore.codeLifetime + 1).failureValue, .badCode)
    }

    func testWrongCodesLockPairing() {
        let s = RemoteDeviceStore(url: nil)
        let now = Date()
        for _ in 0..<5 { XCTAssertEqual(s.pair(code: "nope", name: "x", now: now).failureValue, .badCode) }
        let good = s.makeCode(now: now)
        XCTAssertEqual(s.pair(code: good, name: "x", now: now).failureValue, .locked)
        XCTAssertNotNil(s.pair(code: good, name: "x", now: now + 61).successValue)
    }

    func testTokensAreStoredHashedAndCanBeRevoked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devices-\(UUID().uuidString).json")
        let s = RemoteDeviceStore(url: url)
        let paired = try XCTUnwrap(s.pair(code: s.makeCode(), name: "p").successValue)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(paired.token)); XCTAssertTrue(onDisk.contains(RemoteDeviceStore.hash(paired.token)))
        XCTAssertEqual(RemoteDeviceStore(url: url).device(for: paired.token)?.id, paired.device.id)   // survives a restart
        s.revoke(paired.device.id)
        XCTAssertNil(s.device(for: paired.token)); XCTAssertNil(s.device(for: nil)); XCTAssertNil(s.device(for: ""))
    }

    func testStartLimitIsPerDevicePerHour() {
        let s = RemoteDeviceStore(url: nil)
        let t = Date()
        for _ in 0..<3 { XCTAssertTrue(s.allowStart(device: "a", limit: 3, now: t)) }
        XCTAssertFalse(s.allowStart(device: "a", limit: 3, now: t + 10))
        XCTAssertTrue(s.allowStart(device: "b", limit: 3, now: t + 10))
        XCTAssertTrue(s.allowStart(device: "a", limit: 3, now: t + 3601))
    }

    func testTailscaleStatusParsing() {
        func j(_ s: String) -> Data { Data(s.utf8) }
        XCTAssertEqual(TailscaleTransport.dnsName(fromStatus: j(#"{"BackendState":"Running","Self":{"DNSName":"mac.tail1234.ts.net."}}"#)), "mac.tail1234.ts.net")
        XCTAssertNil(TailscaleTransport.dnsName(fromStatus: j(#"{"BackendState":"NeedsLogin","Self":{"DNSName":"mac.ts.net."}}"#)))
        XCTAssertNil(TailscaleTransport.dnsName(fromStatus: j("not json")))
        XCTAssertEqual(TailscaleTransport.serveArguments(port: 4821), ["serve", "--bg", "--https=443", "http://127.0.0.1:4821"])
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
    var successValue: Success? { if case .success(let v) = self { return v } else { return nil } }
}

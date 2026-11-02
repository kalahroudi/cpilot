// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One HTTP request, as much of it as the remote control server needs.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    /// The device token: from `Authorization: Bearer`, else the `cpilot_token` cookie.
    public var token: String? {
        if let a = headers["authorization"], a.lowercased().hasPrefix("bearer ") { return String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "cpilot_token" { return kv[1] }
        }
        return nil
    }

    public var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

public enum HTTPParser {
    /// Largest request body accepted.
    public static let maxBody = 256 * 1024

    public enum Result: Equatable { case incomplete, tooLarge, bad, request(HTTPRequest) }

    public static func parse(_ data: Data) -> Result {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 16 * 1024 ? .tooLarge : .incomplete }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard first.count >= 2 else { return .bad }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad }
        if length > maxBody { return .tooLarge }
        let body = data[sep.upperBound...]
        guard body.count >= length else { return .incomplete }

        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                query[k] = kv.count == 2 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            }
        }
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        return .request(HTTPRequest(method: String(first[0]).uppercased(), path: path, query: query, headers: headers, body: Data(body.prefix(length))))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status; self.body = body
        self.headers = headers.merging(["Content-Type": contentType]) { a, _ in a }
    }

    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse { json(status, ["error": message]) }

    public static func html(_ text: String) -> HTTPResponse { HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8)) }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 201: "Created"; case 204: "No Content"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"
        case 404: "Not Found"; case 413: "Payload Too Large"; case 429: "Too Many Requests"; default: "Error"
        }
    }

    /// Never cached, never framed, never sniffed: the page is a control surface.
    public func serialized() -> Data {
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        h["Cache-Control"] = "no-store"
        h["X-Content-Type-Options"] = "nosniff"
        h["X-Frame-Options"] = "DENY"
        h["Referrer-Policy"] = "no-referrer"
        var out = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\n".utf8)
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { out.append(Data("\(k): \(v)\r\n".utf8)) }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    /// The head of a Server-Sent Events stream; events follow with `sseEvent`.
    public static let sseHead = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n".utf8)

    public static func sseEvent(_ name: String, _ data: String = "") -> Data {
        Data("event: \(name)\ndata: \(data.replacingOccurrences(of: "\n", with: " "))\n\n".utf8)
    }
}

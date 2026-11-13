// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ReadOnceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func iso(_ s: Double) -> String { ISO8601DateFormatter().string(from: t0.addingTimeInterval(s)) }

    private func assistant(_ n: Int, at s: Double, context: Int = 30_000, use: (id: String, tool: String, input: String)? = nil) -> String {
        let block = use.map { "{\"type\":\"tool_use\",\"id\":\"\($0.id)\",\"name\":\"\($0.tool)\",\"input\":\($0.input)}" } ?? "{\"type\":\"text\",\"text\":\"x\"}"
        return "{\"type\":\"assistant\",\"timestamp\":\"\(iso(s))\",\"message\":{\"id\":\"m\(n)\",\"content\":[\(block)],\"usage\":{\"input_tokens\":1,\"cache_read_input_tokens\":\(context),\"cache_creation_input_tokens\":0,\"output_tokens\":1}}}"
    }
    private func result(_ id: String, _ text: String, at s: Double, error: Bool = false) -> String {
        "{\"type\":\"user\",\"timestamp\":\"\(iso(s))\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"is_error\":\(error),\"content\":\"\(text)\"}]}}"
    }
    private func transcript(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }
    private let readA = ["file_path": "/r/a.swift"] as [String: Any]
    private var firstRead: [String] { [assistant(1, at: 10, use: ("t1", "Read", "{\"file_path\":\"/r/a.swift\"}")), result("t1", String(repeating: "x", count: 4000), at: 11)] }

    func testAnUnchangedFileAlreadyInTheConversationIsRefusedWithWhatItSaved() {
        let d = ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(firstRead + [assistant(2, at: 20)]), modified: t0.addingTimeInterval(5), now: t0.addingTimeInterval(30))
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.savedChars, 4000)
        XCTAssertTrue(d!.reason.hasPrefix(ReadOnce.marker))
    }

    func testAFileChangedSinceTheReadIsReadAgain() {
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(firstRead), modified: t0.addingTimeInterval(15)))
    }

    func testADifferentRangeOrFileIsNotARepeat() {
        let t = transcript(firstRead)
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: ["file_path": "/r/a.swift", "offset": 5, "limit": 20], transcript: t, modified: t0))
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: ["file_path": "/r/b.swift"], transcript: t, modified: t0))
    }

    func testAFailedOrEmptyEarlierReadDoesNotCount() {
        let failed = [assistant(1, at: 10, use: ("t1", "Read", "{\"file_path\":\"/r/a.swift\"}")), result("t1", "no such file", at: 11, error: true)]
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(failed), modified: t0))
    }

    func testAShrunkConversationMeansTheEarlierReadIsGoneAndIsReadAgain() {
        let compacted = firstRead + [assistant(2, at: 20, context: 150_000), assistant(3, at: 30, context: 40_000)]
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(compacted), modified: t0))
        let summary = firstRead + ["{\"type\":\"user\",\"isCompactSummary\":true,\"timestamp\":\"\(iso(25))\",\"message\":{\"content\":\"summary\"}}", assistant(2, at: 26)]
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(summary), modified: t0))
    }

    func testAnAgentThatInsistsGetsTheFileTheSecondTime() {
        let denied = firstRead + [assistant(2, at: 20, use: ("t2", "Read", "{\"file_path\":\"/r/a.swift\"}")), result("t2", ReadOnce.marker + " You already read it", at: 21), assistant(3, at: 22)]
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(denied), modified: t0))
    }

    func testUnknownModificationTimeFailsOpenAndAPureBashReadIsCoveredToo() {
        XCTAssertNil(ReadOnce.decide(tool: "Read", input: readA, transcript: transcript(firstRead), modified: nil))
        let bash = [assistant(1, at: 10, use: ("t1", "Bash", "{\"command\":\"sed -n '1,40p' /r/a.swift\"}")), result("t1", String(repeating: "y", count: 800), at: 11)]
        XCTAssertNotNil(ReadOnce.decide(tool: "Bash", input: ["command": "sed -n '1,40p' /r/a.swift"], transcript: transcript(bash), modified: t0))
        XCTAssertNil(ReadOnce.decide(tool: "Bash", input: ["command": "sed -n '1,40p' /r/a.swift && swift test"], transcript: transcript(bash), modified: t0))
    }

    func testTheHookAnswersInClaudeCodesFormat() throws {
        let o = try JSONSerialization.jsonObject(with: Data(ReadOnce.hookOutput(reason: "why").utf8)) as? [String: Any]
        let h = o?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(h?["permissionDecision"] as? String, "deny")
        XCTAssertEqual(h?["permissionDecisionReason"] as? String, "why")
    }
}

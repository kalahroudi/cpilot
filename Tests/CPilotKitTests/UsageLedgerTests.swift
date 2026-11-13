// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class UsageLedgerTests: XCTestCase {
    /// Lines shaped like Claude Code's own transcripts: one line per content block, the same message id and usage on each.
    private func assistant(_ id: String, at ts: String, input: Int = 2, read: Int, create: Int, oneHour: Int = 0, output: Int, model: String = "claude-sonnet-5-5",
                           tool: (id: String, name: String)? = nil, side: Bool = false, session: String = "S1") -> String {
        let block = tool.map { "{\"type\":\"tool_use\",\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"input\":{}}" } ?? "{\"type\":\"text\",\"text\":\"hi\"}"
        return "{\"type\":\"assistant\",\"isSidechain\":\(side),\"sessionId\":\"\(session)\",\"cwd\":\"/r\",\"timestamp\":\"\(ts)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"content\":[\(block)],\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":\(read),\"cache_creation_input_tokens\":\(create),\"output_tokens\":\(output),\"cache_creation\":{\"ephemeral_1h_input_tokens\":\(oneHour),\"ephemeral_5m_input_tokens\":\(create - oneHour)}}}}"
    }

    private func result(_ useId: String, _ content: String, at ts: String = "2026-11-01T10:00:01.000Z") -> String {
        "{\"type\":\"user\",\"sessionId\":\"S1\",\"timestamp\":\"\(ts)\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(useId)\",\"content\":\(content)}]}}"
    }

    func testAMessageStreamedOverSeveralLinesIsCountedOnceWithItsFinalOutput() {
        let text = [assistant("m1", at: "2026-11-01T10:00:00.000Z", read: 1000, create: 500, output: 10),
                    assistant("m1", at: "2026-11-01T10:00:00.500Z", read: 1000, create: 500, output: 180),
                    "not json", "{\"type\":\"mode\"}", ""].joined(separator: "\n")
        let p = TranscriptUsage.parse(text, session: "fallback")
        XCTAssertEqual(p.rows.count, 1)
        XCTAssertEqual(p.rows[0].output, 180)
        XCTAssertEqual(p.rows[0].session, "S1")
        XCTAssertEqual(p.rows[0].context, 1502)
    }

    func testCacheWritesAreSplitByLifetimeAndOnlyBilledAsWhatTheyAre() {
        let p = TranscriptUsage.parse(assistant("m1", at: "2026-11-01T10:00:00.000Z", input: 0, read: 0, create: 1000, oneHour: 400, output: 0, model: "claude-opus-5-5"), session: "S1")
        XCTAssertEqual(p.rows[0].write1h, 400)
        XCTAssertEqual(p.rows[0].write5m, 600)
        // 600 at 1.25 x $4 and 400 at 2 x $4 per million.
        XCTAssertEqual(ModelPrice.forModel("claude-opus-5-5")!.cost(of: p.rows[0]), (600 * 5.0 + 400 * 8.0) / 1_000_000, accuracy: 1e-12)
    }

    func testPricePicksTheMostSpecificModelAndNeverGuessesAnUnknownOne() {
        XCTAssertEqual(ModelPrice.forModel("claude-opus-5-5")?.input, 4)
        XCTAssertEqual(ModelPrice.forModel("claude-opus-5")?.input, 5)
        XCTAssertEqual(ModelPrice.forModel("claude-sonnet-5-5")?.cacheRead, 0.20)
        XCTAssertNil(ModelPrice.forModel("gpt-5"))
        let unknown = [UsageRow(session: "S", id: "a", model: "mystery", input: 10, output: 10)]
        XCTAssertNil(UsageMetrics.summarize(unknown)?.cost)
    }

    func testToolResultsAreMatchedToTheirCallsEvenWhenTheyArriveInALaterChunk() {
        let first = TranscriptUsage.parse(assistant("m1", at: "2026-11-01T10:00:00.000Z", read: 1, create: 1, output: 1, tool: ("t1", "Bash")), session: "S1")
        let second = TranscriptUsage.parse(result("t1", "\"hello world\""), session: "S1")
        let store = UsageStore(path: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-\(UUID().uuidString).db"))
        store.add(first); store.add(second)
        let tools = store.tools(session: "S1")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "Bash")
        XCTAssertEqual(tools[0].resultChars, 11)
    }

    func testResultsAsTextBlocksAreCounted() {
        let p = TranscriptUsage.parse(result("t1", "[{\"type\":\"text\",\"text\":\"abcd\"},{\"type\":\"text\",\"text\":\"ef\"}]"), session: "S1")
        XCTAssertEqual(p.tools.first?.resultChars, 6)
    }

    func testSummaryHitRateContextAndColdStarts() {
        let rows = [UsageRow(session: "S", id: "1", model: "claude-sonnet-5-5", ts: Date(timeIntervalSince1970: 0), input: 2, cacheRead: 0, write5m: 1000, output: 5),
                    UsageRow(session: "S", id: "2", model: "claude-sonnet-5-5", ts: Date(timeIntervalSince1970: 30), input: 2, cacheRead: 1000, write5m: 100, output: 5),
                    UsageRow(session: "S", id: "3", model: "claude-sonnet-5-5", ts: Date(timeIntervalSince1970: 1000), input: 2, cacheRead: 0, write5m: 1100, output: 5),
                    UsageRow(session: "S", id: "4", model: "claude-haiku-5-5", ts: Date(timeIntervalSince1970: 1010), input: 50_000, cacheRead: 0, write5m: 0, output: 5, sidechain: true)]
        let s = UsageMetrics.summarize(rows)!
        XCTAssertEqual(s.calls, 4)
        XCTAssertEqual(s.peakContext, 1102)          // the sub-agent's 50k is its own context
        XCTAssertEqual(s.lastContext, 1102)
        XCTAssertEqual(s.coldStarts, 1)
        XCTAssertEqual(s.rewrittenAfterGaps, 1100)
        XCTAssertEqual(s.cacheHitRate!, 1000.0 / Double(s.input + s.cacheRead + s.cacheWrite), accuracy: 1e-12)
        XCTAssertNotNil(s.cost)
    }

    func testBiggestResultsAreAddedUpPerTool() {
        let t = [ToolEvent(useId: "1", session: "S", name: "Bash", ts: .now, resultChars: 100), ToolEvent(useId: "2", session: "S", name: "Bash", ts: .now, resultChars: 300),
                 ToolEvent(useId: "3", session: "S", name: "Read", ts: .now, resultChars: 200), ToolEvent(useId: "4", session: "S", name: "Read", ts: .now, resultChars: nil)]
        let top = UsageMetrics.biggestResults(t)
        XCTAssertEqual(top.map(\.name), ["Bash", "Read"])
        XCTAssertEqual(top[0].chars, 400)
        XCTAssertEqual(top[1].calls, 1)
    }

    func testSyncReadsOnlyWhatIsNewAndSurvivesARewrite() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("S1.jsonl")
        let store = UsageStore(path: dir.appendingPathComponent("usage.db"))
        try (assistant("m1", at: "2026-11-01T10:00:00.000Z", read: 100, create: 10, output: 5) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.sync(root: dir), 1)
        XCTAssertEqual(store.sync(root: dir), 0)                       // nothing new, nothing read
        // A second message, and a half-written line the app has not finished yet.
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
        try h.write(contentsOf: Data((assistant("m2", at: "2026-11-01T10:00:09.000Z", read: 110, create: 5, output: 7) + "\n{\"type\":\"assis").utf8)); try h.close()
        XCTAssertEqual(store.sync(root: dir), 1)
        XCTAssertEqual(store.rows(session: "S1").map(\.id), ["m1", "m2"])
        // The half line is finished later, and counted once.
        let h2 = try FileHandle(forWritingTo: file); try h2.seekToEnd()
        try h2.write(contentsOf: Data((assistant("m3", at: "2026-11-01T10:00:19.000Z", read: 120, create: 5, output: 9).dropFirst(15) + "\n").utf8)); try h2.close()
        store.sync(root: dir)
        XCTAssertEqual(store.rows(session: "S1").count, 2)             // the torn line was a fragment; no invented row
        // The file shrank: it was rewritten, so it is read again from the start without double counting.
        try (assistant("m1", at: "2026-11-01T10:00:00.000Z", read: 100, create: 10, output: 5) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.sync(root: dir), 1)
        XCTAssertEqual(store.rows(session: "S1").count, 2)
        XCTAssertEqual(store.summary(session: "S1")?.calls, 2)
    }
}

/// Reads the real ~/.claude/projects, only when asked for: `CPILOT_LIVE_LENS=1 swift test --filter LiveLensTests`.
final class LiveLensTests: XCTestCase {
    func testRealTranscriptsMatchAHandCount() throws {
        guard ProcessInfo.processInfo.environment["CPILOT_LIVE_LENS"] != nil else { throw XCTSkip("set CPILOT_LIVE_LENS=1") }
        let store = UsageStore(path: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("live-\(UUID().uuidString).db"))
        let t0 = Date(); let files = store.sync(); let took = Date().timeIntervalSince(t0)
        let all = store.sessions()
        print("LENS files=\(files) sessions=\(all.count) seconds=\(took)")
        for s in all.sorted(by: { $0.cacheRead > $1.cacheRead }).prefix(4) {
            print("LENS \(s.session.prefix(8)) calls=\(s.calls) read=\(s.cacheRead / 1000)k write=\(s.cacheWrite / 1000)k out=\(s.output / 1000)k peak=\(s.peakContext / 1000)k hit=\(Int((s.cacheHitRate ?? 0) * 100))% cost=\(s.cost.map { String(format: "%.0f", $0) } ?? "?") cold=\(s.coldStarts)")
        }
        let t1 = Date(); XCTAssertLessThan(store.sync(), 10); print("LENS second sync seconds=\(Date().timeIntervalSince(t1))")
    }
}

final class LensAlertsTests: XCTestCase {
    private func usage(context: Int, last: Date, calls: Int = 20, read: Int = 900, write: Int = 100) -> SessionUsage {
        SessionUsage(session: "S", cwd: "/r", model: "claude-sonnet-5-5", calls: calls, input: 0, cacheRead: read, cacheWrite: write, output: 10, peakContext: context, lastContext: context,
                     cost: 1, first: last.addingTimeInterval(-3600), last: last, coldStarts: 0, rewrittenAfterGaps: 0)
    }

    func testAnEightHundredThousandTokenSessionIsFlaggedAtTwoHundredThousand() {
        let now = Date()
        XCTAssertTrue(LensAlerts.alerts(for: usage(context: 199_000, last: now), now: now).isEmpty)
        XCTAssertEqual(LensAlerts.alerts(for: usage(context: 200_000, last: now), now: now).map(\.kind), [.contextHigh])
        XCTAssertEqual(LensAlerts.alerts(for: usage(context: 800_000, last: now), now: now).first?.kind, .contextHigh)
    }

    func testAnIdleLargeSessionIsToldWhatTheNextMessageWillCost() {
        let now = Date()
        let a = LensAlerts.alerts(for: usage(context: 100_000, last: now.addingTimeInterval(-900)), now: now)
        XCTAssertEqual(a.map(\.kind), [.cacheCold])
        XCTAssertTrue(a[0].message.contains("15 minutes") && a[0].message.contains("$0.25"))   // 100k at 1.25 x $2 per million
        XCTAssertTrue(LensAlerts.alerts(for: usage(context: 10_000, last: now.addingTimeInterval(-900)), now: now).isEmpty)
        XCTAssertTrue(LensAlerts.alerts(for: usage(context: 100_000, last: now.addingTimeInterval(-60)), now: now).isEmpty)
    }

    func testLowCacheHitNeedsEnoughCallsAndAHugeResultIsFlagged() {
        let now = Date()
        XCTAssertEqual(LensAlerts.alerts(for: usage(context: 1000, last: now, calls: 30, read: 100, write: 900), now: now).map(\.kind), [.lowCacheHit])
        XCTAssertTrue(LensAlerts.alerts(for: usage(context: 1000, last: now, calls: 3, read: 100, write: 900), now: now).isEmpty)
        XCTAssertEqual(LensAlerts.alerts(for: usage(context: 1000, last: now), largestResultChars: 200_000, now: now).map(\.kind), [.bigResult])
    }

    func testUsageIsSplitByWhoStartedTheWork() {
        var chief = SessionMeta(title: "c", cwd: "/r", backend: .claude, model: nil, access: .askFirst); chief.chief = true
        var rev = SessionMeta(title: "r", cwd: "/r", backend: .claude, model: nil, access: .askFirst); rev.reviewOf = 3
        var tester = SessionMeta(title: "t", cwd: "/r", backend: .claude, model: nil, access: .askFirst); tester.role = "tester"
        let mine = SessionMeta(title: "m", cwd: "/r", backend: .claude, model: nil, access: .askFirst)
        let owners = ["c": chief, "r": rev, "t": tester, "m": mine]
        XCTAssertEqual(UsageOrigin.label(chief), "Chief pilot")
        XCTAssertEqual(UsageOrigin.label(rev), "Reviewers")
        XCTAssertEqual(UsageOrigin.label(tester), "Testers")
        XCTAssertEqual(UsageOrigin.label(mine), "You, in CPilot")
        XCTAssertEqual(UsageOrigin.label(nil), UsageOrigin.outside)
        func u(_ id: String, _ cost: Double) -> SessionUsage { var x = usage(context: 1, last: .now); x.session = id; x.cost = cost; return x }
        let split = UsageOrigin.split([u("c", 5), u("r", 1), u("zz", 9), u("m", 2), u("m2", 1)], owner: { owners[$0] })
        XCTAssertEqual(split.map(\.origin), [UsageOrigin.outside, "Chief pilot", "You, in CPilot", "Reviewers"].sorted { a, b in
            [UsageOrigin.outside: 9, "Chief pilot": 5, "You, in CPilot": 2, "Reviewers": 1][a]! > [UsageOrigin.outside: 9, "Chief pilot": 5, "You, in CPilot": 2, "Reviewers": 1][b]! })
    }
}

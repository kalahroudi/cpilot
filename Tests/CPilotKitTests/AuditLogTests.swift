// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class AuditLogTests: XCTestCase {
    private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl") }
    private func entry(daysAgo: Double, _ summary: String) -> AuditEntry {
        var e = AuditEntry(session: "s", tool: "Bash", summary: summary, outcome: "allowed once"); e.ts = Date().addingTimeInterval(-daysAgo * 86_400); return e
    }

    func testOldLinesAreRemovedAndRecentOnesKept() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.record(entry(daysAgo: 200, "ancient"))
        log.record(entry(daysAgo: 91, "just too old"))
        log.record(entry(daysAgo: 89, "recent"))
        log.record(entry(daysAgo: 0, "today"))
        log.prune()
        XCTAssertEqual(Set(log.recent(10).map(\.summary)), ["recent", "today"])
    }

    func testOpeningTheLogPrunesIt() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let first = AuditLog(url: url)
        first.record(entry(daysAgo: 300, "old"))
        first.record(entry(daysAgo: 1, "new"))
        XCTAssertEqual(Set(AuditLog(url: url).recent(10).map(\.summary)), ["new"])
    }

    func testAFileThatIsAllInsideTheWindowIsNotRewritten() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.record(entry(daysAgo: 2, "a")); log.record(entry(daysAgo: 1, "b"))
        let before = try Data(contentsOf: url)
        log.prune()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testUnreadableLinesAreDropped() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.record(entry(daysAgo: 1, "keep"))
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("not json\n".utf8)); try h.close()
        log.prune()
        XCTAssertEqual(log.recent(10).map(\.summary), ["keep"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("not json"))
    }

    func testAnEmptiedLogIsAnEmptyFileAndStillWorks() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.record(entry(daysAgo: 400, "old"))
        log.prune()
        XCTAssertTrue(log.recent(10).isEmpty)
        log.record(entry(daysAgo: 0, "again"))
        XCTAssertEqual(log.recent(10).map(\.summary), ["again"])
    }

    func testPruningHappensWhileRunningAtMostOncePerDay() {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let log = AuditLog(url: url)
        log.record(entry(daysAgo: 0, "first"))
        // Pruned just now by `init`; an old line written afterwards stays until the next day's write.
        log.record(entry(daysAgo: 200, "late old"))
        XCTAssertEqual(Set(log.recent(10).map(\.summary)), ["first", "late old"])
        var next = entry(daysAgo: 0, "tomorrow"); next.ts = Date().addingTimeInterval(2 * 86_400)
        log.record(next)
        XCTAssertNil(log.recent(10).first { $0.summary == "late old" })
    }
}

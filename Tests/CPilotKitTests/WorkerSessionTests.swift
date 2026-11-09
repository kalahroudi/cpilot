// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class WorkerSessionTests: XCTestCase {
    private func meta(_ edit: (inout SessionMeta) -> Void = { _ in }) -> SessionMeta {
        var m = SessionMeta(title: "t", cwd: "/code/shop"); edit(&m); return m
    }

    func testWhoIsAWorker() {
        XCTAssertFalse(meta().isWorker)
        XCTAssertFalse(meta { $0.chief = true; $0.spawned = true }.isWorker)
        XCTAssertTrue(meta { $0.spawned = true }.isWorker)
        XCTAssertFalse(meta { $0.spawned = false; $0.branch = "spec-001-t1" }.isWorker)       // a task the user started
        XCTAssertTrue(meta { $0.reviewOf = 12 }.isWorker)                                    // from before `spawned` was recorded
        XCTAssertTrue(meta { $0.branch = "spec-001-t1" }.isWorker)
        XCTAssertFalse(meta { $0.branch = "phone/fix-login" }.isWorker)
    }
}

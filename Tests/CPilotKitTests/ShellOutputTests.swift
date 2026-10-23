// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ShellOutputTests: XCTestCase {
    /// A command that prints and exits at once must never come back empty, however many run at the same time.
    func testOutputOfQuickCommandsIsNeverLost() async throws {
        let bad = await withTaskGroup(of: Int.self) { group in
            for i in 0..<400 {
                group.addTask {
                    let r = try? await Shell.run("sh", ["-c", "echo out\(i); echo err\(i) >&2"], timeout: 30)
                    return r?.stdout == "out\(i)\n" && r?.stderr == "err\(i)\n" ? 0 : 1
                }
            }
            return await group.reduce(0, +)
        }
        XCTAssertEqual(bad, 0, "\(bad) of 400 quick commands lost their output")
    }
}

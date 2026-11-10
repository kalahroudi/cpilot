// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class DefaultBranchTests: XCTestCase {
    func repo(branch: String) async throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        _ = try await Shell.check("git", ["init", "-q", "-b", branch], cwd: d)
        _ = try await Shell.check("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"], cwd: d)
        return d.path
    }
    func testARepositoryWithoutMainStartsFromItsOwnBranch() async throws {
        let a = try await repo(branch: "master")
        let b = try await repo(branch: "work")
        let nameA = await Git.defaultBranch(a), nameB = await Git.defaultBranch(b)
        XCTAssertEqual(nameA, "master"); XCTAssertEqual(nameB, "work")
        let base = await Git.freshBase(b)
        XCTAssertEqual(base, "work")
    }
}

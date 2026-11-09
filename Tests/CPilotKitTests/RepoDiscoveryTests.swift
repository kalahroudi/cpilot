// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class RepoDiscoveryTests: XCTestCase {
    func testSlugs() {
        XCTAssertTrue(RepoDiscovery.isSlug("kalahroudi/cpilot"))
        XCTAssertTrue(RepoDiscovery.isSlug("a-b/c.d_e"))
        for bad in ["cpilot", "a/b/c", "/b", "a/", "-a/b", "a/..", "a b/c", "a/b;rm", "a/$(x)", "é/b"] { XCTAssertFalse(RepoDiscovery.isSlug(bad), bad) }
    }

    func testSlugFromLinks() {
        XCTAssertEqual(RepoDiscovery.slug(from: "https://github.com/kalahroudi/cpilot.git"), "kalahroudi/cpilot")
        XCTAssertEqual(RepoDiscovery.slug(from: " git@github.com:kalahroudi/cpilot.git "), "kalahroudi/cpilot")
        XCTAssertEqual(RepoDiscovery.slug(from: "https://github.com/kalahroudi/cpilot/"), "kalahroudi/cpilot")
        XCTAssertEqual(RepoDiscovery.slug(from: "kalahroudi/cpilot"), "kalahroudi/cpilot")
        XCTAssertNil(RepoDiscovery.slug(from: "https://evil.example/kalahroudi/cpilot"))
        XCTAssertNil(RepoDiscovery.slug(from: "kalahroudi"))
    }

    func testScanFindsGitFoldersOneLevelDown() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for d in ["b/.git", "a/.git", "known/.git", "plain", "a/inner/.git", ".hidden/.git"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        let found = RepoDiscovery.scan(roots: [root, root, root + "/missing"], exclude: [root + "/known"])
        XCTAssertEqual(found.map { ($0 as NSString).lastPathComponent }, ["a", "b"])
    }
}

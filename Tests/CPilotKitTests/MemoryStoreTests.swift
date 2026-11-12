// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class MemoryStoreTests: XCTestCase {
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)") }
    func store() -> (MemoryStore, MemoryIndex) {
        let ix = MemoryIndex(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db"), embedder: FakeEmbedder())
        return (MemoryStore(root: tempDir(), index: ix), ix)
    }

    /// Every repository has a note called "lessons-from-past-runs": saving or deleting one must not touch the recall entries of another.
    func testSameNoteNameInTwoScopesIsIndexedSeparately() {
        let (m, ix) = store()
        m.save(scope: "repo-a", name: "lessons-from-past-runs", body: "Run the alpha linter before pushing changes to the alpha service.")
        m.save(scope: "repo-b", name: "lessons-from-past-runs", body: "The beta migrations must be reversible before they merge.")
        XCTAssertEqual(ix.counts().notes, 2)
        m.save(scope: "repo-b", name: "lessons-from-past-runs", body: "The beta migrations are checked by the gamma tool now.")
        XCTAssertEqual(ix.search("alpha linter", scopes: ["repo-a"]).first?.scope, "repo-a")
        m.delete(scope: "repo-b", name: "lessons-from-past-runs")
        XCTAssertEqual(ix.search("alpha linter", scopes: ["repo-a"]).count, 1)
        XCTAssertTrue(ix.search("beta migrations", scopes: ["repo-b"]).isEmpty)
        XCTAssertEqual(ix.counts().notes, 1)
    }

    func testIdenticalChunksInTwoScopesAreBothKept() {
        let ix = MemoryIndex(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db"), embedder: FakeEmbedder())
        let text = "Always run the formatter before committing changes."
        ix.add(scope: "a", source: "note", ref: "n", text: text); ix.add(scope: "b", source: "note", ref: "n", text: text)
        XCTAssertEqual(ix.counts().notes, 2)
    }
}

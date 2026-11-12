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

    // MARK: Versions and checked writes

    func testEverySaveIsAVersionWithWhoAndWhy() {
        let (m, _) = store()
        m.save(scope: "g", name: "Style", body: "Plain language.", actor: "you", reason: "first draft")
        m.save(scope: "g", name: "Style", body: "Plain language. Short sentences.", actor: "lessons", reason: "from a run")
        m.save(scope: "g", name: "Style", body: "Plain language. Short sentences.", actor: "you")       // unchanged: no new version
        let h = m.history(scope: "g", name: "style")
        XCTAssertEqual(h.map(\.id), [2, 1])
        XCTAssertEqual(h.map(\.actor), ["lessons", "you"]); XCTAssertEqual(h[0].reason, "from a run")
        XCTAssertEqual(h[1].body, "Plain language.")
    }

    func testAWriterThatReadAnOldVersionIsRefusedAndNothingIsLost() {
        let (m, _) = store()
        guard case .saved(let first) = m.write(scope: "g", name: "n", body: "one", expect: .absent, actor: "a") else { return XCTFail("create") }
        XCTAssertEqual(m.write(scope: "g", name: "n", body: "two", expect: .hash(first.hash), actor: "b").savedBody, "two")
        // "a" still holds the first version: its write is refused and reports what is there now.
        guard case .conflict(let now) = m.write(scope: "g", name: "n", body: "from a", expect: .hash(first.hash), actor: "a") else { return XCTFail("expected a conflict") }
        XCTAssertEqual(now?.body, "two")
        XCTAssertEqual(m.notes(scope: "g").first?.body, "two")
        guard case .conflict = m.write(scope: "g", name: "n", body: "x", expect: .absent, actor: "a") else { return XCTFail("absent but exists") }
        guard case .conflict(let gone) = m.write(scope: "g", name: "missing", body: "x", expect: .hash("abc"), actor: "a") else { return XCTFail("hash of a note that is not there") }
        XCTAssertNil(gone)
    }

    /// The memory is shared by the app and the MCP server, which are separate processes. Separate store objects over one folder behave the same way: each holds its own lock handle.
    func testManyWritersAppendingToOneNoteLoseNothing() {
        let root = tempDir()
        let stores = (0..<4).map { _ in MemoryStore(root: root) }
        let count = 40
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let m = stores[i % stores.count]
            for _ in 0..<500 {
                let cur = m.notes(scope: "g").first { $0.name == "log" }
                let body = (cur?.body ?? "") + "line \(i)\n"
                if case .saved = m.write(scope: "g", name: "log", body: body, expect: cur.map { .hash($0.hash) } ?? .absent, actor: "w\(i)") { return }
            }
            XCTFail("writer \(i) never got through")
        }
        let lines = Set((stores[0].notes(scope: "g").first?.body ?? "").split(separator: "\n"))
        XCTAssertEqual(lines.count, count)
        XCTAssertEqual(stores[0].history(scope: "g", name: "log").count, count)
    }

    func testUpdateBuildsOnTheCurrentTextUnderTheLock() {
        let root = tempDir()
        let stores = (0..<4).map { _ in MemoryStore(root: root) }
        DispatchQueue.concurrentPerform(iterations: 60) { i in
            stores[i % 4].update(scope: "g", name: "log", actor: "w", reason: "append") { ($0 ?? "") + "line \(i)\n" }
        }
        XCTAssertEqual(Set((stores[0].notes(scope: "g").first?.body ?? "").split(separator: "\n")).count, 60)
        XCTAssertEqual(stores[0].history(scope: "g", name: "log").count, 60)
        // returning nil leaves the note, and creates none
        XCTAssertNil(stores[0].update(scope: "g", name: "log", actor: "w") { _ in nil })
        XCTAssertNil(stores[0].update(scope: "g", name: "never", actor: "w") { _ in nil })
        XCTAssertEqual(stores[0].history(scope: "g", name: "log").count, 60); XCTAssertEqual(stores[0].notes(scope: "g").count, 1)
    }

    func testAChangeMadeOutsideCPilotIsKeptBeforeItIsReplaced() throws {
        let (m, _) = store()
        m.save(scope: "g", name: "n", body: "mine")
        try "edited in an editor".write(to: m.root.appendingPathComponent("g/n.md"), atomically: true, encoding: .utf8)
        m.save(scope: "g", name: "n", body: "replaced", actor: "lessons")
        let h = m.history(scope: "g", name: "n")
        XCTAssertEqual(h.map(\.body), ["replaced", "edited in an editor", "mine"])
        XCTAssertEqual(h[1].actor, "outside edit")
        // a file removed outside is noticed too
        try FileManager.default.removeItem(at: m.root.appendingPathComponent("g/n.md"))
        XCTAssertEqual(m.history(scope: "g", name: "n").first?.deleted, true)
        XCTAssertEqual(m.deletedNotes(scope: "g"), ["n"])
    }

    func testDeleteIsUndoableAndRestoreAddsAVersion() {
        let (m, ix) = store()
        m.save(scope: "g", name: "n", body: "the first words about pipelines")
        m.save(scope: "g", name: "n", body: "the second words about pipelines")
        m.delete(scope: "g", name: "n", actor: "you")
        XCTAssertTrue(m.notes(scope: "g").isEmpty); XCTAssertEqual(ix.counts().notes, 0); XCTAssertEqual(m.deletedNotes(scope: "g"), ["n"])
        XCTAssertEqual(m.restore(scope: "g", name: "n", version: 1).savedBody, "the first words about pipelines")
        XCTAssertEqual(m.notes(scope: "g").first?.body, "the first words about pipelines")
        XCTAssertEqual(ix.counts().notes, 1)
        XCTAssertEqual(m.history(scope: "g", name: "n").map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(m.history(scope: "g", name: "n")[0].reason, "Restored version 1")
        XCTAssertTrue(m.deletedNotes(scope: "g").isEmpty)
        m.save(scope: "other", name: "x", body: "text"); m.delete(scope: "other", name: "x")
        XCTAssertEqual(m.allDeletedNotes().map { "\($0.scope)/\($0.name)" }, ["other/x"])
        XCTAssertEqual(m.restore(scope: "g", name: "n", version: 3), .failed)       // the deletion itself cannot be restored
        XCTAssertEqual(m.restore(scope: "g", name: "n", version: 99), .failed)
    }

    func testHistoryIsCappedAndHiddenFoldersAreNotScopes() {
        let (m, _) = store()
        for i in 1...(MemoryStore.versionLimit + 5) { m.save(scope: "g", name: "n", body: "version \(i)") }
        let h = m.history(scope: "g", name: "n")
        XCTAssertEqual(h.count, MemoryStore.versionLimit); XCTAssertEqual(h.first?.id, MemoryStore.versionLimit + 5)
        XCTAssertEqual(m.allNotes().count, 1)                                         // .history and .lock are not scopes
        m.save(scope: "g", name: "long", body: "x", reason: String(repeating: "r", count: 1000))
        XCTAssertEqual(m.history(scope: "g", name: "long").first?.reason.count, MemoryStore.reasonLimit)
    }
}

extension MemoryWrite {
    var savedBody: String? { if case .saved(let n) = self { return n.body }; return nil }
}

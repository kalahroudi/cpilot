// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class ClaudeModelsTests: XCTestCase {
    func testNewModelsFromClaudeCodesCacheAppearAfterTheAliases() {
        let json = #"{"additionalModelOptionsCache":[{"value":"claude-fable-5-2[1m]","label":"Fable","description":"Fable 5.2 · Most capable"}]}"#
        let o = ClaudeModels.options(claudeJSON: Data(json.utf8))
        XCTAssertEqual(o.map(\.value), ["", "opus", "sonnet", "haiku", "claude-fable-5-2[1m]"])
        XCTAssertEqual(o.last?.label, "Fable 5.2")
    }
    func testMissingOrBrokenFileLeavesTheAliases() {
        XCTAssertEqual(ClaudeModels.options(claudeJSON: nil), ClaudeModels.aliases)
        XCTAssertEqual(ClaudeModels.options(claudeJSON: Data("nope".utf8)), ClaudeModels.aliases)
    }
    func testAnAliasIsNotListedTwice() {
        let json = #"{"additionalModelOptionsCache":[{"value":"opus","label":"Opus"},{"value":""}]}"#
        XCTAssertEqual(ClaudeModels.options(claudeJSON: Data(json.utf8)), ClaudeModels.aliases)
    }
    func testACustomSelectionStaysInTheList() {
        let o = ClaudeModels.options(including: "claude-x-9", in: ClaudeModels.aliases)
        XCTAssertEqual(o.last?.value, "claude-x-9")
        XCTAssertEqual(ClaudeModels.label(for: "claude-x-9", in: o), "claude-x-9")
    }

    // MARK: Claude Code's catalog

    func catalog(surface: String, fetched: Double, current: String = "claude-sonnet-5-5", extra: String = "") -> Data {
        Data("""
        {"version": 2, "fetchedAt": \(fetched), "staleAt": \(fetched + 3600000), "catalog": {"surface": "\(surface)", "config": {"id": "\(surface)", "models": [
          {"id": "claude-opus-5-5", "name": "Opus 5.5", "short_name": "Opus", "description": "For complex work", "section": "main", "min_claude_code_version": "2.1.280"},
          {"id": "claude-fable-5-2", "name": "Fable 5.2", "short_name": "Fable", "description": "For your toughest challenges", "section": "main", "min_claude_code_version": "2.1.290"},
          {"id": "claude-sonnet-5-5", "name": "Sonnet 5.5", "short_name": "Sonnet", "section": "main"},
          {"id": "claude-haiku-5-5", "name": "Haiku 5.5", "short_name": "Haiku", "section": "main"},
          {"id": "claude-fable-5-1", "name": "Fable 5.1", "short_name": "Fable", "section": "overflow", "min_claude_code_version": "2.1.251"},
          {"id": "claude-opus-4-8", "name": "Opus 4.8", "short_name": "Opus", "section": "overflow"}\(extra)
        ]}, "state": {"id": "\(surface)", "model": "\(current)", "selection_source": "user_setting"}}}
        """.utf8)
    }

    func testTheCatalogListsNewModelsByNameMainOnesFirstAndOlderOnesAfter() {
        let o = ClaudeModels.options(claudeJSON: nil, catalogs: [catalog(surface: "cc", fetched: 100)], settingsModel: nil)
        XCTAssertEqual(o.map(\.value), ["", "claude-opus-5-5", "claude-fable-5-2", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-8"])
        XCTAssertEqual(o.map(\.label).dropFirst().prefix(4), ["Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"])
        XCTAssertEqual(o.filter(\.older).map(\.label), ["Fable 5.1", "Opus 4.8"])
        XCTAssertTrue(o[2].detail.contains("For your toughest challenges")); XCTAssertTrue(o[2].detail.contains("Needs Claude Code 2.1.290 or newer."))
        XCTAssertEqual(o[0].detail, "Claude Code's own choice: Sonnet 5.5.")
    }

    func testYourSettingsModelIsTheDefaultsNameAndAnUnknownOneIsStillOffered() {
        let c = catalog(surface: "cc", fetched: 100)
        XCTAssertEqual(ClaudeModels.options(claudeJSON: nil, catalogs: [c], settingsModel: "claude-fable-5-2")[0].detail, "Claude Code's own choice: Fable 5.2.")
        let o = ClaudeModels.options(claudeJSON: nil, catalogs: [c], settingsModel: "claude-future-9")
        XCTAssertEqual(o.first { $0.value == "claude-future-9" }?.detail, "Set in your Claude Code settings"); XCTAssertEqual(o[0].detail, "Claude Code's own choice: claude-future-9.")
    }

    func testTheCommandLinesCatalogBeatsTheDesktopsAndTheNewestWins() {
        let old = catalog(surface: "cc", fetched: 100, extra: #", {"id": "claude-old-1", "name": "Old One", "short_name": "Old", "section": "main"}"#)
        let new = catalog(surface: "cc", fetched: 200)
        let desktop = catalog(surface: "ccd", fetched: 900, extra: #", {"id": "claude-desktop-only", "name": "Desktop Only", "short_name": "D", "section": "main"}"#)
        let o = ClaudeModels.options(claudeJSON: nil, catalogs: [old, desktop, new], settingsModel: nil)
        XCTAssertFalse(o.contains { $0.value == "claude-old-1" }); XCTAssertFalse(o.contains { $0.value == "claude-desktop-only" })
        XCTAssertTrue(ClaudeModels.options(claudeJSON: nil, catalogs: [desktop], settingsModel: nil).contains { $0.value == "claude-desktop-only" })   // when it is all there is
    }

    func testVariantsClaudeCodeListsThatTheCatalogLacksStayAndTheRestFallsBack() {
        let json = #"{"additionalModelOptionsCache":[{"value":"claude-fable-5-2[1m]","label":"Fable","description":"Fable 5.2 · Most capable"},{"value":"claude-fable-5-2","label":"Fable"}]}"#
        let o = ClaudeModels.options(claudeJSON: Data(json.utf8), catalogs: [catalog(surface: "cc", fetched: 1)], settingsModel: nil)
        XCTAssertEqual(o.filter { $0.value.hasPrefix("claude-fable-5-2") }.map(\.value), ["claude-fable-5-2", "claude-fable-5-2[1m]"])         // the catalog's own entry is not doubled
        XCTAssertEqual(o.first { $0.value == "claude-fable-5-2[1m]" }?.label, "Fable 5.2 (1M context)")
        // no usable catalog: the aliases as before, plus the settings model
        XCTAssertEqual(ClaudeModels.options(claudeJSON: nil, catalogs: [Data("nope".utf8)], settingsModel: nil), ClaudeModels.aliases)
        XCTAssertEqual(ClaudeModels.options(claudeJSON: nil, catalogs: [], settingsModel: "claude-x-1").last?.value, "claude-x-1")
        XCTAssertNil(ClaudeModels.parseCatalog(Data(#"{"catalog": {"config": {"models": []}}}"#.utf8)))
    }

    func testAliasesAndRunningIdsReadAsNames() {
        let o = ClaudeModels.options(claudeJSON: nil, catalogs: [catalog(surface: "cc", fetched: 1)], settingsModel: nil)
        XCTAssertEqual(ClaudeModels.label(for: "opus", in: o), "Opus 5.5 (latest)"); XCTAssertEqual(ClaudeModels.label(for: "fable", in: o), "Fable 5.2 (latest)")
        XCTAssertEqual(ClaudeModels.label(for: "claude-fable-5-2", in: o), "Fable 5.2"); XCTAssertEqual(ClaudeModels.label(for: "", in: o), "Default"); XCTAssertEqual(ClaudeModels.label(for: "claude-zzz", in: o), "claude-zzz")
        XCTAssertEqual(ClaudeModels.name(ofRunning: "claude-fable-5-2", in: o), "Fable 5.2")
        XCTAssertEqual(ClaudeModels.name(ofRunning: "claude-fable-5-2[1m]", in: o), "Fable 5.2 (1M context)")
        XCTAssertEqual(ClaudeModels.name(ofRunning: "claude-other-1", in: o), "claude-other-1")
    }

    /// On a Mac where Claude Code has fetched its catalog, every model it lists as main is in our list. Skipped elsewhere.
    func testThisMacsOwnCatalogOffersEverythingItListsAsMain() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: ClaudeModels.catalogDirectory, includingPropertiesForKeys: nil)) ?? []
        let parsed = files.compactMap { try? Data(contentsOf: $0) }.compactMap { ClaudeModels.parseCatalog($0) }
        try XCTSkipIf(parsed.isEmpty, "Claude Code has not fetched a model catalog on this Mac")
        let newest = try XCTUnwrap(parsed.filter { $0.surface == "cc" }.max { $0.fetchedAt < $1.fetchedAt } ?? parsed.first)
        let offered = ClaudeModels.current()
        print("REAL MODEL LIST: \(offered.filter { !$0.older }.map(\.label))")
        for m in newest.models where !m.older { XCTAssertTrue(offered.contains { $0.value == m.id }, "\(m.name) (\(m.id)) is missing from the picker") }
    }
}

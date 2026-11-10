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
}

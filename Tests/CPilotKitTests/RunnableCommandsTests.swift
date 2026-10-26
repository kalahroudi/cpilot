// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class RunnableCommandsTests: XCTestCase {
    func found(_ s: String) -> [String] { RunnableCommands.find(in: s).map(\.command) }

    func testOffersThePathToTheBuiltApp() {
        XCTAssertEqual(found("- **Test it yourself:** run `.build/debug/Moose --demo` and click the top row."), [".build/debug/Moose --demo"])
    }
    func testOffersBuildToolsButNotNamesOrFlags() {
        XCTAssertEqual(found("Use `swift test`, then check `Package.swift` and the `--demo` flag in `ChatView.swift`."), ["swift test"])
    }
    func testAPlainCommandNeedsAVerb() {
        XCTAssertEqual(found("It uses `git status` internally."), [])
        XCTAssertEqual(found("Now run `scripts/dev.sh start` to try it."), ["scripts/dev.sh start"])
    }
    func testOneLineFenceCountsAndRepeatsAreDropped() {
        XCTAssertEqual(found("```sh\nnpm run dev\n```\nthen run `npm run dev` again"), ["npm run dev"])
        XCTAssertEqual(found("```sh\nnpm i\nnpm run dev\n```"), [])
    }
    func testDollarPrompt() {
        XCTAssertEqual(RunnableCommands.shellLine("$ swift run"), "swift run")
    }
}

final class TerminalLaunchTests: XCTestCase {
    func testRunsInTheFolderAndKeepsAShell() {
        let a = TerminalLaunch.argv(directory: "/w/it's", command: "$ .build/debug/Moose --demo", env: nil)
        XCTAssertEqual(a.executable, "/bin/zsh")
        XCTAssertEqual(a.args.last, "cd '/w/it'\\''s' && .build/debug/Moose --demo; exec \"${SHELL:-/bin/zsh}\" -l")
    }
    func testGhosttyGetsTheSameCommand() {
        let a = TerminalLaunch.ghosttyOpenArgs(directory: "/w", command: "swift run", env: nil)
        XCTAssertEqual(Array(a.prefix(4)), ["-na", TerminalLaunch.ghosttyApp, "--args", "--working-directory=/w"])
        XCTAssertTrue(a.last!.contains("swift run"))
    }
}

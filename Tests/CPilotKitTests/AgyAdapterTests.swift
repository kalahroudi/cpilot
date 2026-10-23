// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CPilotKit

final class AgyAdapterTests: XCTestCase {
    func testAdapterCarriesTheVersionTheProbeLooksFor() {
        XCTAssertTrue(AgyAdapter.source.contains("// ADAPTER_VERSION = \(AgyAdapter.version)\n"))
        XCTAssertTrue(AgyAdapter.readyProbe.contains("ADAPTER_VERSION = \(AgyAdapter.version)$"))
    }

    func testTheSameConfigRunsOnTheMacAndOnServers() {
        let c = AgyAdapter.config
        XCTAssertEqual(c.id, "agy")
        XCTAssertEqual(c.command, "sh")
        XCTAssertTrue(c.args.joined(separator: " ").contains("$HOME/.cpilot/agy/adapter.mjs"))
        XCTAssertEqual(AgentInstaller.onServer(c, home: "/home/x"), c)
    }

    func testNodeProbeLoadsNpmsDownloader() {
        XCTAssertTrue(Provisioner.nodeProbe.contains("minipass-fetch"))
        XCTAssertTrue(RemoteHost.nodeInstallScript.contains("minipass-fetch"))
        XCTAssertTrue(RemoteHost.nodeInstallScript.contains("mv \"$NEW\" \"$DIR\""))
    }

    func testAgyIsOfferedAsAnExtra() {
        XCTAssertTrue(AcpRegistry.withExtras([]).contains { $0.id == AgyAdapter.agentId && $0.config == AgyAdapter.config })
    }
}

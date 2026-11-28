//
//  PortForwardAndJumpTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class PortForwardAndJumpTests: XCTestCase {
    @MainActor
    func testSocks5ForwardValidationAndCommand() {
        var machine = RDMachine(remoteAddress: "203.0.113.5", remotePort: "22", name: "bastion")
        machine.username = "ops"
        TamioStore.shared.machineGroup.insert(machine)
        defer { TamioStore.shared.machineGroup.delete(machine.id) }

        let forward = RDPortForward(
            forwardOrientation: .dynamicSocks5,
            bindPort: 1080,
            targetHost: "",
            targetPort: 0,
            usingMachine: machine.id
        )
        XCTAssertTrue(forward.isValid())
        XCTAssertTrue(forward.shortDescription().contains("SOCKS5 localhost:1080"))
        XCTAssertTrue(forward.getCommand()?.hasPrefix("ssh -D 1080 ") ?? false)
    }

    func testJumpChainResolutionAndCycleDetection() throws {
        var hop1 = RDMachine(remoteAddress: "10.0.0.1", remotePort: "22", name: "jump-1")
        var hop2 = RDMachine(remoteAddress: "10.0.0.2", remotePort: "22", name: "jump-2")
        var leaf = RDMachine(remoteAddress: "10.0.0.3", remotePort: "22", name: "target")

        hop2.jumpHostIDs = [hop1.id]
        leaf.jumpHostIDs = [hop2.id]
        let map = [hop1.id: hop1, hop2.id: hop2, leaf.id: leaf]

        let chain = try leaf.resolvedJumpChain { map[$0] }
        XCTAssertEqual(chain.map(\.name), ["jump-1", "jump-2"])

        // Cycle: hop1 -> hop2 -> hop1
        hop1.jumpHostIDs = [hop2.id]
        let cyclicMap = [hop1.id: hop1, hop2.id: hop2, leaf.id: leaf]
        XCTAssertThrowsError(try leaf.resolvedJumpChain { cyclicMap[$0] })
    }

    func testPromptStateReaderTracksOSC133AcrossChunks() {
        var reader = PromptStateReader()
        XCTAssertEqual(reader.read("user@host:~$ \u{1B}]133;B\u{07}"), true)
        XCTAssertEqual(reader.read("\u{1B}]133;C\u{07}running..."), false)
        // Split across chunks
        XCTAssertNil(reader.read("done\u{1B}]13"))
        XCTAssertEqual(reader.read("3;B\u{07}"), true)
        XCTAssertEqual(TerminalDirectories.shellChangeDirectoryCommand(for: "/var/log/my'app"), " cd '/var/log/my'\\''app'\r")
    }
}

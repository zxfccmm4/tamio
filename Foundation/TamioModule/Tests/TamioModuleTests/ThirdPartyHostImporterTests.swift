//
//  ThirdPartyHostImporterTests.swift
//  TamioModuleTests
//

import Foundation
@testable import TamioModule
import XCTest

final class ThirdPartyHostImporterTests: XCTestCase {
    func testParsesXshellINI() {
        let xsh = """
        [SessionInfo]
        Description=Production edge node
        [CONNECTION]
        Protocol=SSH
        Host=203.0.113.10
        Port=2222
        [CONNECTION:AUTHENTICATION]
        UserName=deploy
        """
        let result = ThirdPartyHostImporter.parse(data: Data(xsh.utf8), fileName: "edge-01.xsh")
        XCTAssertEqual(result.format, .xshell)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].name, "edge-01")
        XCTAssertEqual(result.hosts[0].address, "203.0.113.10")
        XCTAssertEqual(result.hosts[0].port, 2222)
        XCTAssertEqual(result.hosts[0].username, "deploy")
        XCTAssertEqual(result.hosts[0].comment, "Production edge node")
    }

    func testParsesWindTermSessions() {
        let json = """
        [
          {
            "session.protocol": "SSH",
            "session.label": "Tokyo API",
            "session.target": "ubuntu@198.51.100.7",
            "session.port": 2200,
            "session.group": "Asia"
          }
        ]
        """
        let result = ThirdPartyHostImporter.parse(data: Data(json.utf8), fileName: "user.sessions")
        XCTAssertEqual(result.format, .windTerm)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].name, "Tokyo API")
        XCTAssertEqual(result.hosts[0].address, "198.51.100.7")
        XCTAssertEqual(result.hosts[0].username, "ubuntu")
        XCTAssertEqual(result.hosts[0].port, 2200)
        XCTAssertEqual(result.hosts[0].group, "Asia")
    }

    func testParsesTermiusJSON() {
        let json = """
        {
          "groups": [{ "id": "g1", "label": "Production" }],
          "hosts": [{ "label": "db-01", "address": "10.0.0.5", "port": 22, "username": "postgres", "group": "g1", "tags": ["db", "primary"] }]
        }
        """
        let result = ThirdPartyHostImporter.parse(data: Data(json.utf8), fileName: "termius.json")
        XCTAssertEqual(result.format, .termius)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].group, "Production")
        XCTAssertEqual(result.hosts[0].tags, ["db", "primary"])
    }

    func testParsesFinalShellAndCSV() {
        let fs = #"{"name":"hk-vps","host":"192.0.2.88","port":22,"user_name":"root","description":"HK node"}"#
        let fsResult = ThirdPartyHostImporter.parse(data: Data(fs.utf8), fileName: "hk.json")
        XCTAssertEqual(fsResult.format, .finalShell)
        XCTAssertEqual(fsResult.hosts.first?.address, "192.0.2.88")

        let csv = """
        name,host,port,username,group,tags,comment
        web-1,192.0.2.10,22,www,Web,prod;nginx,Front door
        """
        let csvResult = ThirdPartyHostImporter.parse(data: Data(csv.utf8), fileName: "servers.csv")
        XCTAssertEqual(csvResult.format, .csv)
        XCTAssertEqual(csvResult.hosts.count, 1)
        XCTAssertEqual(csvResult.hosts[0].tags, ["prod", "nginx"])
    }
}

//
//  AgentJobStoreTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

@MainActor
final class AgentJobStoreTests: XCTestCase {
    func testIncrementalPollAndRedaction() async throws {
        let store = AgentJobStore()
        let buffer = AgentJobHostBuffer(host: "web-01", hostID: UUID().uuidString)
        store.registerTestJob(id: "job-1", command: "build", buffers: [buffer])

        buffer.append("step 1\n")
        let first = try await store.poll(jobID: "job-1", offset: 0, maxBytes: 1024, waitSeconds: 0)
        XCTAssertTrue(first.running)
        XCTAssertEqual(first.hosts.first?.output, "step 1\n")
        let nextOffset = first.hosts.first?.nextOffset ?? 0
        XCTAssertEqual(nextOffset, "step 1\n".utf8.count)

        buffer.append("TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwx\n__TAMIO_EXIT__0\n")
        buffer.finish(exitCode: 0, error: nil)

        let second = try await store.poll(jobID: "job-1", offset: nextOffset, maxBytes: 1024, waitSeconds: 0)
        XCTAssertFalse(second.running)
        XCTAssertEqual(second.hosts.first?.status, "exited")
        XCTAssertEqual(second.hosts.first?.exitCode, 0)
        XCTAssertFalse(second.hosts.first?.output.contains("ghp_1234567890") ?? true)
        XCTAssertFalse(second.hosts.first?.output.contains("__TAMIO_EXIT__") ?? true)
    }

    func testStopJobMarksStopped() async throws {
        let store = AgentJobStore()
        let buffer = AgentJobHostBuffer(host: "web-02", hostID: UUID().uuidString)
        store.registerTestJob(id: "job-2", command: "tail -f /var/log/syslog", buffers: [buffer])

        let stopped = try store.stop(jobID: "job-2", hosts: ["web-02"])
        XCTAssertEqual(stopped.stoppedHosts, ["web-02"])
        XCTAssertFalse(buffer.shouldContinue)
        buffer.finish(exitCode: nil, error: nil)

        let polled = try await store.poll(jobID: "job-2", offset: 0, maxBytes: 1024, waitSeconds: 0)
        XCTAssertEqual(polled.hosts.first?.status, "stopped")
    }
}

//
//  AgentJobStore.swift
//  TamioModule
//
//  Background command runner for MCP (`start_command` / `poll_command` /
//  `stop_command`). Long-running commands return a job id immediately and
//  stream output into a bounded, offset-addressed ring buffer so external
//  agents can poll incrementally without hitting synchronous request timeouts.
//

import Foundation
import NSRemoteShell

public struct AgentJobStartResult: Codable, Sendable {
    public var jobID: String
    public var hosts: [String]
}

public struct AgentJobHostPoll: Codable, Sendable {
    public var host: String
    public var hostID: String
    /// "running", "exited", "stopped", or "failed".
    public var status: String
    public var exitCode: Int?
    public var output: String
    public var offset: Int
    public var nextOffset: Int
    public var truncatedBeforeOffset: Bool
    public var error: String?
    public var seconds: Double
}

public struct AgentJobPollResult: Codable, Sendable {
    public var jobID: String
    public var running: Bool
    public var hosts: [AgentJobHostPoll]
}

public struct AgentJobStopResult: Codable, Sendable {
    public var jobID: String
    public var stoppedHosts: [String]
}

/// Thread-safe per-host state for a running background command.
final class AgentJobHostBuffer: @unchecked Sendable {
    static let maxBufferBytes = 2 * 1024 * 1024

    let host: String
    let hostID: String
    let started = Date()

    private let lock = NSLock()
    private var rawBuffer = Data()
    private var baseOffset = 0
    private var _status = "running"
    private var _exitCode: Int?
    private var _error: String?
    private var _finishedAt: Date?
    private var _stopped = false
    private weak var shell: NSRemoteShell?

    init(host: String, hostID: String) {
        self.host = host
        self.hostID = hostID
    }

    func attachShell(_ shell: NSRemoteShell) {
        lock.lock()
        self.shell = shell
        let alreadyStopped = _stopped
        lock.unlock()
        if alreadyStopped {
            DispatchQueue.global(qos: .userInitiated).async {
                shell.requestDisconnectAndWait()
            }
        }
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_stopped
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _status == "running"
    }

    func totalBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return baseOffset + rawBuffer.count
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let bytes = Data(chunk.utf8)
        lock.lock()
        rawBuffer.append(bytes)
        if rawBuffer.count > Self.maxBufferBytes {
            let overflow = rawBuffer.count - Self.maxBufferBytes
            rawBuffer.removeFirst(overflow)
            baseOffset += overflow
        }
        lock.unlock()
    }

    func finish(exitCode: Int?, error: String?) {
        lock.lock()
        if _stopped {
            _status = "stopped"
            _error = error ?? "Stopped by request."
        } else if let exitCode {
            _status = "exited"
            _exitCode = exitCode
            _error = error
        } else {
            _status = "failed"
            _error = error ?? "The command ended without an exit code."
        }
        _finishedAt = Date()
        shell = nil
        lock.unlock()
    }

    func stop() -> Bool {
        lock.lock()
        let wasRunning = _status == "running"
        _stopped = true
        let activeShell = shell
        lock.unlock()
        if let activeShell {
            DispatchQueue.global(qos: .userInitiated).async {
                activeShell.requestDisconnectAndWait()
            }
        }
        return wasRunning
    }

    func snapshot(from requestedOffset: Int, maxBytes: Int) -> AgentJobHostPoll {
        lock.lock()
        let effectiveStart = max(requestedOffset, baseOffset)
        let truncated = requestedOffset < baseOffset
        let localStart = max(0, effectiveStart - baseOffset)
        let available = max(0, rawBuffer.count - localStart)
        let take = min(available, max(1, maxBytes))
        let sliceData = take > 0 ? rawBuffer.subdata(in: localStart ..< (localStart + take)) : Data()
        let nextOffset = effectiveStart + sliceData.count
        let status = _status
        let exitCode = _exitCode
        let error = _error
        let elapsed = (_finishedAt ?? Date()).timeIntervalSince(started)
        lock.unlock()

        var text = String(decoding: sliceData, as: UTF8.self)
        // Strip the internal exit marker if it arrived in this chunk.
        if text.contains(AgentRunner.marker) {
            text = AgentRunner.parse(text).output
        }
        let redacted = SecretRedactor.redactIfEnabled(text).text
        return AgentJobHostPoll(
            host: host,
            hostID: hostID,
            status: status,
            exitCode: exitCode,
            output: redacted,
            offset: effectiveStart,
            nextOffset: nextOffset,
            truncatedBeforeOffset: truncated,
            error: error,
            seconds: elapsed
        )
    }

    func finalTail(limit: Int = 2000) -> AgentActivity.Result {
        lock.lock()
        let tailData = rawBuffer.count > limit * 2 ? rawBuffer.suffix(limit * 2) : rawBuffer
        let exitCode = _exitCode
        lock.unlock()
        let parsed = AgentRunner.parse(String(decoding: tailData, as: UTF8.self))
        let redacted = SecretRedactor.redactIfEnabled(parsed.output).text
        return AgentActivity.Result(
            host: host,
            exitCode: exitCode ?? parsed.exitCode,
            tail: String(redacted.suffix(limit))
        )
    }
}

@MainActor
public final class AgentJobStore {
    public static let shared = AgentJobStore()

    public static let maxConcurrentJobs = 16
    public static let finishedTTL: TimeInterval = 30 * 60

    final class Job {
        let id: String
        let command: String
        let buffers: [AgentJobHostBuffer]
        let createdAt = Date()
        var finishedAt: Date?

        init(id: String = UUID().uuidString, command: String, buffers: [AgentJobHostBuffer]) {
            self.id = id
            self.command = command
            self.buffers = buffers
        }

        var isRunning: Bool {
            buffers.contains { $0.isRunning }
        }
    }

    private var jobs: [String: Job] = [:]

    public init() {}

    /// Starts a background command on `machines` and returns its job handle immediately.
    public func start(
        command: String,
        on machines: [RDMachine],
        sudo: Bool,
        timeout: Double,
        concurrency: Int,
        onComplete: (@MainActor @Sendable ([AgentActivity.Result]) -> Void)? = nil
    ) throws -> AgentJobStartResult {
        pruneExpired()
        let activeCount = jobs.values.filter(\.isRunning).count
        guard activeCount < Self.maxConcurrentJobs else {
            throw AgentToolError("Too many background jobs running (\(activeCount)); stop or wait for one first.")
        }

        struct WorkItem: Sendable {
            let machine: RDMachine
            let identity: RDIdentity?
            let connectTimeoutSeconds: Double
            let buffer: AgentJobHostBuffer
        }

        let store = TamioStore.shared
        let connectTimeoutSeconds = store.timeoutNumber.doubleValue
        let work = machines.map { machine in
            WorkItem(
                machine: machine,
                identity: store.associatedIdentity(for: machine),
                connectTimeoutSeconds: connectTimeoutSeconds,
                buffer: AgentJobHostBuffer(host: machine.name, hostID: machine.id.uuidString)
            )
        }
        let jobID = UUID().uuidString
        let job = Job(id: jobID, command: command, buffers: work.map(\.buffer))
        jobs[jobID] = job

        let script = AgentRunner.wrap(command, sudo: sudo)
        let limit = max(1, min(concurrency, 32))
        let clampedTimeout = max(5, min(timeout, 86_400))

        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func launch(_ index: Int) {
                    let item = work[index]
                    group.addTask {
                        await Self.runOneBackground(
                            script: script,
                            machine: item.machine,
                            identity: item.identity,
                            connectTimeoutSeconds: item.connectTimeoutSeconds,
                            timeout: clampedTimeout,
                            buffer: item.buffer
                        )
                    }
                }
                while next < min(limit, work.count) { launch(next); next += 1 }
                for await _ in group {
                    if next < work.count { launch(next); next += 1 }
                }
            }
            let results = work.map { $0.buffer.finalTail() }
            await MainActor.run {
                self?.jobs[jobID]?.finishedAt = Date()
                onComplete?(results)
            }
        }

        return AgentJobStartResult(jobID: jobID, hosts: machines.map(\.name))
    }

    /// Reads incremental output starting from `offset`, optionally waiting up to
    /// `waitSeconds` (max 30s) for new output or job completion.
    public func poll(
        jobID: String,
        offset: Int = 0,
        maxBytes: Int = 65_536,
        waitSeconds: Double = 0
    ) async throws -> AgentJobPollResult {
        pruneExpired()
        guard let job = jobs[jobID] else {
            throw AgentToolError("No background job \(jobID). It may have expired or never existed.")
        }
        let safeOffset = max(0, offset)
        let safeMax = max(256, min(maxBytes, 512 * 1024))
        let deadline = Date().addingTimeInterval(min(max(0, waitSeconds), 30))

        while job.isRunning, Date() < deadline {
            let hasNewOutput = job.buffers.contains { $0.totalBytes() > safeOffset }
            if hasNewOutput { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let hostPolls = job.buffers.map { $0.snapshot(from: safeOffset, maxBytes: safeMax) }
        return AgentJobPollResult(
            jobID: job.id,
            running: job.isRunning,
            hosts: hostPolls
        )
    }

    /// Stops a running background job across all hosts (or only `hosts` when specified).
    public func stop(jobID: String, hosts: [String] = []) throws -> AgentJobStopResult {
        guard let job = jobs[jobID] else {
            throw AgentToolError("No background job \(jobID).")
        }
        let filter = Set(hosts.map { $0.lowercased() })
        var stopped: [String] = []
        for buffer in job.buffers {
            if filter.isEmpty || filter.contains(buffer.host.lowercased()) || filter.contains(buffer.hostID.lowercased()) {
                if buffer.stop() {
                    stopped.append(buffer.host)
                }
            }
        }
        return AgentJobStopResult(jobID: job.id, stoppedHosts: stopped)
    }

    private func pruneExpired() {
        let now = Date()
        jobs = jobs.filter { _, job in
            if job.isRunning { return true }
            guard let finished = job.finishedAt else { return true }
            return now.timeIntervalSince(finished) < Self.finishedTTL
        }
    }

    private nonisolated static func runOneBackground(
        script: String,
        machine: RDMachine,
        identity: RDIdentity?,
        connectTimeoutSeconds: Double,
        timeout: Double,
        buffer: AgentJobHostBuffer
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let shell = NSRemoteShell.configured(for: machine, timeout: NSNumber(value: connectTimeoutSeconds))
                buffer.attachShell(shell)
                defer {
                    shell.requestDisconnectAndWait()
                    shell.destroyPermanently()
                }
                guard identity != nil || machine.signsInWithoutCredentials else {
                    buffer.finish(exitCode: nil, error: "This server has no password or key in Tamio.")
                    return continuation.resume()
                }
                if let jumpFailure = shell.prepareJumpTunnelIfNeeded(for: machine, timeout: NSNumber(value: connectTimeoutSeconds)) {
                    buffer.finish(exitCode: nil, error: jumpFailure)
                    return continuation.resume()
                }
                shell.requestConnectAndWait()
                guard shell.isConnected else {
                    let reason = shell.hostKeyRefusal ?? shell.getLastError() ?? "Could not reach \(machine.remoteAddress):\(machine.remotePort)."
                    buffer.finish(exitCode: nil, error: reason)
                    return continuation.resume()
                }
                shell.authenticate(for: machine, identity: identity)
                guard shell.isAuthenticated else {
                    let username = machine.loginUsername(with: identity)
                    let reason = ["Could not sign in as \(username).", machine.signsInWithoutCredentials ? shell.getLastError() : nil]
                        .compactMap { $0 }.joined(separator: " ")
                    buffer.finish(exitCode: nil, error: reason)
                    return continuation.resume()
                }

                let deadline = Date().addingTimeInterval(timeout)
                let tailLock = NSLock()
                nonisolated(unsafe) var markerTail = ""

                shell.beginExecute(
                    withCommand: script,
                    withTimeout: NSNumber(value: timeout),
                    withOnCreate: {},
                    withOutput: { chunk in
                        buffer.append(chunk)
                        tailLock.lock()
                        markerTail += chunk
                        if markerTail.count > 256 {
                            markerTail = String(markerTail.suffix(256))
                        }
                        tailLock.unlock()
                    },
                    withContinuationHandler: {
                        buffer.shouldContinue && Date() < deadline
                    }
                )

                tailLock.lock()
                let tail = markerTail
                tailLock.unlock()
                let parsed = AgentRunner.parse(tail)
                if let code = parsed.exitCode {
                    buffer.finish(exitCode: code, error: nil)
                } else if !buffer.shouldContinue {
                    buffer.finish(exitCode: nil, error: "Stopped by request.")
                } else if Date() >= deadline {
                    buffer.finish(exitCode: nil, error: "Timed out after \(Int(timeout)) s.")
                } else {
                    buffer.finish(exitCode: nil, error: "The command ended without an exit code.")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Test Support

    /// Registers a synthetic job buffer for deterministic unit tests without SSH.
    func registerTestJob(id: String, command: String, buffers: [AgentJobHostBuffer]) {
        jobs[id] = Job(id: id, command: command, buffers: buffers)
    }
}

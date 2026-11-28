//
//  AssistantAgentBridge.swift
//  TamioAssistant
//
//  Unified cross-platform AgentEnvironment bridge connecting Tamio's MCP
//  `AgentServer` to each conversation's `AssistantApprovalGate`, live metrics,
//  and port forward backend, while delegating OS-specific fallback alerts and
//  lifecycle hooks cleanly through `AssistantPlatformHooks`.
//

import Foundation
import MachineStatus
import MachineStatusView
import Observation
import TamioModule

// MARK: - Task-Local Tool Call Routing

public enum AssistantTaskContext {
    @TaskLocal public static var conversationID: UUID?
    @TaskLocal public static var toolReason: String?
    @TaskLocal public static var toolArgumentsJSON: String?
    @TaskLocal public static var toolArgumentOrder: [String]?
}

// MARK: - Platform Hooks (Registered Once by Mac / iOS App Entry)

@MainActor
public final class AssistantPlatformHooks {
    public static let shared = AssistantPlatformHooks()

    /// Called when an approval arrives outside an active in-app conversation.
    public var fallbackApprove: ((AgentRequest) async -> Bool)?

    /// Called when the set of executing conversations changes (e.g. iOS BackgroundGraceController).
    public var onExecutingSessionsChanged: ((Set<UUID>) -> Void)?

    /// Called by `AssistantAgentBridge.install()` on macOS to attach its inline handler
    /// to `AgentBridge` without replacing external MCP socket alerts.
    public var onInstallInlineApprovalBridge: ((@escaping (AgentRequest) async -> Bool?) -> Void)?

    private init() {}
}

// MARK: - Unified Agent Bridge

@MainActor
@Observable
public final class AssistantAgentBridge: AgentEnvironment {
    public static let shared = AssistantAgentBridge()

    /// Kept true while any assistant view or terminal copilot is active.
    public var inlineApprovalActive = false

    private init() {}

    public func install() {
        if let hook = AssistantPlatformHooks.shared.onInstallInlineApprovalBridge {
            hook { [weak self] request in
                guard let self, AssistantTaskContext.conversationID != nil else { return nil }
                return await self.approve(request)
            }
        } else {
            AgentServer.shared.environment = self
        }
    }

    public func hasPendingApproval(for conversationID: UUID) -> Bool {
        ServerAssistant.shared.sessionIfLoaded(for: conversationID)?.approvalGate.hasPendingRequest ?? false
    }

    public var totalPendingApprovalCount: Int {
        ServerAssistant.shared.pendingApprovalConversationIDs.count
    }

    public func resolve(_ request: AssistantApprovalRequest, decision: AssistantApprovalDecision) {
        if decision == .approveForOneHour, !request.isDestructive {
            AgentServer.shared.allowForAnHour(request.client)
        }
        ServerAssistant.shared.sessionIfLoaded(for: request.conversationID)?
            .approvalGate.resolve(request.id, with: decision)
    }

    public func denyPending(for conversationID: UUID) {
        ServerAssistant.shared.sessionIfLoaded(for: conversationID)?.approvalGate.denyPending()
    }

    public func denyAllPending() {
        ServerAssistant.shared.denyAllPendingApprovals()
    }

    // MARK: AgentEnvironment

    public func approve(_ request: AgentRequest) async -> Bool {
        if let cid = AssistantTaskContext.conversationID {
            let risk = request.risk ?? CommandRiskClassifier.classifyTool(
                request.tool,
                detail: request.detail,
                sudo: request.title.localizedCaseInsensitiveContains("sudo")
            )
            let approvalRequest = AssistantApprovalRequest(
                conversationID: cid,
                client: request.client,
                toolName: request.tool,
                title: request.title,
                icon: TamioMCPBuiltinTool.icon(for: request.tool),
                source: String(localized: "Tamio Built-in"),
                reason: AssistantTaskContext.toolReason,
                task: request.task,
                detail: request.detail,
                argumentsJSON: AssistantTaskContext.toolArgumentsJSON ?? "{}",
                argumentOrder: AssistantTaskContext.toolArgumentOrder ?? [],
                hosts: request.hosts,
                risk: risk
            )
            let session = ServerAssistant.shared.session(for: cid)
            let decision = await session.approvalGate.request(approvalRequest)
            switch decision {
            case .approve:
                return true
            case .approveForOneHour:
                if !risk.isDestructive {
                    AgentServer.shared.allowForAnHour(request.client)
                }
                return true
            case .deny:
                return false
            }
        }

        if let fallback = AssistantPlatformHooks.shared.fallbackApprove {
            return await fallback(request)
        }
        return false
    }

    public func prepareMetrics(for machines: [RDMachine.ID]) {
        LiveStatusCenter.shared.lease(machines)
    }

    public func metrics(for machine: RDMachine.ID) async -> JSONValue? {
        guard let session = await LiveStatusCenter.shared.requestSession(for: machine),
              session.status.hasData
        else { return nil }

        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        func number(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }

        return [
            "os": .string(status.system.releaseName),
            "hostname": .string(status.system.hostname),
            "uptimeSeconds": number(status.system.uptimeSec),
            "cores": .number(Double(status.cores)),
            "cpuPercent": number(Double(status.processor.summary.sumUsed)),
            "load": [
                number(Double(status.system.load1)),
                number(Double(status.system.load5)),
                number(Double(status.system.load15)),
            ],
            "memoryPercent": number(status.memoryUsedPercent),
            "memoryUsedBytes": number(status.memoryUsedKB * 1000),
            "memoryTotalBytes": number(status.memory.memTotal * 1000),
            "swapUsedBytes": number(max(0, status.memory.swapTotal - status.memory.swapFree) * 1000),
            "disks": .array(status.fileSystem.elements.map {
                [
                    "mount": .string($0.mountPoint),
                    "usedPercent": number(Double($0.percent)),
                    "used": .string($0.used),
                    "size": .string($0.size),
                ]
            }),
            "rootDiskPercent": root.map { number(Double($0.percent)) } ?? .null,
            "networkUpBytesPerSecond": number(Double(physical.map(\.txBytesPerSec).reduce(0, +))),
            "networkDownBytesPerSecond": number(Double(physical.map(\.rxBytesPerSec).reduce(0, +))),
            "trafficSinceBootUpBytes": number(Double(physical.map(\.txBytesTotal).reduce(0, +))),
            "trafficSinceBootDownBytes": number(Double(physical.map(\.rxBytesTotal).reduce(0, +))),
            "updated": .string(session.lastUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
        ]
    }

    public func isForwarding(_ forward: RDPortForward.ID) -> Bool {
        PortForwardBackend.shared.sessionExists(withPortForwardID: forward)
    }

    public func startForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.createSession(withPortForwardID: forward)
    }

    public func stopForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.endSession(withPortForwardID: forward)
    }
}

/// Preserves call-site compatibility across macOS and iOS apps.
public typealias MobileAgentBridge = AssistantAgentBridge

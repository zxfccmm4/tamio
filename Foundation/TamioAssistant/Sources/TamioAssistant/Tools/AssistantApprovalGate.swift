//
//  AssistantApprovalGate.swift
//  TamioAssistant
//
//  FlowDown `ModelToolApprovalGate` pattern combined with Tamio's
//  `CommandRiskClassifier` and 1-hour non-destructive trust window.
//  Each `ConversationSession` owns its own gate; when a tool waits for approval,
//  the composer morphs in-place into the approval card. Task cancellation
//  automatically resolves `.deny` so continuations never leak.
//

import Foundation
import Observation
import TamioModule

public nonisolated struct AssistantApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let client: String
    public let toolName: String
    public let title: String
    public let icon: String
    /// Optional source badge (e.g. "Tamio Built-in" or external MCP server name).
    public let source: String?
    /// Model-supplied `reason` explaining why it wants to run this action.
    public let reason: String?
    /// Optional task label grouped in `AgentActivityLog`.
    public let task: String?
    /// Human-readable summary or raw command detail.
    public let detail: String
    /// Optional structured arguments JSON for parameter-by-parameter display.
    public let argumentsJSON: String
    public let argumentOrder: [String]
    public let hosts: [String]
    public let risk: CommandRiskAssessment
    public let createdAt: Date

    public var isDestructive: Bool {
        risk.isDestructive
    }

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        client: String,
        toolName: String,
        title: String,
        icon: String = "terminal.fill",
        source: String? = nil,
        reason: String? = nil,
        task: String? = nil,
        detail: String,
        argumentsJSON: String = "{}",
        argumentOrder: [String] = [],
        hosts: [String] = [],
        risk: CommandRiskAssessment,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.client = client
        self.toolName = toolName
        self.title = title
        self.icon = icon
        self.source = source
        self.reason = reason
        self.task = task
        self.detail = detail
        self.argumentsJSON = argumentsJSON
        self.argumentOrder = argumentOrder
        self.hosts = hosts
        self.risk = risk
        self.createdAt = createdAt
    }
}

public nonisolated enum AssistantApprovalDecision: Equatable, Sendable {
    case approve
    case approveForOneHour
    case deny
}

/// Per-conversation approval gate. Holds at most one active request at a time
/// (calls execute sequentially) and drives the composer's in-place approval card.
@MainActor
@Observable
public final class AssistantApprovalGate {
    public private(set) var pendingRequest: AssistantApprovalRequest?

    private var waiting: (id: UUID, continuation: CheckedContinuation<AssistantApprovalDecision, Never>)?

    public init() {}

    public var hasPendingRequest: Bool {
        pendingRequest != nil
    }

    /// Suspends until the user makes a decision or the enclosing task is cancelled.
    public func request(_ request: AssistantApprovalRequest) async -> AssistantApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                if let previous = waiting {
                    waiting = nil
                    previous.continuation.resume(returning: .deny)
                }
                waiting = (request.id, continuation)
                pendingRequest = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(request.id, with: .deny)
            }
        }
    }

    /// Resolves the currently waiting request if its ID matches.
    public func resolve(_ id: UUID, with decision: AssistantApprovalDecision) {
        guard let current = waiting, current.id == id else { return }
        waiting = nil
        pendingRequest = nil
        current.continuation.resume(returning: decision)
    }

    /// Denies any currently waiting request (called on Stop / conversation delete).
    public func denyPending() {
        guard let current = waiting else { return }
        waiting = nil
        pendingRequest = nil
        current.continuation.resume(returning: .deny)
    }
}

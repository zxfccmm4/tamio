//
//  AssistantMessage.swift
//  TamioAssistant
//
//  Persistent chat message & tool execution records, backward-compatible with
//  legacy Tamio JSON conversation files while adding FlowDown-grade metadata:
//  tool `reason`, execution status lifecycle, `thinkingDuration`, attachments,
//  and grouped parallel tool call turns.
//

import Foundation
import TamioModule

// MARK: - Tool Call Wire Model

public nonisolated struct LLMToolCall: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public func decodedJSONValue() -> JSONValue {
        guard let data = argumentsJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return [:]
        }
        return value
    }

    public func decodedDictionary() -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }
}

// MARK: - Tool Execution Status & Record

public nonisolated enum AssistantToolExecutionStatus: String, Codable, Equatable, Hashable, Sendable {
    case running
    case succeeded
    case failed
    case denied
    case cancelled
}

public nonisolated struct AssistantToolExecution: Codable, Equatable, Hashable, Sendable {
    public let callID: String
    public let toolName: String
    public let argumentsJSON: String
    /// Raw arguments including the model's `reason` for Trace/Replay display.
    public var rawArgumentsJSON: String?
    /// Model-supplied human-readable reason (`ModelToolReason`), shown in banners & Trace.
    public var reason: String?
    public var output: String
    public var isError: Bool
    public var status: AssistantToolExecutionStatus
    public var targetHosts: [String]
    public var durationMs: Int
    /// Groups parallel calls emitted in the same assistant turn so replay keeps them together.
    public var turnGroupID: UUID?

    public init(
        callID: String,
        toolName: String,
        argumentsJSON: String,
        rawArgumentsJSON: String? = nil,
        reason: String? = nil,
        output: String = "",
        isError: Bool = false,
        status: AssistantToolExecutionStatus? = nil,
        targetHosts: [String] = [],
        durationMs: Int = 0,
        turnGroupID: UUID? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.rawArgumentsJSON = rawArgumentsJSON
        self.reason = reason
        self.output = output
        self.isError = isError
        self.status = status ?? (isError ? .failed : .succeeded)
        self.targetHosts = targetHosts
        self.durationMs = durationMs
        self.turnGroupID = turnGroupID
    }

    private enum CodingKeys: String, CodingKey {
        case callID, toolName, argumentsJSON, rawArgumentsJSON, reason
        case output, isError, status, targetHosts, durationMs, turnGroupID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callID = try c.decode(String.self, forKey: .callID)
        toolName = try c.decode(String.self, forKey: .toolName)
        argumentsJSON = try c.decode(String.self, forKey: .argumentsJSON)
        rawArgumentsJSON = try c.decodeIfPresent(String.self, forKey: .rawArgumentsJSON)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        status = try c.decodeIfPresent(AssistantToolExecutionStatus.self, forKey: .status)
            ?? (isError ? .failed : .succeeded)
        targetHosts = try c.decodeIfPresent([String].self, forKey: .targetHosts) ?? []
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        turnGroupID = try c.decodeIfPresent(UUID.self, forKey: .turnGroupID)
    }

    public var isRunning: Bool {
        status == .running
    }

    /// Best arguments string for Trace inspection (prefers raw JSON carrying `reason`).
    public var displayArgumentsJSON: String {
        if let raw = rawArgumentsJSON, !raw.isEmpty { return raw }
        return argumentsJSON
    }
}

// MARK: - Persistent Chat Message (Single Source of Truth)

public nonisolated struct AssistantChatMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Role: String, Codable, Equatable, Hashable, Sendable {
        case user
        case assistant
        case toolCall
        case notice
        case error
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var reasoning: String
    /// Whole/fractional seconds spent thinking in this assistant turn (for ActivitySummary).
    public var thinkingDuration: TimeInterval
    /// True when `text` is only an internal replay placeholder (e.g. interrupted reasoning)
    /// and should stay folded into ActivitySummary rather than rendering an AI prose row.
    public var isPlaceholderText: Bool
    /// Groups an intermediate assistant thought/reply with the parallel tool calls it emitted.
    public var turnGroupID: UUID?
    public var toolExecution: AssistantToolExecution?
    public var attachments: [AssistantAttachment]
    public var timestamp: Date
    public var modelLabel: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        reasoning: String = "",
        thinkingDuration: TimeInterval = 0,
        isPlaceholderText: Bool = false,
        turnGroupID: UUID? = nil,
        toolExecution: AssistantToolExecution? = nil,
        attachments: [AssistantAttachment] = [],
        timestamp: Date = Date(),
        modelLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.thinkingDuration = thinkingDuration
        self.isPlaceholderText = isPlaceholderText
        self.turnGroupID = turnGroupID
        self.toolExecution = toolExecution
        self.attachments = attachments
        self.timestamp = timestamp
        self.modelLabel = modelLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, reasoning, thinkingDuration, isPlaceholderText
        case turnGroupID, toolExecution, attachments, timestamp, modelLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        thinkingDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .thinkingDuration) ?? 0
        isPlaceholderText = try c.decodeIfPresent(Bool.self, forKey: .isPlaceholderText) ?? false
        turnGroupID = try c.decodeIfPresent(UUID.self, forKey: .turnGroupID)
        toolExecution = try c.decodeIfPresent(AssistantToolExecution.self, forKey: .toolExecution)
        attachments = try c.decodeIfPresent([AssistantAttachment].self, forKey: .attachments) ?? []
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        modelLabel = try c.decodeIfPresent(String.self, forKey: .modelLabel)
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedReasoning: String {
        reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the message carries visible content worth rendering in the transcript.
    public var hasVisibleContent: Bool {
        switch role {
        case .user:
            !trimmedText.isEmpty || !attachments.isEmpty
        case .notice, .error:
            !trimmedText.isEmpty
        case .assistant:
            (!trimmedText.isEmpty && !isPlaceholderText) || !trimmedReasoning.isEmpty
        case .toolCall:
            toolExecution != nil
        }
    }
}

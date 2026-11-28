//
//  AssistantTool.swift
//  TamioAssistant
//
//  FlowDown-inspired protocolized tool architecture:
//  - `AssistantToolGroup`: toggleable capability groups in QuickSettingBar
//  - `AssistantToolAccess`: risk/approval tier
//  - `AssistantTool`: pure execution contract (no UI presentation)
//  - `AssistantToolOutput`: 64KB truncated model-safe output
//

import Foundation
import TamioModule

// MARK: - Tool Groups

public nonisolated enum AssistantToolGroup: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case observation
    case remoteShell
    case fleetManagement
    case skills

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .observation: String(localized: "Hosts & Metrics")
        case .remoteShell: String(localized: "Remote Commands")
        case .fleetManagement: String(localized: "Fleet Management")
        case .skills: String(localized: "Ops Skills")
        }
    }

    public var subtitle: String {
        switch self {
        case .observation: String(localized: "Read-only server inventory, live status & activity history")
        case .remoteShell: String(localized: "Approval-gated shell commands, background jobs & snippets")
        case .fleetManagement: String(localized: "Add/edit servers, SSH keys, snippets & port forwards")
        case .skills: String(localized: "Load built-in and custom server operations runbooks")
        }
    }

    public var systemImage: String {
        switch self {
        case .observation: "gauge.with.dots.needle.67percent"
        case .remoteShell: "terminal"
        case .fleetManagement: "server.rack"
        case .skills: "wand.and.stars"
        }
    }

    public var isReadOnlyGroup: Bool {
        switch self {
        case .observation, .skills: true
        case .remoteShell, .fleetManagement: false
        }
    }
}

// MARK: - Tool Access Tier

public nonisolated enum AssistantToolAccess: Equatable, Hashable, Sendable {
    /// Read-only inspection tools that run immediately without blocking on approval.
    case readOnly
    /// Commands or state mutations guarded by AgentServer + AssistantApprovalGate.
    case approvalGated
}

// MARK: - Tool Arguments & Context

public nonisolated struct AssistantToolArguments: Equatable, Hashable, Sendable {
    public let json: String

    public init(json: String) {
        self.json = json
    }

    public func decodedJSONValue() -> JSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return [:]
        }
        return value
    }

    public func decodedDictionary() -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }
}

public nonisolated struct AssistantToolContext: Sendable {
    public let conversationID: UUID
    public let clientName: String
    public let reason: String?
    public let argumentOrder: [String]
    public let rawArgumentsJSON: String

    public init(
        conversationID: UUID,
        clientName: String,
        reason: String?,
        argumentOrder: [String],
        rawArgumentsJSON: String
    ) {
        self.conversationID = conversationID
        self.clientName = clientName
        self.reason = reason
        self.argumentOrder = argumentOrder
        self.rawArgumentsJSON = rawArgumentsJSON
    }
}

// MARK: - Tool Output (64KB Safety Cap)

public nonisolated struct AssistantToolOutput: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public var targetHosts: [String]

    /// Past this many characters output is truncated with an explicit note to the model.
    public static let textLimit = 64 * 1024

    public init(text: String, isError: Bool = false, targetHosts: [String] = []) {
        self.text = text
        self.isError = isError
        self.targetHosts = targetHosts
    }

    public var truncatedText: String {
        guard text.count > Self.textLimit else { return text }
        return """
        \(String(text.prefix(Self.textLimit)))…
        [truncated output due to length exceeding \(Self.textLimit) characters]
        """
    }

    public var modelText: String {
        let truncated = truncatedText
        if truncated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isError
                ? "Tool failed with no output."
                : "Tool executed successfully with no output."
        }
        return truncated
    }
}

// MARK: - Tool Schema (Wire Definition)

/// JSON Schema tool definition passed to remote LLM providers.
public nonisolated struct LLMToolSchema: Equatable, Hashable, Sendable {
    public let name: String
    public let description: String
    /// Raw JSON bytes of the `inputSchema` object so nested schemas pass through verbatim.
    public let inputSchemaJSON: Data

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = (try? JSONEncoder().encode(inputSchema))
            ?? Data("{\"type\":\"object\",\"properties\":{}}".utf8)
    }

    public init(name: String, description: String, inputSchemaJSON: Data) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }

    public func inputSchemaObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: inputSchemaJSON) as? [String: Any])
            ?? ["type": "object", "properties": [:]]
    }

    public func inputSchemaJSONValue() -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: inputSchemaJSON))
            ?? ["type": "object", "properties": [:]]
    }
}

// MARK: - AssistantTool Protocol (FlowDown ModelTool Equivalent)

public protocol AssistantTool: AnyObject, Sendable {
    var functionName: String { get }
    var displayName: String { get }
    var activeStatusText: String { get }
    var systemImage: String { get }
    var group: AssistantToolGroup { get }
    var access: AssistantToolAccess { get }
    /// Base wire definition before `AssistantToolReason` injects `reason`.
    var schema: LLMToolSchema { get }
    /// Preferred parameter display order for approval & Trace UI.
    var argumentOrder: [String] { get }
    /// Optional human-readable summary shown in the approval card.
    func approvalSummary(for arguments: AssistantToolArguments) -> String?
    /// Extracts referenced server names/groups/tags for Trace badges.
    func targetHosts(from arguments: AssistantToolArguments) -> [String]
    /// Executes the tool. Must never present UI directly.
    func execute(
        _ arguments: AssistantToolArguments,
        context: AssistantToolContext
    ) async throws -> AssistantToolOutput
}

public extension AssistantTool {
    var argumentOrder: [String] { [] }

    func approvalSummary(for _: AssistantToolArguments) -> String? { nil }

    func targetHosts(from arguments: AssistantToolArguments) -> [String] {
        let args = arguments.decodedJSONValue()
        var found: [String] = []
        if let single = args["host"]?.string, !single.isEmpty {
            found.append(single)
        }
        if let list = args["hosts"]?.strings {
            found.append(contentsOf: list)
        }
        if let targets = args["targets"] {
            if let list = targets["hosts"]?.strings {
                found.append(contentsOf: list)
            }
            if let group = targets["group"]?.string, !group.isEmpty {
                found.append("#\(group)")
            }
            if let tag = targets["tag"]?.string, !tag.isEmpty {
                found.append("@\(tag)")
            }
            if targets["all"]?.bool == true {
                found.append(String(localized: "All Servers"))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }
}

public nonisolated enum AssistantToolError: LocalizedError, Sendable {
    case denied
    case failure(String)

    public var errorDescription: String? {
        switch self {
        case .denied: String(localized: "Tool call denied by user.")
        case .failure(let message): message
        }
    }
}

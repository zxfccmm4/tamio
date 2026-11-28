//
//  AssistantToolSet.swift
//  TamioAssistant
//
//  FlowDown `ModelToolSet` pattern:
//  Freezes the exact set of tools offered at the start of an inference turn.
//  Mid-turn UI changes never break in-flight tool resolution; unknown tool names,
//  case variations, `reason` stripping, and null-key cleanup are handled cleanly.
//

import Foundation
import TamioModule

public nonisolated struct AssistantToolSet: Sendable {
    public struct ResolvedCall: Sendable {
        public let tool: any AssistantTool
        /// Cleaned arguments JSON (with injected `reason` removed and null optionals stripped).
        public let arguments: AssistantToolArguments
        /// Model-provided reason extracted from the call, if present.
        public let reason: String?
        /// Display order for arguments in Approval & Trace sheets.
        public let argumentOrder: [String]
        /// Raw JSON as sent by the model (including `reason`).
        public let rawArgumentsJSON: String
    }

    private struct Entry: Sendable {
        let tool: any AssistantTool
        let offeredSchema: LLMToolSchema
        /// True when `AssistantToolReason` injected `reason` so it must be stripped before execution.
        let carriesInjectedReason: Bool
    }

    private let entries: [Entry]

    public static let empty = AssistantToolSet(tools: [])

    public init(tools: [any AssistantTool], injectReason: Bool = true) {
        entries = tools.map { tool in
            if injectReason, let augmented = AssistantToolReason.adding(to: tool.schema) {
                return Entry(tool: tool, offeredSchema: augmented, carriesInjectedReason: true)
            }
            return Entry(tool: tool, offeredSchema: tool.schema, carriesInjectedReason: false)
        }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Wire-ready schemas offered to the LLM.
    public var schemas: [LLMToolSchema] {
        entries.map(\.offeredSchema)
    }

    public func contains(named name: String) -> Bool {
        entry(named: name) != nil
    }

    /// Resolves a model's `LLMToolCall` against the frozen tool snapshot.
    public func resolve(_ call: LLMToolCall) -> ResolvedCall? {
        guard let entry = entry(named: call.name) else { return nil }
        let rawJSON = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{}"
            : call.argumentsJSON
        let split: (arguments: String, reason: String?)
        if entry.carriesInjectedReason {
            split = AssistantToolReason.split(rawJSON)
        } else {
            split = (rawJSON, AssistantToolReason.reason(in: rawJSON))
        }
        let cleanedArgs = Self.stripNullValues(from: split.arguments)
        let order = AssistantToolArgumentOrder.order(schema: entry.tool.argumentOrder, arguments: rawJSON)
        return ResolvedCall(
            tool: entry.tool,
            arguments: AssistantToolArguments(json: cleanedArgs),
            reason: split.reason,
            argumentOrder: order,
            rawArgumentsJSON: rawJSON
        )
    }

    private func entry(named name: String) -> Entry? {
        entries.first { $0.tool.functionName == name }
            ?? entries.first { $0.tool.functionName.lowercased() == name.lowercased() }
    }

    /// Drops JSON keys with explicit `null` values so optional parameters fall back
    /// cleanly to server defaults (matching FlowDown's strict-schema null stripping).
    public static func stripNullValues(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return json
        }
        let filtered = dict.filter { !($0.value is NSNull) }
        guard filtered.count != dict.count,
              let out = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8)
        else {
            return json
        }
        return str
    }
}

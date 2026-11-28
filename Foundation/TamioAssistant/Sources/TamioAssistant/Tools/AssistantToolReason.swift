//
//  AssistantToolReason.swift
//  TamioAssistant
//
//  FlowDown `ModelToolReason` pattern:
//  Injects a required `reason` parameter into every offered tool schema that
//  doesn't already declare one, then strips `reason` out before forwarding the
//  clean arguments to the underlying MCP/built-in tool.
//  This gives every running banner, Trace row, and approval card a concise
//  user-language explanation of WHY the model invoked the tool.
//

import Foundation
import TamioModule

public nonisolated enum AssistantToolReason {
    public static let key = "reason"

    private static let parameterSchema: JSONValue = [
        "type": "string",
        "description": "A short phrase in the user's language explaining why you are making this call, shown in the UI (e.g. \"Check disk usage on prod nodes\").",
    ]

    /// Returns a modified schema with required `reason`, or `nil` when the tool
    /// already declares its own `reason` parameter (in which case nothing is added or stripped).
    public static func adding(to schema: LLMToolSchema) -> LLMToolSchema? {
        var root = schema.inputSchemaJSONValue()
        guard case var .object(rootObj) = root else { return nil }

        var properties: [String: JSONValue] = [:]
        if case let .object(existingProps)? = rootObj["properties"] {
            properties = existingProps
        }
        guard properties[key] == nil else { return nil }

        properties[key] = parameterSchema
        rootObj["type"] = rootObj["type"] ?? .string("object")
        rootObj["properties"] = .object(properties)

        var required: [JSONValue] = []
        if case let .array(existingReq)? = rootObj["required"] {
            required = existingReq
        }
        if !required.contains(.string(key)) {
            required.append(.string(key))
        }
        rootObj["required"] = .array(required)

        root = .object(rootObj)
        return LLMToolSchema(name: schema.name, description: schema.description, inputSchema: root)
    }

    /// Splits wire JSON into clean tool arguments (without `reason`) and the extracted reason.
    public static func split(_ json: String) -> (arguments: String, reason: String?) {
        guard let data = json.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawValue = object.removeValue(forKey: key)
        else {
            return (json, nil)
        }
        let reason = normalized(rawValue)
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let cleaned = String(data: encoded, encoding: .utf8)
        else {
            return (json, reason)
        }
        return (cleaned, reason)
    }

    /// Reads `reason` from stored raw call JSON without mutating it.
    public static func reason(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return normalized(object[key])
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty
        else {
            return nil
        }
        return str
    }
}

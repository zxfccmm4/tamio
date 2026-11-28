//
//  TamioBuiltinTools.swift
//  TamioAssistant
//
//  Wraps Tamio's MCP `AgentServer.toolDefinitions`, `load_skill`, and
//  `request_agent_mode` into protocolized `AssistantTool` instances with
//  capability grouping, SF Symbol icons, localized titles, and approval summaries.
//

import Foundation
import TamioModule

// MARK: - MCP AgentServer Tool Wrapper

public final class TamioMCPBuiltinTool: AssistantTool, @unchecked Sendable {
    public let functionName: String
    public let displayName: String
    public let activeStatusText: String
    public let systemImage: String
    public let group: AssistantToolGroup
    public let access: AssistantToolAccess
    public let schema: LLMToolSchema
    public let argumentOrder: [String]

    public init(definition: JSONValue) {
        let name = definition["name"]?.string ?? "unknown"
        let description = definition["description"]?.string ?? ""
        let inputSchema = definition["inputSchema"] ?? ["type": "object", "properties": [:]]
        let readOnly = definition["annotations"]?["readOnlyHint"]?.bool ?? false

        self.functionName = name
        self.displayName = Self.localizedTitle(for: name)
        self.activeStatusText = Self.localizedActivity(for: name)
        self.systemImage = Self.icon(for: name)
        self.group = Self.group(for: name, readOnly: readOnly)
        self.access = readOnly ? .readOnly : .approvalGated
        self.schema = LLMToolSchema(name: name, description: description, inputSchema: inputSchema)
        self.argumentOrder = Self.preferredOrder(for: name)
    }

    public func approvalSummary(for arguments: AssistantToolArguments) -> String? {
        let args = arguments.decodedJSONValue()
        switch functionName {
        case "run_command":
            if let cmd = args["command"]?.string, !cmd.isEmpty {
                return cmd
            }
        case "start_command":
            if let cmd = args["command"]?.string, !cmd.isEmpty {
                return cmd
            }
        case "run_snippet":
            if let snippet = args["snippet"]?.string, !snippet.isEmpty {
                return String(localized: "Run saved snippet \"\(snippet)\"")
            }
        default:
            break
        }
        return nil
    }

    public func execute(
        _ arguments: AssistantToolArguments,
        context: AssistantToolContext
    ) async throws -> AssistantToolOutput {
        let args = arguments.decodedJSONValue()
        let hosts = targetHosts(from: arguments)
        let reply = await AssistantTaskContext.$conversationID.withValue(context.conversationID) {
            await AssistantTaskContext.$toolReason.withValue(context.reason) {
                await AssistantTaskContext.$toolArgumentsJSON.withValue(arguments.json) {
                    await AssistantTaskContext.$toolArgumentOrder.withValue(context.argumentOrder) {
                        await AgentServer.shared.invokeTool(
                            functionName,
                            arguments: args,
                            client: context.clientName
                        )
                    }
                }
            }
        }
        return AssistantToolOutput(text: reply.text, isError: reply.isError, targetHosts: hosts)
    }

    // MARK: - Catalog Metadata

    @MainActor
    public static func allBuiltInMCPTools() -> [TamioMCPBuiltinTool] {
        AgentServer.toolDefinitions.compactMap { def in
            guard def["name"]?.string != nil else { return nil }
            return TamioMCPBuiltinTool(definition: def)
        }
    }

    public static func group(for name: String, readOnly: Bool) -> AssistantToolGroup {
        switch name {
        case "list_hosts", "get_host", "get_metrics", "export_ssh_config", "get_activity":
            .observation
        case "run_command", "start_command", "poll_command", "stop_command", "run_snippet":
            .remoteShell
        default:
            readOnly ? .observation : .fleetManagement
        }
    }

    public static func icon(for name: String) -> String {
        switch name {
        case "list_hosts", "get_host": "server.rack"
        case "get_metrics": "gauge.with.dots.needle.67percent"
        case "export_ssh_config": "doc.text"
        case "run_command", "start_command", "poll_command", "stop_command": "terminal.fill"
        case "run_snippet": "applescript"
        case "add_host", "update_host", "remove_host": "desktopcomputer"
        case "list_identities", "add_identity", "remove_identity": "key.fill"
        case "list_snippets", "add_snippet", "update_snippet", "remove_snippet": "curlybraces"
        case "list_port_forwards", "add_port_forward", "start_port_forward", "stop_port_forward", "remove_port_forward":
            "arrow.left.arrow.right"
        case "get_activity", "log_activity": "clock.arrow.circlepath"
        case "load_skill": "wand.and.stars"
        default: "wrench.and.screwdriver"
        }
    }

    private static func preferredOrder(for name: String) -> [String] {
        switch name {
        case "run_command", "start_command":
            ["reason", "task", "targets", "command", "sudo", "timeout", "concurrency"]
        case "run_snippet":
            ["reason", "task", "targets", "snippet", "sudo", "timeout"]
        case "poll_command", "stop_command":
            ["reason", "job_id", "hosts", "offset", "max_bytes", "wait_seconds"]
        case "add_host", "update_host":
            ["reason", "task", "host", "name", "address", "port", "username", "group", "tags", "identity", "auth", "proxy_command"]
        case "add_port_forward":
            ["reason", "task", "host", "direction", "bind_port", "target_host", "target_port", "start"]
        default:
            ["reason", "task", "host", "hosts", "targets"]
        }
    }

    public static func localizedTitle(for name: String) -> String {
        switch name {
        case "list_hosts": String(localized: "List Servers")
        case "get_host": String(localized: "Inspect Server")
        case "get_metrics": String(localized: "Live Metrics")
        case "export_ssh_config": String(localized: "Export SSH Config")
        case "run_command": String(localized: "Run Command")
        case "start_command": String(localized: "Start Background Command")
        case "poll_command": String(localized: "Poll Background Command")
        case "stop_command": String(localized: "Stop Background Command")
        case "run_snippet": String(localized: "Run Snippet")
        case "add_host": String(localized: "Add Server")
        case "update_host": String(localized: "Update Server")
        case "remove_host": String(localized: "Remove Server")
        case "list_identities": String(localized: "List Identities")
        case "add_identity": String(localized: "Add Identity")
        case "remove_identity": String(localized: "Remove Identity")
        case "list_snippets": String(localized: "List Snippets")
        case "add_snippet": String(localized: "Add Snippet")
        case "update_snippet": String(localized: "Update Snippet")
        case "remove_snippet": String(localized: "Remove Snippet")
        case "list_port_forwards": String(localized: "List Port Forwards")
        case "add_port_forward": String(localized: "Add Port Forward")
        case "start_port_forward": String(localized: "Start Port Forward")
        case "stop_port_forward": String(localized: "Stop Port Forward")
        case "remove_port_forward": String(localized: "Remove Port Forward")
        case "get_activity": String(localized: "Agent History")
        case "log_activity": String(localized: "Log Activity")
        case "load_skill": String(localized: "Load Ops Skill")
        case "request_agent_mode": String(localized: "Switch to Agent Mode")
        default: name
        }
    }

    public static func localizedActivity(for name: String) -> String {
        switch name {
        case "list_hosts": String(localized: "Listing saved servers…")
        case "get_host": String(localized: "Inspecting server details…")
        case "get_metrics": String(localized: "Reading live server metrics…")
        case "export_ssh_config": String(localized: "Exporting SSH config…")
        case "run_command": String(localized: "Running command on servers…")
        case "start_command": String(localized: "Starting background command…")
        case "poll_command": String(localized: "Checking background command…")
        case "stop_command": String(localized: "Stopping background command…")
        case "run_snippet": String(localized: "Running saved snippet…")
        case "add_host": String(localized: "Adding server…")
        case "update_host": String(localized: "Updating server…")
        case "remove_host": String(localized: "Removing server…")
        case "list_identities": String(localized: "Listing SSH identities…")
        case "add_identity": String(localized: "Creating SSH identity…")
        case "remove_identity": String(localized: "Removing SSH identity…")
        case "list_snippets": String(localized: "Listing saved snippets…")
        case "add_snippet", "update_snippet": String(localized: "Saving snippet…")
        case "remove_snippet": String(localized: "Removing snippet…")
        case "list_port_forwards": String(localized: "Listing port forwards…")
        case "add_port_forward", "start_port_forward", "stop_port_forward", "remove_port_forward":
            String(localized: "Updating port forward…")
        case "get_activity": String(localized: "Reading agent history…")
        case "log_activity": String(localized: "Recording activity…")
        case "load_skill": String(localized: "Loading operations skill…")
        default: String(localized: "Running \(name)…")
        }
    }
}

// MARK: - Load Ops Skill Tool

public final class LoadOpsSkillTool: AssistantTool, @unchecked Sendable {
    public let functionName = "load_skill"
    public let displayName = String(localized: "Load Ops Skill")
    public let activeStatusText = String(localized: "Loading operations skill…")
    public let systemImage = "wand.and.stars"
    public let group: AssistantToolGroup = .skills
    public let access: AssistantToolAccess = .readOnly
    public let argumentOrder = ["reason", "skill"]

    public let schema = LLMToolSchema(
        name: "load_skill",
        description: "Load the full instructions of an enabled server operations skill by its id or name.",
        inputSchema: [
            "type": "object",
            "properties": [
                "skill": ["type": "string", "description": "Skill id or name from <available_skills>"],
            ],
            "required": ["skill"],
        ]
    )

    private let lookupSkill: @MainActor (String) -> ServerOpsSkill?

    public init(lookupSkill: @escaping @MainActor (String) -> ServerOpsSkill? = { ServerOpsSkillStore.shared.skill(idOrName: $0) }) {
        self.lookupSkill = lookupSkill
    }

    public func execute(
        _ arguments: AssistantToolArguments,
        context _: AssistantToolContext
    ) async throws -> AssistantToolOutput {
        let query = arguments.decodedJSONValue()["skill"]?.string ?? ""
        let skill = await MainActor.run { lookupSkill(query) }
        if let skill {
            return AssistantToolOutput(text: "# \(skill.name)\n\n\(skill.instructions)", isError: false)
        }
        return AssistantToolOutput(text: "Skill not found: \(query)", isError: true)
    }
}

// MARK: - Ask-Mode Upgrade Guard Tool

public final class RequestAgentModeTool: AssistantTool, @unchecked Sendable {
    public let functionName = "request_agent_mode"
    public let displayName = String(localized: "Switch to Agent Mode")
    public let activeStatusText = String(localized: "Requesting Agent mode…")
    public let systemImage = "bolt.shield"
    public let group: AssistantToolGroup = .observation
    public let access: AssistantToolAccess = .readOnly
    public let argumentOrder = ["reason"]

    public let schema = LLMToolSchema(
        name: "request_agent_mode",
        description: "Ask the user for permission to switch from read-only Ask mode to Agent mode when running SSH commands or querying live server state is required.",
        inputSchema: [
            "type": "object",
            "properties": [
                "reason": ["type": "string", "description": "Short explanation of what needs to be checked or run on the server"],
            ],
            "required": ["reason"],
        ]
    )

    public init() {}

    public func execute(
        _ arguments: AssistantToolArguments,
        context _: AssistantToolContext
    ) async throws -> AssistantToolOutput {
        let reason = arguments.decodedJSONValue()["reason"]?.string ?? ""
        return AssistantToolOutput(text: reason, isError: false)
    }
}

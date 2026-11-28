//
//  TamioAssistantTests.swift
//  TamioAssistantTests
//
//  Covers the core FlowDown-inspired engine contracts:
//  - `AssistantToolReason` schema injection & clean stripping
//  - `AssistantToolArgumentOrder` wire JSON key order preservation
//  - `AssistantToolSet` frozen snapshot resolution, case fallback, and null cleanup
//  - `AssistantApprovalGate` decision flow & cancellation safety
//  - `ConversationContextBuilder` grouped parallel tool calls, orphan repair & pruning
//  - `AssistantTranscriptBuilder` ActivitySummary folding, TraceStep & ToolArgumentLabel
//  - Backward-compatible decoding of legacy Tamio JSON conversation records
//

import Foundation
import TamioAssistant
import TamioModule
import Testing

// MARK: - Test Double

private final class StubTool: AssistantTool, @unchecked Sendable {
    let functionName: String
    let displayName: String
    let activeStatusText: String
    let systemImage = "wrench"
    let group: AssistantToolGroup = .observation
    let access: AssistantToolAccess = .readOnly
    let schema: LLMToolSchema
    let argumentOrder: [String]

    init(name: String, properties: [String: JSONValue], required: [String] = [], order: [String] = []) {
        self.functionName = name
        self.displayName = name
        self.activeStatusText = "Running \(name)…"
        self.argumentOrder = order
        self.schema = LLMToolSchema(
            name: name,
            description: "Stub tool",
            inputSchema: [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]
        )
    }

    func execute(_ arguments: AssistantToolArguments, context _: AssistantToolContext) async throws -> AssistantToolOutput {
        AssistantToolOutput(text: arguments.json)
    }
}

// MARK: - ToolReason & ToolSet Tests

@Test func toolReason_injectsRequiredReasonAndStripsBeforeExecution() {
    let tool = StubTool(
        name: "run_command",
        properties: [
            "command": ["type": "string"],
            "sudo": ["type": "boolean"],
        ],
        required: ["command"],
        order: ["reason", "command", "sudo"]
    )
    let toolSet = AssistantToolSet(tools: [tool], injectReason: true)
    let offered = toolSet.schemas[0].inputSchemaJSONValue()

    #expect(offered["properties"]?["reason"] != nil)
    #expect(offered["required"]?.strings.contains("reason") == true)

    let wire = #"{"reason":"Check disk usage","command":"df -h","sudo":null}"#
    let resolved = toolSet.resolve(LLMToolCall(id: "c1", name: "RUN_COMMAND", argumentsJSON: wire))
    #expect(resolved != nil)
    #expect(resolved?.reason == "Check disk usage")

    let cleanArgs = resolved?.arguments.decodedJSONValue()
    #expect(cleanArgs?["reason"] == nil)
    #expect(cleanArgs?["sudo"] == nil)
    #expect(cleanArgs?["command"]?.string == "df -h")
    #expect(resolved?.argumentOrder == ["reason", "command", "sudo"])
}

@Test func toolReason_preservesNativeReasonParameter() {
    let tool = StubTool(
        name: "request_agent_mode",
        properties: ["reason": ["type": "string"]],
        required: ["reason"]
    )
    #expect(AssistantToolReason.adding(to: tool.schema) == nil)

    let toolSet = AssistantToolSet(tools: [tool], injectReason: true)
    let resolved = toolSet.resolve(LLMToolCall(id: "c2", name: "request_agent_mode", argumentsJSON: #"{"reason":"Need live CPU"}"#))
    #expect(resolved?.reason == "Need live CPU")
    // Native `reason` stays in the tool's own arguments.
    #expect(resolved?.arguments.decodedJSONValue()["reason"]?.string == "Need live CPU")
}

@Test func toolArgumentOrder_preservesWireOrderAfterSchemaOrder() {
    let raw = #"{"zeta":1,"alpha":"hello","nested":{"k":"v"},"beta":true}"#
    let order = AssistantToolArgumentOrder.order(schema: ["alpha"], arguments: raw)
    #expect(order == ["alpha", "zeta", "nested", "beta"])
}

// MARK: - ApprovalGate Tests

@Test @MainActor func approvalGate_resolvesDecisionAndClearsPending() async {
    let gate = AssistantApprovalGate()
    let req = AssistantApprovalRequest(
        conversationID: UUID(),
        client: "Tamio AI",
        toolName: "run_command",
        title: "Run on 1 server",
        reason: "Check disk space",
        detail: "df -h",
        hosts: ["prod-1"],
        risk: CommandRiskClassifier.classify(command: "df -h", sudo: false)
    )

    let task = Task { await gate.request(req) }
    await Task.yield()
    #expect(gate.pendingRequest?.id == req.id)

    gate.resolve(req.id, with: .approve)
    let decision = await task.value
    #expect(decision == .approve)
    #expect(gate.pendingRequest == nil)
}

@Test @MainActor func approvalGate_cancellationResolvesDeny() async {
    let gate = AssistantApprovalGate()
    let req = AssistantApprovalRequest(
        conversationID: UUID(),
        client: "Tamio AI",
        toolName: "run_command",
        title: "Delete temp files",
        detail: "rm -rf /tmp/x",
        hosts: ["prod-1"],
        risk: CommandRiskClassifier.classify(command: "rm -rf /tmp/x", sudo: false)
    )

    let task = Task { await gate.request(req) }
    await Task.yield()
    #expect(gate.hasPendingRequest)

    task.cancel()
    let decision = await task.value
    #expect(decision == .deny)
}

// MARK: - MessageNormalizer & Context Builder Tests

@Test func contextBuilder_groupsParallelToolCallsAndRepairsOrphans() {
    let groupID = UUID()
    let messages: [AssistantChatMessage] = [
        AssistantChatMessage(role: .user, text: "Check servers"),
        AssistantChatMessage(
            role: .assistant,
            text: ".",
            reasoning: "Let me check hosts and metrics together.",
            thinkingDuration: 3.2,
            isPlaceholderText: true,
            turnGroupID: groupID
        ),
        AssistantChatMessage(
            role: .toolCall,
            text: "List Servers",
            turnGroupID: groupID,
            toolExecution: AssistantToolExecution(
                callID: "call_1",
                toolName: "list_hosts",
                argumentsJSON: "{}",
                reason: "List servers",
                output: #"[{"name":"prod-1"}]"#,
                status: .succeeded,
                turnGroupID: groupID
            )
        ),
        AssistantChatMessage(
            role: .toolCall,
            text: "Live Metrics",
            turnGroupID: groupID,
            toolExecution: AssistantToolExecution(
                callID: "call_2",
                toolName: "get_metrics",
                argumentsJSON: "{}",
                reason: "Read CPU/MEM",
                output: #"{"prod-1":{"cpuPercent":12}}"#,
                status: .succeeded,
                turnGroupID: groupID
            )
        ),
        AssistantChatMessage(role: .assistant, text: "prod-1 is healthy (CPU 12%)."),
    ]

    let prepared = ConversationContextBuilder.build(
        messages: messages,
        baseSystemPrompt: "System",
        tools: [],
        tokenBudget: 64_000
    )

    // Expect: user -> ONE assistant(2 toolCalls) -> toolResult(call_1) -> toolResult(call_2) -> assistant(final)
    #expect(prepared.turns.count == 5)
    if case .assistant(let prose, let reasoning, let calls) = prepared.turns[1] {
        #expect(prose.isEmpty)
        #expect(reasoning == "Let me check hosts and metrics together.")
        #expect(calls.map(\.id) == ["call_1", "call_2"])
    } else {
        Issue.record("Expected grouped assistant tool_calls turn at index 1")
    }

    // Verify normalizer repairs missing tool_result with "."
    let broken: [LLMConversationTurn] = [
        .user(text: "Hi"),
        .assistant(text: "", toolCalls: [LLMToolCall(id: "orphan", name: "list_hosts", argumentsJSON: "{}")]),
        .user(text: "Continue"),
    ]
    let repaired = ConversationContextBuilder.normalizeTurns(broken)
    #expect(repaired.count == 4)
    if case .toolResult(let id, _, let content) = repaired[2] {
        #expect(id == "orphan")
        #expect(content == ".")
    } else {
        Issue.record("Expected repaired placeholder toolResult")
    }
}

// MARK: - ActivitySummary & Legacy JSON Migration Tests

@Test func transcriptBuilder_foldsConsecutiveThoughtsAndToolsIntoOneActivitySummary() {
    let groupID = UUID()
    let msgs: [AssistantChatMessage] = [
        AssistantChatMessage(role: .user, text: "Audit disk"),
        AssistantChatMessage(
            role: .assistant,
            text: ".",
            reasoning: "First check metrics",
            thinkingDuration: 4.4,
            isPlaceholderText: true,
            turnGroupID: groupID
        ),
        AssistantChatMessage(
            role: .toolCall,
            text: "Live Metrics",
            turnGroupID: groupID,
            toolExecution: AssistantToolExecution(
                callID: "c1",
                toolName: "get_metrics",
                argumentsJSON: "{}",
                reason: "Inspect root disk usage",
                output: "ok",
                status: .succeeded,
                durationMs: 120,
                turnGroupID: groupID
            )
        ),
        AssistantChatMessage(role: .assistant, text: "All disks are below 50%."),
    ]

    let entries = AssistantTranscriptBuilder.buildEntries(
        messages: msgs,
        isStreaming: false,
        streamText: "",
        streamReasoning: "",
        streamThinkingDuration: 0,
        activeToolStatus: nil,
        showsInlineSteps: false
    )

    let summaries = entries.compactMap { entry -> AssistantActivitySummary? in
        if case .activity(let s) = entry { return s }
        return nil
    }
    #expect(summaries.count == 1)
    #expect(summaries[0].steps.count == 2)
    #expect(summaries[0].seconds == 4)
    #expect(summaries[0].toolCount == 1)
    #expect(summaries[0].title.contains("4"))
    #expect(summaries[0].title.contains("1"))
}

@Test func legacyConversationJSON_decodesCleanlyWithDefaults() throws {
    let legacyMessageJSON = """
    [
      {
        "id": "11111111-1111-1111-1111-111111111111",
        "role": "toolCall",
        "text": "Run Command",
        "reasoning": "",
        "timestamp": "2026-10-01T12:00:00Z",
        "toolExecution": {
          "callID": "call_legacy",
          "toolName": "run_command",
          "argumentsJSON": "{\\"command\\":\\"uptime\\"}",
          "output": "up 10 days",
          "isError": false,
          "targetHosts": ["web-01"],
          "durationMs": 230
        }
      }
    ]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let msgs = try decoder.decode([AssistantChatMessage].self, from: Data(legacyMessageJSON.utf8))
    #expect(msgs.count == 1)
    #expect(msgs[0].thinkingDuration == 0)
    #expect(msgs[0].attachments.isEmpty)
    #expect(msgs[0].toolExecution?.status == .succeeded)
    #expect(msgs[0].toolExecution?.reason == nil)
}

@Test func toolArgumentLabel_formatsSnakeAndCamelCaseWithAcronyms() {
    #expect(ToolArgumentLabel.words(of: "end_date") == "End date")
    #expect(ToolArgumentLabel.words(of: "repoURL") == "Repo URL")
    #expect(ToolArgumentLabel.text(for: "proxy_command") == String(localized: "ProxyCommand"))
}

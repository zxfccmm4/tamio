//
//  ConversationSession.swift
//  TamioAssistant
//
//  FlowDown-inspired single-conversation runtime session:
//  - Owns the conversation's messages (single source of truth), live streaming
//    buffers paced via `BalancedEmitter`, live thinking duration, and its own
//    `AssistantApprovalGate`.
//  - Freezes an `AssistantToolSet` snapshot per turn so mid-turn UI edits never
//    break tool resolution; injects & strips `ModelToolReason` transparently.
//  - Appends a `.running` tool row BEFORE execution and settles it in place
//    (succeeded / failed / denied / cancelled) so ActivitySummary & Trace Sheet
//    update in real time.
//  - Supports Send (with Attachments), Redo-in-Composer, Edit & Resend, Retry,
//    Regenerate, Continue, Rewrite (in-place streaming with rollback on failure),
//    Delete / Delete w/ After, Compress, and Post-Actions (Auto-Title + Summary).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Observation
import TamioModule

// MARK: - On-Device FoundationModels Tools (macOS 26+ / iOS 26+)

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
private struct ListHostsOnDeviceTool: Tool {
    let name = "list_hosts"
    let description = "List saved SSH servers (name, address, port, group, tags). Never returns passwords or private keys."

    @Generable
    struct Arguments {
        @Guide(description: "Optional group filter; leave empty for all servers.")
        var group: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var args: [String: JSONValue] = [:]
        if let group = arguments.group, !group.isEmpty { args["group"] = .string(group) }
        let reply = await AgentServer.shared.invokeTool("list_hosts", arguments: .object(args), client: "Tamio AI (On-Device)")
        return String(reply.text.prefix(4000))
    }
}

@available(macOS 26.0, iOS 26.0, *)
private struct GetMetricsOnDeviceTool: Tool {
    let name = "get_metrics"
    let description = "Fetch live CPU, memory, disk, load, and network metrics for saved servers."

    @Generable
    struct Arguments {
        @Guide(description: "Comma-separated server names, or empty for all servers.")
        var hostsCSV: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var args: [String: JSONValue] = [:]
        if let csv = arguments.hostsCSV, !csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let names = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !names.isEmpty { args["hosts"] = .array(names.map { .string($0) }) }
        }
        let reply = await AgentServer.shared.invokeTool("get_metrics", arguments: .object(args), client: "Tamio AI (On-Device)")
        return String(reply.text.prefix(4000))
    }
}

@available(macOS 26.0, iOS 26.0, *)
private struct RunCommandOnDeviceTool: Tool {
    let name = "run_command"
    let description = "Run a shell command in parallel on one or more servers after the user approves."

    @Generable
    struct Arguments {
        @Guide(description: "Shell command to run.")
        var command: String
        @Guide(description: "Comma-separated server names, or 'all' for every server.")
        var targets: String
        @Guide(description: "Short task title for server history, e.g. 'Check disk space'.")
        var task: String
    }

    func call(arguments: Arguments) async throws -> String {
        let trimmedTargets = arguments.targets.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSpec: JSONValue
        if trimmedTargets.lowercased() == "all" || trimmedTargets.isEmpty {
            targetSpec = ["all": .bool(true)]
        } else {
            let names = trimmedTargets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            targetSpec = ["hosts": .array(names.map { .string($0) })]
        }
        let payload: JSONValue = [
            "targets": targetSpec,
            "command": .string(arguments.command),
            "task": .string(arguments.task),
        ]
        let reply = await AgentServer.shared.invokeTool("run_command", arguments: payload, client: "Tamio AI (On-Device)")
        return String(reply.text.prefix(4000))
    }
}

@available(macOS 26.0, iOS 26.0, *)
@MainActor
private final class OnDeviceServerSessionHolder {
    var session: LanguageModelSession

    init(instructions: String) {
        self.session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: [
                ListHostsOnDeviceTool(),
                GetMetricsOnDeviceTool(),
                RunCommandOnDeviceTool(),
            ],
            instructions: instructions
        )
    }
}

#if compiler(>=6.4)
@available(macOS 27.0, iOS 27.0, *)
@MainActor
private final class PrivateCloudComputeSessionHolder {
    var session: LanguageModelSession

    init(instructions: String) {
        self.session = LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            tools: [
                ListHostsOnDeviceTool(),
                GetMetricsOnDeviceTool(),
                RunCommandOnDeviceTool(),
            ],
            instructions: instructions
        )
    }
}
#endif
#endif

// MARK: - Single Conversation Runtime Session

@MainActor
@Observable
public final class ConversationSession {
    public let conversationID: UUID
    public let approvalGate = AssistantApprovalGate()

    public private(set) var messages: [AssistantChatMessage]
    public private(set) var streamText = ""
    public private(set) var streamReasoning = ""
    public private(set) var streamThinkingDuration: TimeInterval = 0
    public private(set) var isStreaming = false
    public private(set) var activeToolStatus: String?
    public private(set) var didPruneContext = false
    public private(set) var canContinueAfterToolLimit = false
    /// Set when the model in read-only Ask mode requests switching to Agent mode.
    public private(set) var pendingAgentModeReason: String?
    /// Non-nil while an in-place `AssistantRewriteAction` is streaming into a message.
    public private(set) var rewritingMessageID: UUID?

    /// Stable message ID for the live streaming assistant prose row.
    public let liveStreamMessageID = UUID()

    public static let maxRemoteToolRounds = 48
    private static let clientName = "Tamio AI"

    private weak var manager: ServerAssistant?
    private let remoteClient: RemoteLLMClient
    private var activeTask: Task<Void, Never>?
    private var thinkingStartInstant: ContinuousClock.Instant?
    private var onDeviceSessionBox: AnyObject?
    private var onDeviceExchangeCount = 0

    public init(
        conversationID: UUID,
        messages: [AssistantChatMessage],
        manager: ServerAssistant,
        remoteClient: RemoteLLMClient = RemoteLLMClient()
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.manager = manager
        self.remoteClient = remoteClient
    }

    // MARK: - Transcript View Model Projection

    public func transcriptEntries(showsInlineSteps: Bool) -> [AssistantTranscriptEntry] {
        AssistantTranscriptBuilder.buildEntries(
            messages: messages,
            isStreaming: isStreaming,
            streamText: streamText,
            streamReasoning: streamReasoning,
            streamThinkingDuration: streamThinkingDuration,
            activeToolStatus: activeToolStatus,
            showsInlineSteps: showsInlineSteps,
            streamingMessageID: liveStreamMessageID
        )
    }

    // MARK: - Message Mutations

    public func send(_ rawText: String, attachments: [AssistantAttachment] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !isStreaming else { return }
        pendingAgentModeReason = nil
        appendMessage(AssistantChatMessage(role: .user, text: text, attachments: attachments))
        applyImmediateFallbackTitleIfNeeded(from: text.isEmpty ? (attachments.first?.name ?? "") : text)
        startInference()
    }

    public func switchToAgentModeAndRetry() {
        guard !isStreaming else { return }
        pendingAgentModeReason = nil
        manager?.setInteractionMode(.agent, for: conversationID)
        regenerateLastReply()
    }

    public func dismissAgentModePrompt() {
        pendingAgentModeReason = nil
    }

    public func regenerateLastReply() {
        guard !isStreaming else { return }
        while let last = messages.last, last.role != .user {
            messages.removeLast()
        }
        guard messages.last?.role == .user else { return }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    /// FlowDown `Retry` from any user or assistant message: removes everything after
    /// the nearest user prompt at or before `messageID` and re-runs inference.
    public func retry(from messageID: UUID) {
        guard !isStreaming,
              let targetIdx = messages.firstIndex(where: { $0.id == messageID }),
              let userIdx = messages[...targetIdx].lastIndex(where: { $0.role == .user })
        else { return }
        if userIdx + 1 < messages.count {
            messages.removeSubrange((userIdx + 1)...)
        }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    /// Resumes after a network or stream error without discarding completed tool calls.
    public func retryAfterError() {
        guard !isStreaming else { return }
        while let last = messages.last, last.role == .error {
            messages.removeLast()
        }
        guard !messages.isEmpty else { return }
        canContinueAfterToolLimit = false
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    public func continueExecution() {
        guard !isStreaming else { return }
        canContinueAfterToolLimit = false
        while let last = messages.last, last.role == .notice {
            messages.removeLast()
        }
        guard !messages.isEmpty else { return }
        persistMessages()
        startInference()
    }

    public func editAndResend(messageID: UUID, newText: String, newAttachments: [AssistantAttachment]? = nil) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming,
              let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user })
        else { return }
        messages[index].text = trimmed
        if let newAttachments {
            messages[index].attachments = newAttachments
        }
        messages[index].timestamp = Date()
        if index + 1 < messages.count {
            messages.removeSubrange((index + 1)...)
        }
        onDeviceSessionBox = nil
        persistMessages()
        startInference()
    }

    /// FlowDown `Redo (Edit)`: extracts the user message's text + attachments to
    /// refill the composer, and removes that message and everything after it.
    @discardableResult
    public func popForComposerEdit(messageID: UUID) -> (text: String, attachments: [AssistantAttachment])? {
        guard !isStreaming,
              let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user })
        else { return nil }
        let extracted = (messages[index].text, messages[index].attachments)
        messages.removeSubrange(index...)
        onDeviceSessionBox = nil
        persistMessages()
        return extracted
    }

    public func deleteMessage(_ id: UUID) {
        guard !isStreaming else { return }
        messages.removeAll { $0.id == id }
        onDeviceSessionBox = nil
        persistMessages()
    }

    /// FlowDown `Delete w/ After`: deletes `id` and every subsequent message.
    public func deleteMessageAndAfter(_ id: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages.removeSubrange(index...)
        onDeviceSessionBox = nil
        persistMessages()
    }

    /// FlowDown `RewriteAction`: streams a rewritten version into the message in place,
    /// restoring the original content automatically if the stream fails or cancels.
    public func rewriteMessage(_ id: UUID, action: AssistantRewriteAction) {
        guard !isStreaming,
              let manager,
              let index = messages.firstIndex(where: { $0.id == id }),
              case .custom(let providerId) = manager.effectiveSelection(for: conversationID),
              let config = manager.resolvedProviderConfig(for: conversationID, providerId: providerId)
        else { return }

        let originalText = messages[index].text
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let apiKey = manager.providerStore.apiKey(for: config.id)

        isStreaming = true
        rewritingMessageID = id
        manager.markExecuting(conversationID, running: true)

        activeTask = Task { [weak self] in
            guard let self else { return }
            var rewritten = ""
            do {
                let turn = try await self.remoteClient.streamCompletion(
                    config: config,
                    apiKey: apiKey,
                    systemPrompt: action.prompt,
                    messages: [.user(text: originalText)],
                    tools: [],
                    onReasoningDelta: nil,
                    onTextDelta: { @MainActor [weak self] delta in
                        guard let self, let idx = self.messages.firstIndex(where: { $0.id == id }) else { return }
                        rewritten += delta
                        self.messages[idx].text = rewritten
                    }
                )
                let final = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[idx].text = final.isEmpty ? originalText : final
                }
                self.persistMessages()
            } catch {
                if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[idx].text = originalText
                }
                self.persistMessages()
            }
            self.rewritingMessageID = nil
            self.finishStreamingState()
        }
    }

    public func stopGenerating() {
        activeTask?.cancel()
        activeTask = nil
        approvalGate.denyPending()

        // Settle any in-flight tool rows as cancelled so they never stay "running" forever.
        for idx in messages.indices {
            if messages[idx].role == .toolCall, messages[idx].toolExecution?.isRunning == true {
                messages[idx].toolExecution?.status = .cancelled
                messages[idx].toolExecution?.isError = true
                if messages[idx].toolExecution?.output.isEmpty == true {
                    messages[idx].toolExecution?.output = String(localized: "Cancelled by user.")
                }
            }
        }

        let partial = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialReasoning = streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = finalizeThinkingDuration()

        if !partial.isEmpty {
            appendMessage(
                AssistantChatMessage(
                    role: .assistant,
                    text: partial,
                    reasoning: partialReasoning,
                    thinkingDuration: duration,
                    modelLabel: manager?.activeModelLabel(for: conversationID)
                )
            )
            appendMessage(AssistantChatMessage(role: .notice, text: String(localized: "Generation stopped.")))
        } else if !partialReasoning.isEmpty {
            // FlowDown `finalizeInterruptedReasoning`: preserve reasoning with an internal
            // placeholder so ActivitySummary displays the thought cleanly without an ugly bubble.
            appendMessage(
                AssistantChatMessage(
                    role: .assistant,
                    text: ".",
                    reasoning: partialReasoning,
                    thinkingDuration: duration,
                    isPlaceholderText: true,
                    modelLabel: manager?.activeModelLabel(for: conversationID)
                )
            )
            appendMessage(AssistantChatMessage(role: .notice, text: String(localized: "Generation stopped.")))
        } else {
            persistMessages()
        }
        rewritingMessageID = nil
        finishStreamingState()
    }

    public func resetOnDeviceContext() {
        onDeviceSessionBox = nil
        onDeviceExchangeCount = 0
    }

    public func runCompressionStream(
        sourceTitle: String,
        sourceTranscript: String,
        config: AIProviderConfig,
        apiKey: String?
    ) {
        appendMessage(
            AssistantChatMessage(
                role: .notice,
                text: String(localized: "Compressed from \"\(sourceTitle)\"")
            )
        )
        isStreaming = true
        streamText = ""
        streamReasoning = ""
        streamThinkingDuration = 0
        thinkingStartInstant = nil
        manager?.markExecuting(conversationID, running: true)

        let systemPrompt = """
        You are an expert infrastructure & DevOps summarization assistant.
        Compress the previous SSH server operations conversation into a crisp, structured Markdown brief:
        1. Preserve every server name, IP/group, confirmed finding, root cause, and command outcome.
        2. List completed changes and open follow-up items clearly as bullet points.
        3. Drop redundant raw logs and chatter while keeping exact file paths, error codes, and config values.
        4. Reply in the same language as the original conversation. Do not wrap the whole reply in a markdown code fence.
        """

        let cid = conversationID
        activeTask = Task { [weak self] in
            await AssistantTaskContext.$conversationID.withValue(cid) {
                guard let self else { return }
                do {
                    let clipped = sourceTranscript.count > 48_000
                        ? String(sourceTranscript.suffix(48_000))
                        : sourceTranscript
                    let turn = try await self.streamWithBalancedEmitter(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: systemPrompt,
                        messages: [.user(text: "Please summarize and compress this server operations conversation so we can continue seamlessly:\n\n\(clipped)")],
                        tools: []
                    )
                    let finalText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalReasoning = turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalText.isEmpty {
                        self.appendMessage(
                            AssistantChatMessage(
                                role: .assistant,
                                text: finalText,
                                reasoning: finalReasoning,
                                thinkingDuration: self.finalizeThinkingDuration(),
                                modelLabel: config.model
                            )
                        )
                    }
                } catch is CancellationError {
                    // Handled by stopGenerating()
                } catch {
                    self.appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
                }
                self.finishStreamingState()
            }
        }
    }

    // MARK: - Inference Pipeline

    private func startInference() {
        guard let manager else { return }
        let selection = manager.effectiveSelection(for: conversationID)
        let cid = conversationID
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await AssistantTaskContext.$conversationID.withValue(cid) {
                guard let self else { return }
                switch selection {
                case .appleIntelligence:
                    await self.runAppleIntelligenceTurn()
                case .applePrivateCloudCompute:
                    await self.runPrivateCloudComputeTurn()
                case .custom(let providerId):
                    guard let config = manager.resolvedProviderConfig(for: cid, providerId: providerId) else {
                        self.appendMessage(
                            AssistantChatMessage(
                                role: .error,
                                text: String(localized: "Selected AI provider was not found. Choose one in AI Providers.")
                            )
                        )
                        return
                    }
                    await self.runRemoteProviderLoop(config: config)
                }
            }
        }
    }

    private func runRemoteProviderLoop(config: AIProviderConfig) async {
        guard let manager else { return }
        isStreaming = true
        streamText = ""
        streamReasoning = ""
        streamThinkingDuration = 0
        thinkingStartInstant = nil
        activeToolStatus = nil
        canContinueAfterToolLimit = false
        manager.markExecuting(conversationID, running: true)

        let apiKey = manager.providerStore.apiKey(for: config.id)
        // FlowDown `ModelToolSet`: freeze offered tools at the start of the turn.
        let toolSet = manager.makeToolSet(for: conversationID)
        let budget = manager.contextTokenBudget

        do {
            for round in 0 ..< Self.maxRemoteToolRounds {
                try Task.checkCancellation()
                streamText = ""
                streamReasoning = ""
                streamThinkingDuration = 0
                thinkingStartInstant = nil

                let baseSystem = manager.buildInstructions(for: conversationID, compactForOnDevice: false)
                let prepared = ConversationContextBuilder.build(
                    messages: messages,
                    baseSystemPrompt: baseSystem,
                    tools: toolSet.schemas,
                    tokenBudget: budget
                )
                didPruneContext = prepared.didPrune

                let turn = try await streamCompletionWithRetry(
                    config: config,
                    apiKey: apiKey,
                    systemPrompt: prepared.systemPrompt,
                    messages: prepared.turns,
                    tools: toolSet.schemas
                )

                let replyText = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let replyReasoning = turn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                let thinkingDuration = finalizeThinkingDuration()

                if turn.toolCalls.isEmpty {
                    if !replyText.isEmpty || !replyReasoning.isEmpty {
                        appendMessage(
                            AssistantChatMessage(
                                role: .assistant,
                                text: replyText.isEmpty ? "." : replyText,
                                reasoning: replyReasoning,
                                thinkingDuration: thinkingDuration,
                                isPlaceholderText: replyText.isEmpty,
                                modelLabel: config.model
                            )
                        )
                    }
                    break
                }

                // Group intermediate assistant thought/text with the parallel tool calls it emitted.
                let turnGroupID = UUID()
                if !replyText.isEmpty || !replyReasoning.isEmpty {
                    appendMessage(
                        AssistantChatMessage(
                            role: .assistant,
                            text: replyText.isEmpty ? "." : replyText,
                            reasoning: replyReasoning,
                            thinkingDuration: thinkingDuration,
                            isPlaceholderText: replyText.isEmpty,
                            turnGroupID: turnGroupID,
                            modelLabel: config.model
                        )
                    )
                }
                streamText = ""
                streamReasoning = ""
                streamThinkingDuration = 0

                var requestedAgentUpgrade = false
                for call in turn.toolCalls {
                    try Task.checkCancellation()
                    if call.name.lowercased() == "request_agent_mode" {
                        let resolved = toolSet.resolve(call)
                        let args = (resolved?.arguments ?? AssistantToolArguments(json: call.argumentsJSON)).decodedJSONValue()
                        pendingAgentModeReason = args["reason"]?.string
                            ?? resolved?.reason
                            ?? String(localized: "This request needs to inspect live server state or run commands.")
                        requestedAgentUpgrade = true
                        break
                    }
                    await executeToolCall(call, using: toolSet, turnGroupID: turnGroupID)
                }
                activeToolStatus = nil
                if requestedAgentUpgrade { break }

                if round == Self.maxRemoteToolRounds - 1 {
                    streamText = ""
                    streamReasoning = ""
                    streamThinkingDuration = 0
                    thinkingStartInstant = nil
                    let wrapBase = manager.buildInstructions(for: conversationID, compactForOnDevice: false)
                    let wrapPrepared = ConversationContextBuilder.build(
                        messages: messages,
                        baseSystemPrompt: wrapBase,
                        tools: [],
                        tokenBudget: budget
                    )
                    if let summaryTurn = try? await streamCompletionWithRetry(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: wrapPrepared.systemPrompt,
                        messages: wrapPrepared.turns,
                        tools: []
                    ) {
                        let summaryText = summaryTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let summaryReasoning = summaryTurn.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !summaryText.isEmpty || !summaryReasoning.isEmpty {
                            appendMessage(
                                AssistantChatMessage(
                                    role: .assistant,
                                    text: summaryText.isEmpty ? "." : summaryText,
                                    reasoning: summaryReasoning,
                                    thinkingDuration: finalizeThinkingDuration(),
                                    isPlaceholderText: summaryText.isEmpty,
                                    modelLabel: config.model
                                )
                            )
                        }
                    }
                    canContinueAfterToolLimit = true
                    appendMessage(
                        AssistantChatMessage(
                            role: .notice,
                            text: String(localized: "Stopped after \(Self.maxRemoteToolRounds) tool rounds. Continue to keep going.")
                        )
                    )
                }
            }

            finishStreamingState()
            schedulePostActions(using: config, apiKey: apiKey)
        } catch is CancellationError {
            // Handled by stopGenerating()
        } catch {
            preservePartialStreamIfNeeded(modelLabel: config.model)
            appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
            finishStreamingState()
        }
    }

    // MARK: - Live Tool Execution (FlowDown Pattern)

    private func executeToolCall(
        _ call: LLMToolCall,
        using toolSet: AssistantToolSet,
        turnGroupID: UUID
    ) async {
        // 1. Unknown tool name becomes an error result the model can recover from.
        guard let resolved = toolSet.resolve(call) else {
            let execution = AssistantToolExecution(
                callID: call.id,
                toolName: call.name,
                argumentsJSON: call.argumentsJSON,
                rawArgumentsJSON: call.argumentsJSON,
                reason: AssistantToolReason.reason(in: call.argumentsJSON),
                output: "No tool named \(call.name) is available. Call one of the provided tools instead.",
                isError: true,
                status: .failed,
                targetHosts: [],
                durationMs: 0,
                turnGroupID: turnGroupID
            )
            appendMessage(AssistantChatMessage(
                role: .toolCall,
                text: call.name,
                turnGroupID: turnGroupID,
                toolExecution: execution
            ))
            return
        }

        let tool = resolved.tool
        let hosts = tool.targetHosts(from: resolved.arguments)
        let rowID = UUID()

        // 2. Append a `.running` row immediately so ActivitySummary shows shimmer + `reason` banner live.
        let runningExec = AssistantToolExecution(
            callID: call.id,
            toolName: tool.functionName,
            argumentsJSON: resolved.arguments.json,
            rawArgumentsJSON: resolved.rawArgumentsJSON,
            reason: resolved.reason,
            output: "",
            isError: false,
            status: .running,
            targetHosts: hosts,
            durationMs: 0,
            turnGroupID: turnGroupID
        )
        appendMessage(AssistantChatMessage(
            id: rowID,
            role: .toolCall,
            text: tool.displayName,
            turnGroupID: turnGroupID,
            toolExecution: runningExec
        ))
        activeToolStatus = resolved.reason ?? tool.activeStatusText

        let start = ContinuousClock.now
        let context = AssistantToolContext(
            conversationID: conversationID,
            clientName: Self.clientName,
            reason: resolved.reason,
            argumentOrder: resolved.argumentOrder,
            rawArgumentsJSON: resolved.rawArgumentsJSON
        )

        do {
            let output = try await tool.execute(resolved.arguments, context: context)
            let elapsed = elapsedMilliseconds(since: start)
            let wasDenied = output.isError && output.text.localizedCaseInsensitiveContains("declined by the user")
            let status: AssistantToolExecutionStatus = wasDenied ? .denied : (output.isError ? .failed : .succeeded)
            let finalText = wasDenied
                ? "The user denied this call. Do not retry it unless the user asks you to."
                : output.modelText
            settleToolRow(
                rowID: rowID,
                output: finalText,
                isError: output.isError,
                status: status,
                hosts: output.targetHosts.isEmpty ? hosts : output.targetHosts,
                durationMs: elapsed
            )
        } catch is CancellationError {
            settleToolRow(
                rowID: rowID,
                output: String(localized: "Cancelled by user."),
                isError: true,
                status: .cancelled,
                hosts: hosts,
                durationMs: elapsedMilliseconds(since: start)
            )
        } catch {
            settleToolRow(
                rowID: rowID,
                output: "Tool execution failed. Reason: \(error.localizedDescription)",
                isError: true,
                status: .failed,
                hosts: hosts,
                durationMs: elapsedMilliseconds(since: start)
            )
        }
    }

    private func settleToolRow(
        rowID: UUID,
        output: String,
        isError: Bool,
        status: AssistantToolExecutionStatus,
        hosts: [String],
        durationMs: Int
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == rowID }) else { return }
        messages[idx].toolExecution?.output = output
        messages[idx].toolExecution?.isError = isError
        messages[idx].toolExecution?.status = status
        messages[idx].toolExecution?.targetHosts = hosts
        messages[idx].toolExecution?.durationMs = durationMs
        persistMessages()
    }

    // MARK: - Streaming with Retry & BalancedEmitter

    private func streamCompletionWithRetry(
        config: AIProviderConfig,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema]
    ) async throws -> LLMResponseTurn {
        let maxRetries = 2
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let turn = try await streamWithBalancedEmitter(
                    config: config,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools
                )
                activeToolStatus = nil
                return turn
            } catch {
                let receivedAnyOutput = !streamText.isEmpty || !streamReasoning.isEmpty
                guard attempt < maxRetries,
                      !receivedAnyOutput,
                      RemoteLLMClient.isRetryableError(error)
                else {
                    throw error
                }
                attempt += 1
                activeToolStatus = String(localized: "Connection interrupted, retrying (\(attempt)/\(maxRetries))…")
                let delaySeconds: Double = attempt == 1 ? 1.5 : 3.5
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
    }

    private func streamWithBalancedEmitter(
        config: AIProviderConfig,
        apiKey: String?,
        systemPrompt: String,
        messages: [LLMConversationTurn],
        tools: [LLMToolSchema]
    ) async throws -> LLMResponseTurn {
        let textEmitter = BalancedEmitter(duration: 0.28, frequency: 30) { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                self.activeToolStatus = nil
                self.streamText += chunk
            }
        }

        do {
            let turn = try await remoteClient.streamCompletion(
                config: config,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools,
                onReasoningDelta: { @MainActor [weak self] delta in
                    guard let self else { return }
                    self.activeToolStatus = nil
                    if self.thinkingStartInstant == nil {
                        self.thinkingStartInstant = .now
                    }
                    self.streamReasoning += delta
                    self.updateThinkingDuration()
                },
                onTextDelta: { delta in
                    await MainActor.run { [weak self] in
                        self?.updateThinkingDuration()
                    }
                    await textEmitter.add(delta)
                }
            )
            await textEmitter.flushAndWait()
            return turn
        } catch {
            await textEmitter.cancel()
            throw error
        }
    }

    private func updateThinkingDuration() {
        guard let start = thinkingStartInstant else { return }
        let elapsed = start.duration(to: .now)
        streamThinkingDuration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func finalizeThinkingDuration() -> TimeInterval {
        updateThinkingDuration()
        let result = streamThinkingDuration
        thinkingStartInstant = nil
        return result
    }

    private func preservePartialStreamIfNeeded(modelLabel: String?) {
        let partialText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialReasoning = streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = finalizeThinkingDuration()
        guard !partialText.isEmpty || !partialReasoning.isEmpty else { return }
        appendMessage(
            AssistantChatMessage(
                role: .assistant,
                text: partialText.isEmpty ? "." : partialText,
                reasoning: partialReasoning,
                thinkingDuration: duration,
                isPlaceholderText: partialText.isEmpty,
                modelLabel: modelLabel
            )
        )
        streamText = ""
        streamReasoning = ""
        streamThinkingDuration = 0
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - On-Device Apple Intelligence (macOS 26+ / iOS 26+)

    private func runAppleIntelligenceTurn() async {
        guard let manager else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard AppleIntelligenceStatus.current == .available else {
                appendMessage(AssistantChatMessage(role: .error, text: AppleIntelligenceStatus.current.localizedDescription))
                return
            }
            guard let prompt = messages.last(where: { $0.role == .user })?.text else { return }

            isStreaming = true
            streamText = ""
            streamReasoning = ""
            manager.markExecuting(conversationID, running: true)

            if onDeviceExchangeCount >= 8 {
                onDeviceSessionBox = nil
                onDeviceExchangeCount = 0
                appendMessage(
                    AssistantChatMessage(
                        role: .notice,
                        text: String(localized: "On-device context refreshed with recent summary.")
                    )
                )
            }

            do {
                let holder: OnDeviceServerSessionHolder
                if let existing = onDeviceSessionBox as? OnDeviceServerSessionHolder {
                    holder = existing
                } else {
                    var instructions = manager.buildInstructions(for: conversationID, compactForOnDevice: true)
                    let prior = Array(messages.dropLast())
                    let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: prior)
                    if !digest.isEmpty {
                        instructions += "\n\n" + digest
                    }
                    holder = OnDeviceServerSessionHolder(instructions: instructions)
                    onDeviceSessionBox = holder
                }

                for try await snapshot in holder.session.streamResponse(to: prompt) {
                    try Task.checkCancellation()
                    streamText = snapshot.content
                }
                let finalText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                appendMessage(
                    AssistantChatMessage(
                        role: .assistant,
                        text: finalText.isEmpty ? String(localized: "(No response)") : finalText,
                        modelLabel: String(localized: "Apple Intelligence")
                    )
                )
                onDeviceExchangeCount += 1
            } catch is CancellationError {
                // Handled by stopGenerating()
            } catch {
                preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence"))
                appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
            }

            finishStreamingState()
            return
        }
        #endif
        appendMessage(AssistantChatMessage(role: .error, text: AppleIntelligenceStatus.current.localizedDescription))
    }

    // MARK: - Apple Intelligence Private Cloud Compute (macOS 27+ / iOS 27+)

    private func runPrivateCloudComputeTurn() async {
        guard let manager else { return }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27.0, iOS 27.0, *) {
            let status = ApplePrivateCloudComputeStatus.current
            guard status == .available else {
                appendMessage(AssistantChatMessage(role: .error, text: status.localizedDescription))
                return
            }
            guard let prompt = messages.last(where: { $0.role == .user })?.text else { return }

            isStreaming = true
            streamText = ""
            streamReasoning = ""
            manager.markExecuting(conversationID, running: true)

            do {
                let holder: PrivateCloudComputeSessionHolder
                if let existing = onDeviceSessionBox as? PrivateCloudComputeSessionHolder {
                    holder = existing
                } else {
                    var instructions = manager.buildInstructions(for: conversationID, compactForOnDevice: false)
                    let prior = Array(messages.dropLast())
                    let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: prior)
                    if !digest.isEmpty {
                        instructions += "\n\n" + digest
                    }
                    holder = PrivateCloudComputeSessionHolder(instructions: instructions)
                    onDeviceSessionBox = holder
                }

                for try await snapshot in holder.session.streamResponse(to: prompt) {
                    try Task.checkCancellation()
                    streamText = snapshot.content
                }
                let finalText = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                appendMessage(
                    AssistantChatMessage(
                        role: .assistant,
                        text: finalText.isEmpty ? String(localized: "(No response)") : finalText,
                        modelLabel: String(localized: "Apple Intelligence (PCC)")
                    )
                )
            } catch is CancellationError {
                // Handled by stopGenerating()
            } catch let pccError as PrivateCloudComputeLanguageModel.Error {
                preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence (PCC)"))
                let friendly: String
                switch pccError {
                case .networkFailure:
                    friendly = String(localized: "Unable to reach Apple Private Cloud Compute. Check your network connection and retry.")
                case .quotaLimitReached:
                    friendly = String(localized: "Apple Private Cloud Compute usage limit reached. Try again later or switch to On-Device / another provider.")
                case .serviceUnavailable:
                    friendly = String(localized: "Apple Private Cloud Compute is temporarily unavailable. Try again in a moment.")
                @unknown default:
                    friendly = pccError.localizedDescription
                }
                appendMessage(AssistantChatMessage(role: .error, text: friendly))
            } catch {
                preservePartialStreamIfNeeded(modelLabel: String(localized: "Apple Intelligence (PCC)"))
                appendMessage(AssistantChatMessage(role: .error, text: error.localizedDescription))
            }

            finishStreamingState()
            return
        }
        #endif
        appendMessage(AssistantChatMessage(role: .error, text: ApplePrivateCloudComputeStatus.current.localizedDescription))
    }

    // MARK: - Post-Actions (Auto-Rename + Cross-Session Summary)

    private func applyImmediateFallbackTitleIfNeeded(from userPrompt: String) {
        guard let manager,
              let conv = manager.conversation(id: conversationID),
              conv.shouldAutoRename,
              conv.title == String(localized: "New Conversation") || conv.title.isEmpty
        else { return }

        let cleaned = userPrompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? userPrompt
        guard !cleaned.isEmpty else { return }
        let title = cleaned.count > 28 ? String(cleaned.prefix(28)) + "…" : cleaned
        manager.updateMetadata(conversationID) { item in
            item.title = title
        }
    }

    private func schedulePostActions(using config: AIProviderConfig, apiKey: String?) {
        guard let manager, let conv = manager.conversation(id: conversationID) else { return }

        if conv.shouldAutoRename {
            let sample = messages
                .filter { ($0.role == .user || $0.role == .assistant) && !$0.trimmedText.isEmpty && !$0.isPlaceholderText }
                .prefix(4)
                .map { "\($0.role == .user ? "User" : "Assistant"): \(String($0.trimmedText.prefix(260)))" }
                .joined(separator: "\n")

            if !sample.isEmpty {
                let cid = conversationID
                Task.detached(priority: .utility) { [remoteClient] in
                    let sys = """
                    Generate a very short title (3–12 words or 4–14 Chinese characters) and one relevant emoji for this server operations chat.
                    Match the user's language. Reply in exactly two lines with no quotes or markdown:
                    EMOJI: <single emoji>
                    TITLE: <short title>
                    """
                    guard let raw = try? await remoteClient.completeText(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: sys,
                        userPrompt: sample,
                        maxTokens: 64
                    ) else { return }

                    var parsedEmoji = ""
                    var parsedTitle = ""
                    for line in raw.components(separatedBy: .newlines) {
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.uppercased().hasPrefix("EMOJI:") {
                            parsedEmoji = String(t.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if t.uppercased().hasPrefix("TITLE:") {
                            parsedTitle = String(t.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    guard !parsedTitle.isEmpty else { return }
                    await MainActor.run {
                        ServerAssistant.shared.applyAutoTitle(
                            for: cid,
                            title: String(parsedTitle.prefix(40)),
                            emoji: parsedEmoji.first.map(String.init)
                        )
                    }
                }
            }
        }

        if manager.crossSessionMemoryEnabled {
            let userCount = messages.filter { $0.role == .user }.count
            let delta = messages.count - conv.summaryMessageCount
            if userCount >= 3, delta >= 2 {
                let digest = messages
                    .filter { ($0.role == .user || $0.role == .assistant) && !$0.trimmedText.isEmpty && !$0.isPlaceholderText }
                    .suffix(12)
                    .map { "\($0.role == .user ? "User" : "Assistant"): \(String($0.trimmedText.prefix(320)))" }
                    .joined(separator: "\n")
                let msgCount = messages.count
                let cid = conversationID

                Task.detached(priority: .utility) { [remoteClient] in
                    let sys = """
                    Summarize this SSH server operations conversation in 1–2 concise sentences (preserve key server names, findings, and changes). Plain text only.
                    """
                    guard let summary = try? await remoteClient.completeText(
                        config: config,
                        apiKey: apiKey,
                        systemPrompt: sys,
                        userPrompt: String(digest.prefix(3600)),
                        maxTokens: 160
                    ), !summary.isEmpty else { return }

                    await MainActor.run {
                        ServerAssistant.shared.saveSummary(summary, messageCount: msgCount, for: cid)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func appendMessage(_ message: AssistantChatMessage) {
        messages.append(message)
        persistMessages()
    }

    private func persistMessages() {
        manager?.persistMessages(messages, for: conversationID)
    }

    private func finishStreamingState() {
        activeToolStatus = nil
        streamText = ""
        streamReasoning = ""
        streamThinkingDuration = 0
        thinkingStartInstant = nil
        isStreaming = false
        activeTask = nil
        manager?.markExecuting(conversationID, running: false)
    }
}

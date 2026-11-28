//
//  MessageNormalizer.swift
//  TamioAssistant
//
//  FlowDown `ChatClientKit` message normalization + single-source-of-truth
//  request reconstruction and atomic token-budget pruning:
//  1. Groups parallel tool calls emitted in the same assistant turn into one
//     `.assistant(text:, reasoning:, toolCalls:)` turn followed by matching
//     `.toolResult` turns (fixing Anthropic & OpenAI strict role alternation).
//  2. Repairs any orphaned tool call missing a result with a safe placeholder.
//  3. Prunes oldest turns atomically when above tokenBudget without ever
//     separating a tool result from its preceding assistant tool call.
//  4. Exports clean Markdown transcripts including thinking & tool reasons.
//

import Foundation

public nonisolated enum ConversationContextBuilder {
    public struct PreparedContext: Sendable {
        public let systemPrompt: String
        public let turns: [LLMConversationTurn]
        public let didPrune: Bool
        public let estimatedTokens: Int
    }

    public static func build(
        messages: [AssistantChatMessage],
        baseSystemPrompt: String,
        tools: [LLMToolSchema],
        tokenBudget: Int
    ) -> PreparedContext {
        let recentCutoff = max(0, messages.count - 8)
        let rawTurns = buildGroupedTurns(from: messages, recentCutoff: recentCutoff)
        let normalizedTurns = normalizeTurns(rawTurns)

        let toolsTokens = tools.reduce(0) { acc, tool in
            acc + estimateTokens(tool.name) + estimateTokens(tool.description) + (tool.inputSchemaJSON.count / 4)
        }
        let systemTokens = estimateTokens(baseSystemPrompt)
        let effectiveBudget = max(4_000, tokenBudget)

        func totalTokens(for candidate: [LLMConversationTurn]) -> Int {
            systemTokens + toolsTokens + candidate.reduce(0) { $0 + estimateTurnTokens($1) }
        }

        let initialTotal = totalTokens(for: normalizedTurns)
        guard initialTotal > effectiveBudget, normalizedTurns.count > 1 else {
            return PreparedContext(
                systemPrompt: baseSystemPrompt,
                turns: normalizedTurns,
                didPrune: false,
                estimatedTokens: initialTotal
            )
        }

        // Phase 1: Evict earliest turns front-to-back, never evicting the latest turn.
        let upperBound = normalizedTurns.count - 1
        var evictEnd = 0
        var current = initialTotal

        while evictEnd < upperBound, current > effectiveBudget {
            current -= estimateTurnTokens(normalizedTurns[evictEnd])
            evictEnd += 1
        }

        // Atomic pairing: never leave an orphaned .toolResult after an evicted .assistant(toolCalls:).
        while evictEnd < upperBound {
            if case .toolResult = normalizedTurns[evictEnd] {
                current -= estimateTurnTokens(normalizedTurns[evictEnd])
                evictEnd += 1
            } else {
                break
            }
        }

        guard evictEnd > 0 else {
            return PreparedContext(
                systemPrompt: baseSystemPrompt,
                turns: normalizedTurns,
                didPrune: false,
                estimatedTokens: initialTotal
            )
        }

        // Phase 2: Compact extractive digest of evicted turns (capped at 10% of budget).
        let evicted = Array(normalizedTurns[..<evictEnd])
        let remaining = Array(normalizedTurns[evictEnd...])
        let summaryBudget = max(300, effectiveBudget / 10)
        var summaryLines: [String] = []
        var summaryTokens = 0

        for turn in evicted {
            let line: String
            switch turn {
            case .user(let text, _):
                line = "user: \(firstLine(text, limit: 140))"
            case .assistant(let text, _, let calls):
                if !text.isEmpty {
                    line = "assistant: \(firstLine(text, limit: 160))"
                } else if !calls.isEmpty {
                    line = "tool_calls: \(calls.map(\.name).joined(separator: ", "))"
                } else {
                    continue
                }
            case .toolResult(_, let name, let content):
                line = "tool(\(name)): \(firstLine(content, limit: 120))"
            }
            let cost = estimateTokens(line)
            guard summaryTokens + cost <= summaryBudget else { break }
            summaryLines.append(line)
            summaryTokens += cost
        }

        var updatedSystemPrompt = baseSystemPrompt
        if !summaryLines.isEmpty {
            let digest = """
            [Earlier conversation turns condensed due to context limit]
            \(summaryLines.joined(separator: "\n"))
            """
            if current + estimateTokens(digest) <= effectiveBudget {
                updatedSystemPrompt += "\n\n" + digest
                current += estimateTokens(digest)
            }
        }

        return PreparedContext(
            systemPrompt: updatedSystemPrompt,
            turns: remaining,
            didPrune: true,
            estimatedTokens: current
        )
    }

    /// Converts stored messages into wire turns while grouping parallel tool calls
    /// that share a `turnGroupID` (and any immediately preceding assistant prelude
    /// with the same `turnGroupID`) into a single `.assistant` turn + `.toolResult` sequence.
    static func buildGroupedTurns(from messages: [AssistantChatMessage], recentCutoff: Int) -> [LLMConversationTurn] {
        var turns: [LLMConversationTurn] = []
        var index = 0

        while index < messages.count {
            let msg = messages[index]
            switch msg.role {
            case .user:
                var textParts: [String] = []
                var images: [LLMImageAttachment] = []
                for attachment in msg.attachments {
                    switch attachment.kind {
                    case .terminalSnapshot, .textFile:
                        let block = attachment.formattedPromptBlock()
                        if !block.isEmpty { textParts.append(block) }
                    case .image:
                        if let data = attachment.imageData {
                            images.append(LLMImageAttachment(data: data, mimeType: attachment.mimeType ?? "image/png"))
                        }
                    }
                }
                let trimmed = msg.trimmedText
                if !trimmed.isEmpty {
                    textParts.insert(trimmed, at: 0)
                }
                let combinedText = textParts.joined(separator: "\n\n")
                if !combinedText.isEmpty || !images.isEmpty {
                    turns.append(.user(text: combinedText, images: images))
                }
                index += 1

            case .assistant:
                let prose = msg.isPlaceholderText ? "" : msg.trimmedText
                let reasoning = msg.trimmedReasoning

                // Check if following toolCall messages belong to this assistant's `turnGroupID`.
                if let groupID = msg.turnGroupID {
                    var groupedCalls: [LLMToolCall] = []
                    var groupedResults: [(id: String, name: String, content: String)] = []
                    var cursor = index + 1
                    while cursor < messages.count,
                          messages[cursor].role == .toolCall,
                          let exec = messages[cursor].toolExecution,
                          exec.turnGroupID == groupID
                    {
                        let argsJSON = exec.displayArgumentsJSON.isEmpty ? "{}" : exec.displayArgumentsJSON
                        groupedCalls.append(LLMToolCall(id: exec.callID, name: exec.toolName, argumentsJSON: argsJSON))
                        groupedResults.append((exec.callID, exec.toolName, formattedToolOutput(exec, isRecent: cursor >= recentCutoff)))
                        cursor += 1
                    }
                    if !groupedCalls.isEmpty {
                        turns.append(.assistant(text: prose, reasoning: reasoning, toolCalls: groupedCalls))
                        for res in groupedResults {
                            turns.append(.toolResult(toolCallId: res.id, name: res.name, content: res.content))
                        }
                        index = cursor
                        continue
                    }
                }

                if !prose.isEmpty {
                    turns.append(.assistant(text: prose, reasoning: reasoning, toolCalls: []))
                } else if !reasoning.isEmpty {
                    // Interrupted reasoning without prose still keeps non-empty assistant turn.
                    turns.append(.assistant(text: ".", reasoning: reasoning, toolCalls: []))
                }
                index += 1

            case .toolCall:
                guard let exec = msg.toolExecution else {
                    index += 1
                    continue
                }
                // Group consecutive toolCall messages sharing the same non-nil `turnGroupID`.
                if let groupID = exec.turnGroupID {
                    var groupedCalls: [LLMToolCall] = []
                    var groupedResults: [(id: String, name: String, content: String)] = []
                    var cursor = index
                    while cursor < messages.count,
                          messages[cursor].role == .toolCall,
                          let nextExec = messages[cursor].toolExecution,
                          nextExec.turnGroupID == groupID
                    {
                        let argsJSON = nextExec.displayArgumentsJSON.isEmpty ? "{}" : nextExec.displayArgumentsJSON
                        groupedCalls.append(LLMToolCall(id: nextExec.callID, name: nextExec.toolName, argumentsJSON: argsJSON))
                        groupedResults.append((nextExec.callID, nextExec.toolName, formattedToolOutput(nextExec, isRecent: cursor >= recentCutoff)))
                        cursor += 1
                    }
                    turns.append(.assistant(text: "", reasoning: "", toolCalls: groupedCalls))
                    for res in groupedResults {
                        turns.append(.toolResult(toolCallId: res.id, name: res.name, content: res.content))
                    }
                    index = cursor
                    continue
                }

                // Legacy single-call format (pre-refactor saved conversations).
                let call = LLMToolCall(
                    id: exec.callID,
                    name: exec.toolName,
                    argumentsJSON: exec.displayArgumentsJSON.isEmpty ? "{}" : exec.displayArgumentsJSON
                )
                turns.append(.assistant(text: "", reasoning: "", toolCalls: [call]))
                turns.append(.toolResult(
                    toolCallId: exec.callID,
                    name: exec.toolName,
                    content: formattedToolOutput(exec, isRecent: index >= recentCutoff)
                ))
                index += 1

            case .notice, .error:
                index += 1
            }
        }

        return turns
    }

    /// FlowDown ChatClientKit-style normalizer:
    /// - Ensures every `.assistant(toolCalls:)` is immediately followed by matching `.toolResult` entries
    ///   (fills missing results with `"."` so strict providers never reject after interruption).
    /// - Merges consecutive `.user` turns so Anthropic/Mistral strict alternation always passes.
    public static func normalizeTurns(_ turns: [LLMConversationTurn]) -> [LLMConversationTurn] {
        var result: [LLMConversationTurn] = []
        var i = 0

        while i < turns.count {
            let turn = turns[i]
            switch turn {
            case .user(let text, let images):
                if case .user(let prevText, let prevImages) = result.last {
                    let mergedText = [prevText, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    result[result.count - 1] = .user(text: mergedText, images: prevImages + images)
                } else {
                    result.append(turn)
                }
                i += 1

            case .assistant(_, _, let calls) where !calls.isEmpty:
                result.append(turn)
                i += 1
                // Collect immediately following toolResults keyed by callID.
                var supplied: [String: LLMConversationTurn] = [:]
                while i < turns.count, case .toolResult(let cid, _, _) = turns[i] {
                    supplied[cid] = turns[i]
                    i += 1
                }
                for call in calls {
                    if let existing = supplied[call.id] {
                        result.append(existing)
                    } else {
                        result.append(.toolResult(toolCallId: call.id, name: call.name, content: "."))
                    }
                }

            case .assistant:
                result.append(turn)
                i += 1

            case .toolResult:
                // Stray orphaned toolResult with no preceding assistant tool call — drop safely.
                i += 1
            }
        }

        return result
    }

    private static func formattedToolOutput(_ exec: AssistantToolExecution, isRecent: Bool) -> String {
        let cap = isRecent ? 16_000 : 2_000
        let raw = exec.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            switch exec.status {
            case .denied:
                return "The user denied this call. Do not retry it unless asked."
            case .cancelled:
                return "Cancelled by user."
            case .failed:
                return "Tool failed with no output."
            case .running, .succeeded:
                return "Tool completed with no output."
            }
        }
        if raw.count > cap {
            return String(raw.prefix(cap)) + "\n… [earlier tool output condensed]"
        }
        return raw
    }

    /// Compact conversation history digest for on-device Apple Intelligence (4096-token window).
    public static func buildOnDeviceHistoryDigest(from messages: [AssistantChatMessage], maxChars: Int = 1_800) -> String {
        let relevant = messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.trimmedText.isEmpty && !$0.isPlaceholderText }.suffix(8)
        guard !relevant.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for msg in relevant.reversed() {
            let prefix = msg.role == .user ? "User: " : "Assistant: "
            let text = msg.trimmedText
            let clipped = text.count > 360 ? String(text.prefix(360)) + "…" : text
            let entry = prefix + clipped.replacingOccurrences(of: "\n", with: " ")
            if used + entry.count > maxChars { break }
            lines.insert(entry, at: 0)
            used += entry.count
        }
        guard !lines.isEmpty else { return "" }
        return "Previous conversation context:\n" + lines.joined(separator: "\n")
    }

    /// CJK-aware lightweight token estimator (~1 token/CJK char, ~1 token/3.8 ASCII chars).
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        return cjkCount + max(1, (otherCount + 3) / 4)
    }

    private static func estimateTurnTokens(_ turn: LLMConversationTurn) -> Int {
        switch turn {
        case .user(let text, let images):
            return 6 + estimateTokens(text) + images.count * 768
        case .assistant(let text, _, let calls):
            let callsCost = calls.reduce(0) { $0 + 12 + estimateTokens($1.name) + estimateTokens($1.argumentsJSON) }
            return 6 + estimateTokens(text) + callsCost
        case .toolResult(_, let name, let content):
            return 10 + estimateTokens(name) + estimateTokens(content)
        }
    }

    private static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Exports a conversation cleanly as a shareable Markdown transcript.
    public static func exportMarkdown(conversation: AssistantConversation, messages: [AssistantChatMessage]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var out: [String] = [
            "# \(conversation.icon) \(conversation.title)",
            "",
            "- Created: \(formatter.string(from: conversation.createdAt))",
            "- Updated: \(formatter.string(from: conversation.updatedAt))",
            "",
            "---",
            "",
        ]

        for msg in messages {
            switch msg.role {
            case .user:
                var section = "## User\n\n\(msg.text)"
                if !msg.attachments.isEmpty {
                    let names = msg.attachments.map(\.name).joined(separator: ", ")
                    section += "\n\n*Attachments: \(names)*"
                }
                out.append(section + "\n")
            case .assistant:
                if !msg.trimmedReasoning.isEmpty {
                    out.append("<details><summary>Thinking</summary>\n\n\(msg.trimmedReasoning)\n\n</details>\n")
                }
                if !msg.trimmedText.isEmpty, !msg.isPlaceholderText {
                    out.append("## Assistant\n\n\(msg.trimmedText)\n")
                }
            case .toolCall:
                if let exec = msg.toolExecution {
                    let hosts = exec.targetHosts.isEmpty ? "" : " (\(exec.targetHosts.joined(separator: ", ")))"
                    let reason = exec.reason.map { " — \($0)" } ?? ""
                    out.append("> **Tool**: `\(exec.toolName)`\(hosts)\(reason) · \(exec.status.rawValue) (\(exec.durationMs) ms)\n")
                    let snippet = exec.output.count > 1200 ? String(exec.output.prefix(1200)) + "\n…" : exec.output
                    if !snippet.isEmpty {
                        out.append("```\n\(snippet)\n```\n")
                    }
                }
            case .notice:
                out.append("*\(msg.text)*\n")
            case .error:
                out.append("> **Error**: \(msg.text)\n")
            }
        }
        return out.joined(separator: "\n")
    }
}

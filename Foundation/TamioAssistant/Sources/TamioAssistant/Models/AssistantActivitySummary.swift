//
//  AssistantActivitySummary.swift
//  TamioAssistant
//
//  FlowDown-inspired transcript folding, ActivitySummary, TraceStep,
//  ToolCallDetail, and ToolArgumentLabel models.
//  Folds consecutive reasoning + tool calls between prose blocks into one
//  scannable ActivitySummary row that drills into a live-updating Trace sheet.
//

import Foundation

// MARK: - Transcript Entries

public nonisolated enum AssistantTranscriptEntry: Identifiable, Hashable, Sendable {
    case dateSeparator(id: String, title: String)
    case userMessage(AssistantChatMessage)
    case activity(AssistantActivitySummary)
    case assistantMessage(AssistantChatMessage, isStreaming: Bool)
    case notice(AssistantChatMessage)
    case error(AssistantChatMessage)
    case activityReporting(String)

    public var id: String {
        switch self {
        case .dateSeparator(let id, _): "date.\(id)"
        case .userMessage(let msg): "user.\(msg.id.uuidString)"
        case .activity(let summary): summary.id
        case .assistantMessage(let msg, _): "ai.\(msg.id.uuidString)"
        case .notice(let msg): "notice.\(msg.id.uuidString)"
        case .error(let msg): "error.\(msg.id.uuidString)"
        case .activityReporting: "activity-reporting"
        }
    }
}

// MARK: - Activity Summary

public nonisolated struct AssistantActivitySummary: Identifiable, Hashable, Sendable {
    public enum Step: Identifiable, Hashable, Sendable {
        case thought(id: String, text: String, duration: TimeInterval)
        case tool(id: String, title: String, execution: AssistantToolExecution)

        public var id: String {
            switch self {
            case .thought(let id, _, _): id
            case .tool(let id, _, _): id
            }
        }
    }

    public struct InlineStep: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case thought
            case call(status: AssistantToolExecutionStatus, durationMs: Int, hosts: [String])
        }

        public let id: String
        public let kind: Kind
        public let text: String

        public init(id: String, kind: Kind, text: String) {
            self.id = id
            self.kind = kind
            self.text = text
        }
    }

    public let id: String
    public var steps: [Step]
    public var thinkingDuration: TimeInterval
    public var isRunning: Bool
    public var showsSteps: Bool

    public init(
        id: String,
        steps: [Step] = [],
        thinkingDuration: TimeInterval = 0,
        isRunning: Bool = false,
        showsSteps: Bool = false
    ) {
        self.id = id
        self.steps = steps
        self.thinkingDuration = thinkingDuration
        self.isRunning = isRunning
        self.showsSteps = showsSteps
    }

    public var toolCount: Int {
        steps.reduce(0) { count, step in
            if case .tool = step { return count + 1 }
            return count
        }
    }

    public var runningToolCount: Int {
        steps.reduce(0) { count, step in
            if case .tool(_, _, let exec) = step, exec.isRunning { return count + 1 }
            return count
        }
    }

    public var failedToolCount: Int {
        steps.reduce(0) { count, step in
            if case .tool(_, _, let exec) = step,
               exec.status == .failed || exec.status == .denied
            {
                return count + 1
            }
            return count
        }
    }

    public var hasThoughts: Bool {
        steps.contains { if case .thought = $0 { true } else { false } }
    }

    /// Whole seconds spent thinking; at least 1 once there is any thought.
    public var seconds: Int {
        let rounded = Int(thinkingDuration.rounded())
        return hasThoughts ? max(1, rounded) : rounded
    }

    /// Latest tool call's reason (or localized title + hosts) shown in the subtle
    /// banner beneath a running summary. Stays visible after a quick call completes
    /// until new thought text or prose arrives, avoiding flicker (FlowDown pattern).
    public var banner: String? {
        guard isRunning, !showsSteps else { return nil }
        for step in steps.reversed() {
            switch step {
            case .thought(_, let text, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
            case .tool(_, let title, let exec):
                if let reason = exec.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    return Self.singleLine(reason)
                }
                if !exec.targetHosts.isEmpty {
                    return Self.singleLine("\(title) · \(exec.targetHosts.joined(separator: ", "))")
                }
                return Self.singleLine(title)
            }
        }
        return nil
    }

    public var inlineSteps: [InlineStep] {
        guard showsSteps else { return [] }
        return steps.map { step in
            switch step {
            case .thought(let id, let text, _):
                return InlineStep(id: id, kind: .thought, text: text)
            case .tool(let id, let title, let exec):
                let label: String
                if let reason = exec.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    label = Self.singleLine(reason)
                } else {
                    label = Self.singleLine(title)
                }
                return InlineStep(
                    id: id,
                    kind: .call(status: exec.status, durationMs: exec.durationMs, hosts: exec.targetHosts),
                    text: label
                )
            }
        }
    }

    public var title: String {
        if isRunning {
            let running = runningToolCount
            guard running > 0 else { return String(localized: "Thinking…") }
            return running == 1
                ? String(localized: "Executing tool…")
                : String(localized: "Executing \(running) tools…")
        }
        let sec = seconds
        let tools = toolCount
        if sec <= 0 {
            return tools == 1
                ? String(localized: "Called 1 tool")
                : String(localized: "Called \(tools) tools")
        }
        if tools <= 0 {
            return sec == 1
                ? String(localized: "Thought for 1 second")
                : String(localized: "Thought for \(sec) seconds")
        }
        if sec == 1 {
            return tools == 1
                ? String(localized: "Thought for 1 second and called 1 tool")
                : String(localized: "Thought for 1 second and called \(tools) tools")
        }
        return tools == 1
            ? String(localized: "Thought for \(sec) seconds and called 1 tool")
            : String(localized: "Thought for \(sec) seconds and called \(tools) tools")
    }

    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Transcript Entry Builder

public nonisolated enum AssistantTranscriptBuilder {
    /// Builds display entries from persisted messages plus live streaming state.
    public static func buildEntries(
        messages: [AssistantChatMessage],
        isStreaming: Bool,
        streamText: String,
        streamReasoning: String,
        streamThinkingDuration: TimeInterval,
        activeToolStatus: String?,
        showsInlineSteps: Bool,
        streamingMessageID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    ) -> [AssistantTranscriptEntry] {
        var entries: [AssistantTranscriptEntry] = []
        var latestDay: Date?

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"

        func addDateSeparatorIfNeeded(_ date: Date) {
            if let latestDay, Calendar.current.isDate(date, inSameDayAs: latestDay) {
                return
            }
            latestDay = date
            entries.append(.dateSeparator(
                id: dayKeyFormatter.string(from: date),
                title: dateFormatter.string(from: date)
            ))
        }

        var currentSummary: AssistantActivitySummary?

        func fold(step: AssistantActivitySummary.Step, at date: Date, anchorID: String, thinkingDuration: TimeInterval = 0) {
            if currentSummary == nil {
                addDateSeparatorIfNeeded(date)
                currentSummary = AssistantActivitySummary(
                    id: "activity.\(anchorID)",
                    steps: [],
                    thinkingDuration: 0,
                    isRunning: false,
                    showsSteps: showsInlineSteps
                )
            }
            currentSummary?.steps.append(step)
            currentSummary?.thinkingDuration += thinkingDuration
        }

        func flushSummary(running: Bool = false) {
            guard var finished = currentSummary else { return }
            finished.isRunning = running
            entries.append(.activity(finished))
            currentSummary = nil
        }

        for msg in messages {
            switch msg.role {
            case .user:
                guard msg.hasVisibleContent else { continue }
                flushSummary()
                addDateSeparatorIfNeeded(msg.timestamp)
                entries.append(.userMessage(msg))

            case .assistant:
                let reasoning = msg.trimmedReasoning
                let prose = msg.isPlaceholderText ? "" : msg.trimmedText
                if !reasoning.isEmpty {
                    fold(
                        step: .thought(
                            id: "thought.\(msg.id.uuidString)",
                            text: reasoning,
                            duration: msg.thinkingDuration
                        ),
                        at: msg.timestamp,
                        anchorID: msg.id.uuidString,
                        thinkingDuration: msg.thinkingDuration
                    )
                }
                if !prose.isEmpty {
                    flushSummary()
                    addDateSeparatorIfNeeded(msg.timestamp)
                    entries.append(.assistantMessage(msg, isStreaming: false))
                }

            case .toolCall:
                guard let exec = msg.toolExecution else { continue }
                fold(
                    step: .tool(
                        id: "tool.\(msg.id.uuidString)",
                        title: msg.text.isEmpty ? exec.toolName : msg.text,
                        execution: exec
                    ),
                    at: msg.timestamp,
                    anchorID: msg.id.uuidString
                )

            case .notice:
                guard msg.hasVisibleContent else { continue }
                flushSummary()
                addDateSeparatorIfNeeded(msg.timestamp)
                entries.append(.notice(msg))

            case .error:
                guard msg.hasVisibleContent else { continue }
                flushSummary()
                addDateSeparatorIfNeeded(msg.timestamp)
                entries.append(.error(msg))
            }
        }

        // Fold live streaming reasoning / prose / activity reporting
        if isStreaming {
            let trimmedReasoning = streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedProse = streamText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedReasoning.isEmpty {
                fold(
                    step: .thought(
                        id: "thought.live",
                        text: trimmedReasoning,
                        duration: streamThinkingDuration
                    ),
                    at: Date(),
                    anchorID: "live",
                    thinkingDuration: streamThinkingDuration
                )
            }

            if !trimmedProse.isEmpty {
                // Once prose starts streaming, close the preceding activity summary as settled.
                flushSummary(running: false)
                addDateSeparatorIfNeeded(Date())
                let liveMessage = AssistantChatMessage(
                    id: streamingMessageID,
                    role: .assistant,
                    text: trimmedProse,
                    timestamp: Date()
                )
                entries.append(.assistantMessage(liveMessage, isStreaming: true))
            } else if currentSummary != nil {
                flushSummary(running: true)
            } else {
                let status = activeToolStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(.activityReporting((status?.isEmpty == false ? status! : String(localized: "Thinking…"))))
            }
        } else {
            flushSummary(running: false)
        }

        return entries
    }
}

// MARK: - Trace Models (FlowDown TraceStep + ToolCallDetail + ToolArgumentLabel)

public nonisolated struct ToolCallDetail: Equatable, Hashable, Sendable {
    public struct Section: Identifiable, Equatable, Hashable, Sendable {
        public var id: String { "\(name ?? ""):\(value.prefix(32))" }
        /// Argument label or "Result"; nil for raw non-object JSON.
        public let name: String?
        public let value: String
        public let isMonospaced: Bool

        public init(name: String?, value: String, isMonospaced: Bool = false) {
            self.name = name
            self.value = value
            self.isMonospaced = isMonospaced
        }
    }

    public let sections: [Section]

    public init(arguments: String, result: String, title: String) {
        var built: [Section]
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmedArgs.isEmpty
            ? [:]
            : (try? JSONSerialization.jsonObject(with: Data(trimmedArgs.utf8), options: [.fragmentsAllowed])) as? [String: Any]

        if let decoded {
            built = decoded
                .filter { name, value in !(name == "reason" && (value as? String) == title) }
                .map { name, value in
                    let formatted = Self.text(of: value)
                    let mono = ["command", "script", "code", "proxy_command", "public_key"].contains(name)
                    return Section(name: name, value: formatted, isMonospaced: mono)
                }
                .sorted(by: Self.precedes)
        } else {
            built = [Section(name: nil, value: trimmedArgs, isMonospaced: true)]
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedResult.isEmpty {
            built.append(Section(name: String(localized: "Result"), value: trimmedResult, isMonospaced: true))
        }
        sections = built
    }

    public var plainText: String {
        sections.map { section in
            section.name.map { "\($0)\n\(section.value)" } ?? section.value
        }.joined(separator: "\n\n")
    }

    public static func text(of value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? String(localized: "Yes") : String(localized: "No")
        }
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func precedes(_ lhs: Section, _ rhs: Section) -> Bool {
        func rank(_ s: Section) -> Int {
            if s.name == "reason" { return 0 }
            if s.name == "task" { return 1 }
            if s.name == "targets" || s.name == "host" || s.name == "hosts" { return 2 }
            if s.name == "command" || s.name == "snippet" { return 3 }
            return s.value.contains("\n") ? 5 : 4
        }
        let r = (rank(lhs), rank(rhs))
        return r.0 == r.1 ? (lhs.name ?? "") < (rhs.name ?? "") : r.0 < r.1
    }
}

public nonisolated struct AssistantTraceStep: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case thought(String)
        case tool(execution: AssistantToolExecution, detail: ToolCallDetail)
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: Kind
    public let hasDetail: Bool

    public static let excerptLength = 160

    public init(_ step: AssistantActivitySummary.Step) {
        id = step.id
        switch step {
        case .thought(_, let text, _):
            title = String(localized: "Thoughts")
            subtitle = Self.excerpt(text)
            kind = .thought(text)
            hasDetail = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .tool(_, let label, let exec):
            let detail = ToolCallDetail(
                arguments: exec.displayArgumentsJSON,
                result: exec.output,
                title: label
            )
            title = label
            let summaryLine = exec.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? exec.reason!
                : Self.callLine(detail)
            subtitle = Self.excerpt(summaryLine)
            kind = .tool(execution: exec, detail: detail)
            hasDetail = !detail.sections.isEmpty
        }
    }

    public static func excerpt(_ text: String) -> String {
        var line = ""
        var length = 0
        var spaced = false
        for character in text {
            guard !character.isWhitespace else {
                spaced = length > 0
                continue
            }
            let added = spaced ? 2 : 1
            guard length + added <= excerptLength else { return line + "…" }
            if spaced { line.append(" ") }
            line.append(character)
            length += added
            spaced = false
        }
        return line
    }

    private static func callLine(_ detail: ToolCallDetail) -> String {
        var values: [String: String] = [:]
        for section in detail.sections {
            if let name = section.name, values[name] == nil {
                values[name] = section.value
            }
        }
        let priority = ["reason", "task", "command", "snippet", "host", "hosts", "targets", "skill", String(localized: "Result")]
        let named = priority.lazy.compactMap { values[$0] }.first { !$0.allSatisfy(\.isWhitespace) }
        return named ?? detail.sections.first?.value ?? ""
    }
}

// MARK: - Human-Readable Tool Argument Labels (FlowDown ToolArgumentLabel)

public nonisolated enum ToolArgumentLabel {
    public struct Row: Identifiable, Equatable, Hashable, Sendable {
        public var id: String { "\(label ?? ""):\(value.prefix(32))" }
        public let label: String?
        public let value: String
        public let isMonospaced: Bool

        public init(label: String?, value: String, isMonospaced: Bool = false) {
            self.label = label
            self.value = value
            self.isMonospaced = isMonospaced
        }
    }

    public static func rows(of json: String, order: [String], title: String) -> [Row] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
            return [Row(label: nil, value: trimmed, isMonospaced: true)]
        }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return decoded
            .filter { key, value in !(key == "reason" && (value as? String) == title) }
            .sorted { first, second in
                switch (position[first.key], position[second.key]) {
                case let (a?, b?): a < b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): first.key < second.key
                }
            }
            .map { key, value in
                let formatted = ToolCallDetail.text(of: value)
                let mono = ["command", "code", "proxy_command", "address", "target_host"].contains(key)
                return Row(label: text(for: key), value: formatted, isMonospaced: mono)
            }
            .filter { !$0.value.isEmpty }
    }

    public static func text(for key: String) -> String {
        known(key) ?? words(of: key)
    }

    public static func known(_ key: String) -> String? {
        switch key {
        case "command": String(localized: "Command")
        case "targets": String(localized: "Targets")
        case "host": String(localized: "Server")
        case "hosts": String(localized: "Servers")
        case "task": String(localized: "Task")
        case "sudo": String(localized: "Run with sudo")
        case "timeout": String(localized: "Timeout (s)")
        case "concurrency": String(localized: "Concurrency")
        case "snippet": String(localized: "Snippet")
        case "job_id": String(localized: "Job ID")
        case "address": String(localized: "Address")
        case "port": String(localized: "Port")
        case "username": String(localized: "Username")
        case "group": String(localized: "Group")
        case "tags": String(localized: "Tags")
        case "proxy_command": String(localized: "ProxyCommand")
        case "bind_port": String(localized: "Bind Port")
        case "target_host": String(localized: "Target Host")
        case "target_port": String(localized: "Target Port")
        case "direction": String(localized: "Direction")
        case "skill": String(localized: "Ops Skill")
        case "reason": String(localized: "Reason")
        default: nil
        }
    }

    /// Converts snake_case, kebab-case, and camelCase keys to Title words while
    /// preserving acronyms like `SSH` or `URL`.
    public static func words(of key: String) -> String {
        let characters = Array(key)
        let isAllCaps = !characters.contains { $0.isLowercase }
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == "." || character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return key }

        let sentence = words.map { word in
            let isAcronym = !isAllCaps && word.count > 1 && !word.contains { $0.isLowercase }
            return isAcronym ? word : word.lowercased()
        }.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

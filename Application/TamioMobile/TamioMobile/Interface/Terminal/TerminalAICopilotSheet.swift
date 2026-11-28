//
//  TerminalAICopilotSheet.swift
//  TamioMobile
//
//  In-terminal AI Assistant drawer for SSH development & troubleshooting:
//  - Scopes AI context directly to the active SSH server
//  - Optionally attaches live terminal screen/transcript output for diagnosis
//  - Extracts runnable shell code blocks from AI replies so the user can
//    Insert (paste without Enter) or Run (inject + Enter) directly into the
//    active SSH terminal session.
//

import SwiftUI
import TamioDesign
import TamioModule
import TamioTerminal
import UIKit

struct TerminalAICopilotSheet: View {
    let machine: RDMachine?
    let terminalTitle: String
    let terminal: TamioTerminalView
    let onInject: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assistant = ServerAssistant.shared
    @State private var bridge = MobileAgentBridge.shared
    @State private var inputText = ""
    @State private var attachScreenContext = true
    @State private var injectedToast: String?

    private var session: ConversationSession { assistant.activeSession }
    private var visibleMessages: [AssistantChatMessage] {
        session.messages.filter(\.hasVisibleContent)
    }
    private var activeApprovals: [MobileAgentBridge.PendingApproval] {
        bridge.pendingApprovals(for: assistant.activeConversationID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !assistant.isReadyToChat {
                    ContentUnavailableView {
                        Label("Configure an AI Provider", systemImage: "sparkles")
                    } description: {
                        Text("Open the AI Assistant tab to configure Apple Intelligence or a remote AI provider.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    contextHeaderBar
                    Divider()

                    if visibleMessages.isEmpty && !session.isStreaming && activeApprovals.isEmpty {
                        emptyQuickActions
                    } else {
                        transcriptList
                    }

                    Divider()
                    composerBar
                }
            }
            .navigationTitle(String(localized: "SSH AI Copilot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        assistant.createNewConversation(
                            targetScope: machine.map { .hosts([$0.id]) } ?? .all
                        )
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Conversation")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let toast = injectedToast {
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear {
                bridge.inlineApprovalActive = true
                if let machine, machine.isNotPlaceholder() {
                    assistant.targetScope = .hosts([machine.id])
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var contextHeaderBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(terminalTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())

            Picker("Mode", selection: Binding(
                get: { assistant.interactionMode(for: assistant.activeConversationID) },
                set: { assistant.setInteractionMode($0, for: assistant.activeConversationID) }
            )) {
                Text(AssistantInteractionMode.ask.localizedTitle).tag(AssistantInteractionMode.ask)
                Text(AssistantInteractionMode.agent.localizedTitle).tag(AssistantInteractionMode.agent)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(maxWidth: 112)

            Spacer()

            Toggle(isOn: $attachScreenContext) {
                Label("Screen Context", systemImage: "text.viewfinder")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .tint(attachScreenContext ? .accentColor : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var emptyQuickActions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask AI to diagnose terminal output or generate SSH commands to inject directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                quickChip(
                    title: "Explain Current Screen & Errors",
                    icon: "stethoscope",
                    prompt: String(localized: "Analyze the current SSH terminal screen output, explain any errors or warnings, and give me the exact fix commands.")
                )
                quickChip(
                    title: "Inspect Running Services & Ports",
                    icon: "network",
                    prompt: String(localized: "Give me a concise shell command to inspect listening ports and failed systemd services on this server.")
                )
                quickChip(
                    title: "Check Disk & Memory Pressure",
                    icon: "internaldrive",
                    prompt: String(localized: "Help me inspect disk usage, large log directories, and top memory processes on this server.")
                )
            }
            .padding(16)
        }
    }

    private func quickChip(title: LocalizedStringKey, icon: String, prompt: String) -> some View {
        Button {
            sendPrompt(prompt)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleMessages) { msg in
                        copilotMessageRow(msg)
                            .id(msg.id)
                    }

                    if session.isStreaming {
                        let streamText = session.streamText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let streamReasoning = session.streamReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isThinkingPhase = streamText.isEmpty

                        VStack(alignment: .leading, spacing: 6) {
                            if let tool = session.activeToolStatus {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text(tool).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !streamReasoning.isEmpty {
                                ReasoningDisclosureBox(
                                    text: streamReasoning,
                                    defaultExpanded: isThinkingPhase,
                                    isThinking: isThinkingPhase
                                )
                            }
                            if streamText.isEmpty {
                                if session.activeToolStatus == nil && streamReasoning.isEmpty {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text(LocalizedStringKey(streamText))
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let reason = session.pendingAgentModeReason {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Switch to Agent mode?", systemImage: "bolt.shield.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Switch & Retry") { session.switchToAgentModeAndRetry() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                Button("Stay in Ask") { session.dismissAgentModePrompt() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    ForEach(activeApprovals) { approval in
                        let risk = approval.risk
                        let tint: Color = switch risk.level {
                        case .readOnly: .green
                        case .modify: .orange
                        case .destructive: .red
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Label(approval.request.title, systemImage: approval.isDestructive ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(tint)
                                Spacer(minLength: 4)
                                Text(risk.level.localizedLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(tint.opacity(0.14), in: Capsule())
                            }
                            if !risk.reasons.isEmpty {
                                Text(risk.reasons.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !approval.request.detail.isEmpty {
                                Text(approval.request.detail)
                                    .font(.caption2.monospaced())
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                            HStack(spacing: 8) {
                                Button("Approve", role: approval.isDestructive ? .destructive : nil) {
                                    bridge.resolve(approval.id, approved: true)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(approval.isDestructive ? .red : .accentColor)
                                .controlSize(.small)
                                Button("Deny", role: .destructive) { bridge.resolve(approval.id, approved: false) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    Color.clear.frame(height: 12).id("copilot-bottom")
                }
                .padding(14)
            }
            .onChange(of: session.messages.count) { _, _ in
                proxy.scrollTo("copilot-bottom", anchor: .bottom)
            }
            .onChange(of: session.streamText.count) { _, _ in
                if session.isStreaming { proxy.scrollTo("copilot-bottom", anchor: .bottom) }
            }
            .onChange(of: session.streamReasoning.count) { _, _ in
                if session.isStreaming { proxy.scrollTo("copilot-bottom", anchor: .bottom) }
            }
            .onChange(of: session.activeToolStatus) { _, _ in
                if session.isStreaming { proxy.scrollTo("copilot-bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func copilotMessageRow(_ msg: AssistantChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            let text = msg.trimmedText
            let reasoning = msg.trimmedReasoning
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !reasoning.isEmpty {
                        ReasoningDisclosureBox(text: reasoning, defaultExpanded: false)
                    }

                    Text(LocalizedStringKey(text))
                        .font(.subheadline)
                        .textSelection(.enabled)

                    let commands = ShellCommandExtractor.extract(from: text)
                    if !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(commands.enumerated()), id: \.offset) { _, cmd in
                                commandInjectionCard(cmd)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            } else if !reasoning.isEmpty {
                ReasoningDisclosureBox(text: reasoning, defaultExpanded: false)
            }
        case .toolCall:
            if let exec = msg.toolExecution {
                HStack(spacing: 6) {
                    Image(systemName: exec.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(exec.isError ? .red : .green)
                    Text(msg.text).font(.caption.weight(.medium))
                    Spacer()
                    Text("\(exec.durationMs) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        case .notice:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(msg.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func commandInjectionCard(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    onInject(command, false)
                    flashToast(String(localized: "Inserted into terminal"))
                } label: {
                    Label("Insert", systemImage: "text.insert")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    onInject(command, true)
                    flashToast(String(localized: "Executed in SSH terminal"))
                    dismiss()
                } label: {
                    Label("Run in SSH", systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Spacer()

                Button {
                    UIPasteboard.general.string = command
                    flashToast(String(localized: "Copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var composerBar: some View {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !session.isStreaming && !trimmed.isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask AI or generate SSH command…", text: $inputText, axis: .vertical)
                .lineLimit(1 ... 4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                if session.isStreaming {
                    session.stopGenerating()
                } else if canSend {
                    sendPrompt(trimmed)
                    inputText = ""
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(session.isStreaming ? Color.red : (canSend ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .frame(width: 34, height: 34)
                    if session.isStreaming {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.white)
                            .frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(!session.isStreaming && !canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sendPrompt(_ raw: String) {
        var finalPrompt = raw
        if attachScreenContext {
            let screen = (terminal.readViewportText() ?? terminal.readTranscript())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !screen.isEmpty {
                let rawTail = String(screen.suffix(2400))
                let redacted = SecretRedactor.redactIfEnabled(rawTail)
                if redacted.didRedact {
                    flashToast(String(localized: "Redacted \(redacted.redactionCount) secret(s) from terminal context"))
                }
                finalPrompt += "\n\n[Current SSH Terminal Output (\(terminalTitle))]\n```\n\(redacted.text)\n```"
            }
        }
        session.send(finalPrompt)
    }

    private func flashToast(_ message: String) {
        withAnimation(.snappy) { injectedToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.snappy) {
                if injectedToast == message { injectedToast = nil }
            }
        }
    }
}

enum ShellCommandExtractor {
    /// Extracts fenced shell/bash/sh/zsh code blocks (or single-line command blocks)
    /// from an AI markdown reply so they can be injected into the active SSH terminal.
    static func extract(from markdown: String) -> [String] {
        var results: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var inFence = false
        var fenceLang = ""
        var buffer: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let allowedLang = fenceLang.isEmpty
                        || ["sh", "bash", "zsh", "shell", "console", "fish"].contains(fenceLang)
                    if allowedLang, !body.isEmpty, body.count <= 2000 {
                        results.append(body)
                    }
                    inFence = false
                    fenceLang = ""
                    buffer = []
                } else {
                    inFence = true
                    fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    buffer = []
                }
            } else if inFence {
                buffer.append(line)
            }
        }
        return results
    }
}

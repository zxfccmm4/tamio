//
//  MacTerminalAIPanel.swift
//  Tamio (macOS)
//
//  Side panel beside a macOS SSH terminal for AI-assisted development:
//  - Automatically scopes AI context to the current SSH server
//  - Optional one-click attachment of live terminal screen output
//  - Extracts shell code blocks from AI replies with Insert / Run in SSH
//    buttons that inject directly into the active Ghostty SSH session.
//

import AppKit
import SwiftUI
import TamioDesign
import TamioModule
import TamioTerminal

struct MacTerminalAIPanel: View {
    static let width: CGFloat = 340

    @ObservedObject var context: TerminalManager.Context
    let close: () -> Void

    @State private var assistant = ServerAssistant.shared
    @State private var bridge = MobileAgentBridge.shared
    @State private var inputText = ""
    @State private var attachScreenContext = true

    private var session: ConversationSession { assistant.activeSession }
    private var activeApprovals: [MobileAgentBridge.PendingApproval] {
        bridge.pendingApprovals(for: assistant.activeConversationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("SSH AI Copilot")
                    .font(.rxBodyStrong)
                Spacer()
                Button {
                    let scope: AssistantTargetScope = (context.remoteType == .machine && context.machine.isNotPlaceholder())
                        ? .hosts([context.machine.id])
                        : .all
                    assistant.createNewConversation(targetScope: scope)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("New Conversation")

                Button(action: close) {
                    Label("Close", rx: "xmark")
                }
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .help("Close AI Panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Hairline()

            if !assistant.isReadyToChat {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Configure an AI Provider")
                        .font(.rxBodyStrong)
                    Text("Open Assistant in the sidebar to configure Apple Intelligence or a remote AI provider.")
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                        .multilineTextAlignment(.center)
                    Button("Open Assistant") {
                        AppRouter.shared.route = .assistant
                    }
                    .buttonStyle(.rxPrimary)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Context toggle row
                HStack(spacing: 6) {
                    Toggle("Attach terminal screen", isOn: $attachScreenContext)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                Hairline()

                if session.messages.isEmpty && !session.isStreaming {
                    VStack(alignment: .leading, spacing: 8) {
                        quickButton("Explain current screen & errors", "stethoscope",
                                    String(localized: "Analyze the current SSH terminal screen output, explain any errors or warnings, and give me the exact fix commands."))
                        quickButton("Check services & ports", "network",
                                    String(localized: "Give me a concise shell command to inspect listening ports and failed systemd services on this server."))
                        quickButton("Check disk & memory", "internaldrive",
                                    String(localized: "Help me inspect disk usage, large log directories, and top memory processes on this server."))
                        Spacer()
                    }
                    .padding(12)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(session.messages) { msg in
                                    messageView(msg)
                                        .id(msg.id)
                                }

                                if session.isStreaming {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if let tool = session.activeToolStatus {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.mini)
                                                Text(tool).font(.caption).foregroundStyle(.rxInkSecondary)
                                            }
                                        }
                                        if session.streamText.isEmpty {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.mini)
                                                Text("Thinking…").font(.caption).foregroundStyle(.rxInkSecondary)
                                            }
                                        } else {
                                            Text(LocalizedStringKey(session.streamText))
                                                .font(.caption)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.rxSurfaceSunken, in: RoundedRectangle(cornerRadius: 10))
                                }

                                ForEach(activeApprovals) { approval in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(approval.request.title, systemImage: "checkmark.shield.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                        if !approval.request.detail.isEmpty {
                                            Text(approval.request.detail)
                                                .font(.caption2.monospaced())
                                                .padding(6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                        }
                                        HStack(spacing: 6) {
                                            Button("Approve") { bridge.resolve(approval.id, approved: true) }
                                                .buttonStyle(.rxPrimary)
                                            Button("Deny", role: .destructive) { bridge.resolve(approval.id, approved: false) }
                                                .buttonStyle(.rx)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                }

                                Color.clear.frame(height: 8).id("mac-copilot-bottom")
                            }
                            .padding(10)
                        }
                        .onChange(of: session.messages.count) { _, _ in
                            proxy.scrollTo("mac-copilot-bottom", anchor: .bottom)
                        }
                        .onChange(of: session.streamText.count) { _, _ in
                            if session.isStreaming { proxy.scrollTo("mac-copilot-bottom", anchor: .bottom) }
                        }
                    }
                }

                Hairline()

                // Composer
                let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let canSend = !session.isStreaming && !trimmed.isEmpty
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Ask AI or generate command…", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .lineLimit(1 ... 4)
                        .onSubmit {
                            guard canSend else { return }
                            sendPrompt(trimmed)
                            inputText = ""
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.rxSurfaceSunken, in: RoundedRectangle(cornerRadius: 8))

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
                                .fill(session.isStreaming ? Color.red : (canSend ? Color.accentColor : Color.primary.opacity(0.08)))
                                .frame(width: 26, height: 26)
                            if session.isStreaming {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white)
                                    .frame(width: 8, height: 8)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.isStreaming && !canSend)
                }
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .fill(Color.rxSurface.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .strokeBorder(Color.rxHairline, lineWidth: 0.5)
        )
        .onAppear {
            bridge.install()
            bridge.inlineApprovalActive = true
            if context.remoteType == .machine, context.machine.isNotPlaceholder() {
                assistant.targetScope = .hosts([context.machine.id])
            }
        }
    }

    private func quickButton(_ title: LocalizedStringKey, _ icon: String, _ prompt: String) -> some View {
        Button {
            sendPrompt(prompt)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.rxInk)
                Spacer()
            }
            .padding(9)
            .background(Color.rxSurfaceSunken, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func messageView(_ msg: AssistantChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(msg.text)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(msg.text))
                    .font(.caption)
                    .textSelection(.enabled)

                let commands = MacShellCommandExtractor.extract(from: msg.text)
                if !commands.isEmpty {
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, cmd in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cmd)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                Button("Insert") {
                                    context.termInterface.sendInputText(cmd)
                                }
                                .buttonStyle(.rx)
                                Button("Run in SSH") {
                                    context.termInterface.sendInputText(cmd + "\n")
                                }
                                .buttonStyle(.rxPrimary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.rx)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rxSurfaceSunken, in: RoundedRectangle(cornerRadius: 10))
        case .toolCall:
            if let exec = msg.toolExecution {
                HStack(spacing: 5) {
                    Image(systemName: exec.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(exec.isError ? .red : .green)
                    Text(msg.text).font(.caption2.weight(.medium))
                    Spacer()
                    Text("\(exec.durationMs) ms").font(.caption2.monospacedDigit()).foregroundStyle(.rxInkTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
        case .notice:
            Text(msg.text)
                .font(.caption2)
                .foregroundStyle(.rxInkSecondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(msg.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sendPrompt(_ raw: String) {
        var finalPrompt = raw
        if attachScreenContext {
            let screen = (context.termInterface.readViewportText() ?? context.termInterface.readTranscript())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !screen.isEmpty {
                let tail = String(screen.suffix(2400))
                finalPrompt += "\n\n[Current SSH Terminal Output (\(context.displayName))]\n```\n\(tail)\n```"
            }
        }
        session.send(finalPrompt)
    }
}

private enum MacShellCommandExtractor {
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

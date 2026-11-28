//
//  MacTerminalAIPanel.swift
//  Tamio (macOS)
//
//  Side panel beside a macOS SSH terminal powered by `TamioAssistantUI`:
//  - Scopes AI context to the active SSH server
//  - Attaches redacted terminal screen snapshots as first-class attachments
//  - Uses `Lakr233/MarkdownView` with native Insert / Run in SSH / Save Snippet
//    buttons inside every shell code block header
//  - Morphs the composer in place into `ToolApprovalCardView` when commands wait
//    for approval
//

import AppKit
import SwiftUI
import TamioAssistant
import TamioAssistantUI
import TamioDesign
import TamioModule
import TamioTerminal

struct MacTerminalAIPanel: View {
    static let width: CGFloat = 360

    @ObservedObject var context: TerminalManager.Context
    let close: () -> Void

    @State private var assistant = ServerAssistant.shared
    @State private var bridge = AssistantAgentBridge.shared
    @State private var inputText = ""
    @State private var pendingAttachments: [AssistantAttachment] = []
    @State private var autoAttachScreenContext = true
    @State private var toastMessage: String?

    private var session: ConversationSession { assistant.activeSession }

    private var hasContent: Bool {
        session.messages.contains(where: \.hasVisibleContent)
            || session.isStreaming
            || session.approvalGate.hasPendingRequest
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
                // Terminal screen attachment toggle
                HStack(spacing: 6) {
                    Toggle("Auto-attach terminal screen", isOn: $autoAttachScreenContext)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                Hairline()

                if !hasContent {
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
                    AssistantTranscriptView(
                        assistant: assistant,
                        session: session,
                        compact: true,
                        maxReadingWidth: nil,
                        horizontalPadding: 12,
                        bottomPadding: 12,
                        codeActions: AssistantMarkdownCodeActions(
                            onInsertShellCommand: { cmd in
                                context.termInterface.sendInputText(cmd)
                                flashToast(String(localized: "Inserted into terminal"))
                            },
                            onRunShellCommand: { cmd in
                                context.termInterface.sendInputText(cmd + "\n")
                                flashToast(String(localized: "Executed in SSH terminal"))
                            },
                            onSaveSnippet: { code, language in
                                saveSnippet(code: code, language: language)
                            }
                        ),
                        onRefillComposer: { text, attachments in
                            inputText = text
                            pendingAttachments = attachments
                        }
                    )
                }

                UnifiedComposerView(
                    assistant: assistant,
                    session: session,
                    text: $inputText,
                    attachments: $pendingAttachments,
                    placeholder: String(localized: "Ask AI or generate command…"),
                    compact: true,
                    onAttachTerminalSnapshot: {
                        if let snap = captureTerminalSnapshot() {
                            pendingAttachments.append(snap)
                        } else {
                            flashToast(String(localized: "Terminal screen is empty"))
                        }
                    },
                    onSend: { text, attachments in
                        sendPrompt(text, explicitAttachments: attachments)
                    }
                )
                .padding(10)
            }
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
            sendPrompt(prompt, explicitAttachments: pendingAttachments)
            pendingAttachments = []
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

    private func captureTerminalSnapshot() -> AssistantAttachment? {
        let screen = (context.termInterface.readViewportText() ?? context.termInterface.readTranscript())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screen.isEmpty else { return nil }
        let tail = String(screen.suffix(3200))
        let redacted = SecretRedactor.redactIfEnabled(tail)
        let lineCount = redacted.text.components(separatedBy: .newlines).count
        let subtitle = redacted.didRedact
            ? String(localized: "\(lineCount) lines · redacted \(redacted.redactionCount)")
            : String(localized: "\(lineCount) lines")
        return AssistantAttachment(
            kind: .terminalSnapshot,
            name: context.displayName,
            textContent: redacted.text,
            subtitle: subtitle
        )
    }

    private func sendPrompt(_ raw: String, explicitAttachments: [AssistantAttachment]) {
        var attachments = explicitAttachments
        if autoAttachScreenContext,
           !attachments.contains(where: { $0.kind == .terminalSnapshot }),
           let snap = captureTerminalSnapshot()
        {
            attachments.append(snap)
        }
        session.send(raw, attachments: attachments)
    }

    private func saveSnippet(code: String, language: String?) {
        let firstLine = code.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "SSH Snippet"
        var snippet = RDSnippet()
        snippet.name = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(48))
        snippet.group = "AI Copilot"
        snippet.code = code
        if let language, !language.isEmpty {
            snippet.comment = "Saved from SSH AI Copilot (\(language))"
        }
        TamioStore.shared.snippetGroup.insert(snippet)
        flashToast(String(localized: "Saved to Snippets"))
    }

    private func flashToast(_ message: String) {
        withAnimation(.snappy) { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

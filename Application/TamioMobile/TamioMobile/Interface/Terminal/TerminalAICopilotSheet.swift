//
//  TerminalAICopilotSheet.swift
//  TamioMobile
//
//  In-terminal AI Assistant drawer powered by `TamioAssistantUI`:
//  - Scopes AI context directly to the active SSH server
//  - Attaches redacted terminal screen snapshots as first-class attachments
//  - Renders Markdown via `Lakr233/MarkdownView` with Insert / Run in SSH /
//    Save Snippet buttons directly in shell code block headers
//  - Morphs the composer in place into `ToolApprovalCardView` on approval
//

import SwiftUI
import TamioAssistant
import TamioAssistantUI
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
    @State private var bridge = AssistantAgentBridge.shared
    @State private var inputText = ""
    @State private var pendingAttachments: [AssistantAttachment] = []
    @State private var autoAttachScreenContext = true
    @State private var injectedToast: String?

    private var session: ConversationSession { assistant.activeSession }

    private var hasContent: Bool {
        session.messages.contains(where: \.hasVisibleContent)
            || session.isStreaming
            || session.approvalGate.hasPendingRequest
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

                    if !hasContent {
                        emptyQuickActions
                    } else {
                        AssistantTranscriptView(
                            assistant: assistant,
                            session: session,
                            compact: true,
                            maxReadingWidth: nil,
                            horizontalPadding: 14,
                            bottomPadding: 16,
                            codeActions: AssistantMarkdownCodeActions(
                                onInsertShellCommand: { cmd in
                                    onInject(cmd, false)
                                    HapticsPreference.impact()
                                    flashToast(String(localized: "Inserted into terminal"))
                                },
                                onRunShellCommand: { cmd in
                                    onInject(cmd, true)
                                    HapticsPreference.impact()
                                    flashToast(String(localized: "Executed in SSH terminal"))
                                    dismiss()
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
                        placeholder: String(localized: "Ask AI or generate SSH command…"),
                        compact: true,
                        onAttachTerminalSnapshot: {
                            if let snap = captureTerminalSnapshot() {
                                pendingAttachments.append(snap)
                            } else {
                                flashToast(String(localized: "Terminal screen is empty"))
                            }
                        },
                        onSend: { text, attachments in
                            HapticsPreference.impact()
                            sendPrompt(text, explicitAttachments: attachments)
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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

            Spacer()

            Toggle(isOn: $autoAttachScreenContext) {
                Label("Screen Context", systemImage: "text.viewfinder")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .tint(autoAttachScreenContext ? .accentColor : .secondary)
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
            sendPrompt(prompt, explicitAttachments: pendingAttachments)
            pendingAttachments = []
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

    private func captureTerminalSnapshot() -> AssistantAttachment? {
        let screen = (terminal.readViewportText() ?? terminal.readTranscript())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !screen.isEmpty else { return nil }
        let tail = String(screen.suffix(3200))
        let redacted = SecretRedactor.redactIfEnabled(tail)
        if redacted.didRedact {
            flashToast(String(localized: "Redacted \(redacted.redactionCount) secret(s) from terminal context"))
        }
        let lineCount = redacted.text.components(separatedBy: .newlines).count
        let subtitle = redacted.didRedact
            ? String(localized: "\(lineCount) lines · redacted \(redacted.redactionCount)")
            : String(localized: "\(lineCount) lines")
        return AssistantAttachment(
            kind: .terminalSnapshot,
            name: terminalTitle,
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
        HapticsPreference.impact()
        flashToast(String(localized: "Saved to Snippets"))
    }

    private func flashToast(_ message: String) {
        withAnimation(.snappy) { injectedToast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) {
                if injectedToast == message { injectedToast = nil }
            }
        }
    }
}

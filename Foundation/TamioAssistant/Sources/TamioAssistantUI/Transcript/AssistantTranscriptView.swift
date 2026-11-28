//
//  AssistantTranscriptView.swift
//  TamioAssistantUI
//
//  Unified FlowDown-style transcript list shared by macOS Main Assistant,
//  iOS Main Assistant, macOS Terminal Copilot, and iOS Terminal Copilot:
//  - Renders folded `ActivitySummaryRow`, document-first `AIMessageRow`,
//    soft-tinted `UserMessageRow`, compact `ErrorRowView`, and `NoticeRowView`.
//  - Tracks whether the user is pinned near the bottom so streaming auto-scrolls
//    smoothly without fighting manual scroll-up, surfacing a floating
//    "Jump to Latest" button whenever the user reads earlier messages.
//  - Hosts the live-updating `TraceSheetView` and `RawMessageSheetView`.
//

import SwiftUI
import TamioAssistant

public struct AssistantTranscriptView: View {
    public let assistant: ServerAssistant
    public let session: ConversationSession
    public let compact: Bool
    public let maxReadingWidth: CGFloat?
    public let horizontalPadding: CGFloat
    public let bottomPadding: CGFloat
    public let codeActions: AssistantMarkdownCodeActions
    public let onRefillComposer: ((String, [AssistantAttachment]) -> Void)?

    @State private var activeTraceSummaryID: String?
    @State private var rawMessageText: String?
    @State private var isPinnedToBottom = true

    public init(
        assistant: ServerAssistant,
        session: ConversationSession,
        compact: Bool = false,
        maxReadingWidth: CGFloat? = 780,
        horizontalPadding: CGFloat = 18,
        bottomPadding: CGFloat = 24,
        codeActions: AssistantMarkdownCodeActions = .none,
        onRefillComposer: ((String, [AssistantAttachment]) -> Void)? = nil
    ) {
        self.assistant = assistant
        self.session = session
        self.compact = compact
        self.maxReadingWidth = maxReadingWidth
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
        self.codeActions = codeActions
        self.onRefillComposer = onRefillComposer
    }

    private var canRewrite: Bool {
        if case .custom = assistant.effectiveSelection(for: session.conversationID) {
            return true
        }
        return false
    }

    public var body: some View {
        let entries = session.transcriptEntries(showsInlineSteps: assistant.inlineActivityStepsEnabled)
        let lastNoticeID: UUID? = session.messages.last(where: { $0.role == .notice })?.id

        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 10 : 14) {
                        if session.didPruneContext {
                            prunedContextBanner
                        }

                        ForEach(entries) { entry in
                            entryRow(entry, lastNoticeID: lastNoticeID)
                                .id(entry.id)
                        }

                        if let reason = session.pendingAgentModeReason {
                            agentModeUpgradeCard(reason: reason)
                                .id("agent-mode-prompt")
                        }

                        // Invisible bottom sentinel used for sticky-scroll tracking & scroll-to-bottom.
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom-sentinel")
                            .onAppear { isPinnedToBottom = true }
                            .onDisappear { isPinnedToBottom = false }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 10 : 14)
                    .padding(.bottom, bottomPadding)
                    .frame(maxWidth: maxReadingWidth ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onChange(of: session.conversationID) { _, _ in
                    isPinnedToBottom = true
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if isPinnedToBottom {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: session.isStreaming) { _, streaming in
                    if streaming && isPinnedToBottom {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: session.streamText.count) { _, _ in
                    if session.isStreaming && isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: session.streamReasoning.count) { _, _ in
                    if session.isStreaming && isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: session.activeToolStatus) { _, _ in
                    if session.isStreaming && isPinnedToBottom {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: session.pendingAgentModeReason) { _, reason in
                    if reason != nil && isPinnedToBottom {
                        scrollToBottom(proxy, animated: true)
                    }
                }

                if !isPinnedToBottom && !entries.isEmpty {
                    Button {
                        isPinnedToBottom = true
                        scrollToBottom(proxy, animated: true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                                .font(.caption2.weight(.bold))
                            if session.isStreaming {
                                Text(String(localized: "Streaming"))
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { activeTraceSummaryID != nil },
            set: { if !$0 { activeTraceSummaryID = nil } }
        )) {
            if let summaryID = activeTraceSummaryID {
                TraceSheetView(
                    session: session,
                    summaryID: summaryID,
                    showsInlineSteps: assistant.inlineActivityStepsEnabled
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { rawMessageText != nil },
            set: { if !$0 { rawMessageText = nil } }
        )) {
            if let raw = rawMessageText {
                RawMessageSheetView(text: raw)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AssistantTranscriptEntry, lastNoticeID: UUID?) -> some View {
        switch entry {
        case .dateSeparator(_, let title):
            HStack {
                Spacer()
                Text(title)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                Spacer()
            }

        case .userMessage(let msg):
            UserMessageRow(
                message: msg,
                compact: compact,
                canMutate: !session.isStreaming,
                onRedoEdit: {
                    if let popped = session.popForComposerEdit(messageID: msg.id) {
                        onRefillComposer?(popped.text, popped.attachments)
                    }
                },
                onRetry: { session.retry(from: msg.id) },
                onForkHere: {
                    _ = assistant.duplicateConversation(session.conversationID, upToMessageID: msg.id)
                },
                onDelete: { session.deleteMessage(msg.id) },
                onDeleteWithAfter: { session.deleteMessageAndAfter(msg.id) }
            )

        case .activity(let summary):
            ActivitySummaryRow(
                summary: summary,
                compact: compact
            ) {
                activeTraceSummaryID = summary.id
            }

        case .assistantMessage(let msg, let streaming):
            AIMessageRow(
                message: msg,
                isStreaming: streaming,
                isRewriting: session.rewritingMessageID == msg.id,
                compact: compact,
                canMutate: !session.isStreaming,
                canRewrite: canRewrite,
                codeActions: codeActions,
                onViewRaw: { rawMessageText = msg.trimmedText },
                onRegenerate: { session.retry(from: msg.id) },
                onRewrite: { action in session.rewriteMessage(msg.id, action: action) },
                onForkHere: {
                    _ = assistant.duplicateConversation(session.conversationID, upToMessageID: msg.id)
                },
                onDelete: { session.deleteMessage(msg.id) },
                onDeleteWithAfter: { session.deleteMessageAndAfter(msg.id) }
            )

        case .notice(let msg):
            NoticeRowView(
                text: msg.trimmedText,
                showContinue: !session.isStreaming && session.canContinueAfterToolLimit && msg.id == lastNoticeID,
                onContinue: { session.continueExecution() }
            )

        case .error(let msg):
            ErrorRowView(
                text: msg.trimmedText,
                canRetry: !session.isStreaming,
                onRetry: { session.retryAfterError() }
            )

        case .activityReporting(let status):
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                ShimmerThinkingText(
                    text: status,
                    isActive: true,
                    font: compact ? .caption.weight(.medium) : .subheadline.weight(.medium)
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var prunedContextBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(localized: "Earlier turns were condensed to fit the context window."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(String(localized: "Compress")) {
                assistant.compressConversation(session.conversationID)
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func agentModeUpgradeCard(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Switch to Agent mode?"), systemImage: "bolt.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(String(localized: "Switch & Retry")) {
                    session.switchToAgentModeAndRetry()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(String(localized: "Stay in Ask")) {
                    session.dismissAgentModePrompt()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            await Task.yield()
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("transcript-bottom-sentinel", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("transcript-bottom-sentinel", anchor: .bottom)
            }
        }
    }
}

//
//  UnifiedComposerView.swift
//  TamioAssistantUI
//
//  FlowDown `RichEditorView` + In-Place Tool Approval Morphing:
//  - Single continuous card container shared across macOS and iOS.
//  - Floats `ToolsChangeHint` 8pt above the card with zero layout shift when
//    offered tools change mid-conversation.
//  - Smoothly morphs in place into `ToolApprovalCardView` whenever
//    `session.approvalGate.pendingRequest` is present, and morphs back to
//    the editor + `QuickSettingBarView` the moment the user decides.
//  - Supports macOS drag-and-drop of text/log files and images.
//

import SwiftUI
import TamioAssistant
import TamioDesign
import UniformTypeIdentifiers

public struct UnifiedComposerView: View {
    public let assistant: ServerAssistant
    public let session: ConversationSession
    @Binding public var text: String
    @Binding public var attachments: [AssistantAttachment]

    public let placeholder: String
    public let compact: Bool
    public let scopeLabel: String?
    public let isScopeFiltered: Bool
    public let onTapScope: (() -> Void)?
    public let onTapSkills: (() -> Void)?
    public let onAttachFile: (() -> Void)?
    public let onAttachTerminalSnapshot: (() -> Void)?
    public let externalFocus: FocusState<Bool>.Binding?
    public let onDismissKeyboard: (() -> Void)?
    public let onSend: (String, [AssistantAttachment]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var internalFocus: Bool
    @State private var isDropTargeted = false

    public init(
        assistant: ServerAssistant,
        session: ConversationSession,
        text: Binding<String>,
        attachments: Binding<[AssistantAttachment]>,
        placeholder: String = String(localized: "Ask to check metrics, run batch commands, or manage servers…"),
        compact: Bool = false,
        scopeLabel: String? = nil,
        isScopeFiltered: Bool = false,
        onTapScope: (() -> Void)? = nil,
        onTapSkills: (() -> Void)? = nil,
        onAttachFile: (() -> Void)? = nil,
        onAttachTerminalSnapshot: (() -> Void)? = nil,
        externalFocus: FocusState<Bool>.Binding? = nil,
        onDismissKeyboard: (() -> Void)? = nil,
        onSend: @escaping (String, [AssistantAttachment]) -> Void
    ) {
        self.assistant = assistant
        self.session = session
        self._text = text
        self._attachments = attachments
        self.placeholder = placeholder
        self.compact = compact
        self.scopeLabel = scopeLabel
        self.isScopeFiltered = isScopeFiltered
        self.onTapScope = onTapScope
        self.onTapSkills = onTapSkills
        self.onAttachFile = onAttachFile
        self.onAttachTerminalSnapshot = onAttachTerminalSnapshot
        self.externalFocus = externalFocus
        self.onDismissKeyboard = onDismissKeyboard
        self.onSend = onSend
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !session.isStreaming && (!trimmedText.isEmpty || !attachments.isEmpty)
    }

    private var activeFocusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }

    private var isFocused: Bool {
        activeFocusBinding.wrappedValue
    }

    public var body: some View {
        let pendingApproval = session.approvalGate.pendingRequest

        ZStack(alignment: .top) {
            cardContainer {
                if let approval = pendingApproval {
                    ToolApprovalCardView(
                        request: approval,
                        compact: compact
                    ) { decision in
                        session.approvalGate.resolve(approval.id, with: decision)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    editorContent
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: pendingApproval?.id)
        }
        .overlay(alignment: .top) {
            if let hint = assistant.toolsChangeHintText, !hint.isEmpty, pendingApproval == nil {
                Text(hint)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: assistant.toolsChangeHintText)
        #if os(macOS)
        .onDrop(of: [.fileURL, .plainText, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        #endif
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            AttachmentsBarView(attachments: $attachments)

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(compact ? .subheadline : .body)
                .lineLimit(1 ... (compact ? 5 : 7))
                .focused(activeFocusBinding)
                .onSubmit {
                    submitIfReady()
                }
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.top, attachments.isEmpty ? (compact ? 10 : 12) : 4)

            QuickSettingBarView(
                assistant: assistant,
                conversationID: session.conversationID,
                isStreaming: session.isStreaming,
                canSend: canSend,
                compact: compact,
                scopeLabel: scopeLabel,
                isScopeFiltered: isScopeFiltered,
                onTapScope: onTapScope,
                onTapSkills: onTapSkills,
                onAttachFile: onAttachFile,
                onAttachTerminalSnapshot: onAttachTerminalSnapshot,
                showDismissKeyboard: showKeyboardDismissButton,
                onDismissKeyboard: {
                    activeFocusBinding.wrappedValue = false
                    onDismissKeyboard?()
                },
                onSend: submitIfReady,
                onStop: { session.stopGenerating() }
            )
        }
    }

    private var showKeyboardDismissButton: Bool {
        #if os(iOS)
        return isFocused
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let radius: CGFloat = compact ? 14 : 20
        let hasApproval = session.approvalGate.pendingRequest != nil
        let approvalBorderColor: Color = {
            guard let req = session.approvalGate.pendingRequest else {
                return isDropTargeted ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)
            }
            switch req.risk.level {
            case .readOnly: return Color.green.opacity(0.45)
            case .modify: return Color.orange.opacity(0.55)
            case .destructive: return Color.red.opacity(0.65)
            }
        }()

        #if os(iOS)
        if #available(iOS 26.0, *) {
            content()
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(approvalBorderColor, lineWidth: hasApproval ? 1.0 : 0.5)
                )
        } else {
            content()
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(approvalBorderColor, lineWidth: hasApproval ? 1.0 : 0.5)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 10, y: 3)
        }
        #else
        content()
            .background(
                Color.rxSurface,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(approvalBorderColor, lineWidth: (hasApproval || isDropTargeted) ? 1.2 : 0.75)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.05), radius: 10, y: 2)
        #endif
    }

    private func submitIfReady() {
        guard canSend else { return }
        let payloadText = trimmedText
        let payloadAttachments = attachments
        text = ""
        attachments = []
        onSend(payloadText, payloadAttachments)
    }

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    Task { @MainActor in
                        if let attachment = AssistantAttachmentLoader.load(from: url) {
                            attachments.append(attachment)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        let item = AssistantAttachment(
                            kind: .image,
                            name: "Image.png",
                            imageData: data,
                            mimeType: "image/png"
                        )
                        attachments.append(item)
                    }
                }
            }
        }
        return accepted
    }
    #endif
}

// MARK: - Attachment Loader Helper

public enum AssistantAttachmentLoader {
    public static let maxTextBytes = 128 * 1024
    public static let maxImageBytes = 8 * 1024 * 1024

    public static func load(from url: URL) -> AssistantAttachment? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
        if imageExts.contains(ext) {
            guard data.count <= maxImageBytes else { return nil }
            let mime: String = switch ext {
            case "jpg", "jpeg": "image/jpeg"
            case "webp": "image/webp"
            case "gif": "image/gif"
            default: "image/png"
            }
            return AssistantAttachment(
                kind: .image,
                name: url.lastPathComponent,
                imageData: data,
                mimeType: mime
            )
        }

        let sliced = data.prefix(maxTextBytes)
        guard let text = String(data: sliced, encoding: .utf8) ?? String(data: sliced, encoding: .isoLatin1) else {
            return nil
        }
        let suffix = data.count > maxTextBytes ? "\n… [truncated at 128 KB]" : ""
        return AssistantAttachment(
            kind: .textFile,
            name: url.lastPathComponent,
            textContent: text + suffix,
            mimeType: "text/plain"
        )
    }
}

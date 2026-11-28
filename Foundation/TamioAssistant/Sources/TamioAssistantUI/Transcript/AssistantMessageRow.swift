//
//  AssistantMessageRow.swift
//  TamioAssistantUI
//
//  FlowDown-inspired transcript message rows:
//  - User message: right-aligned soft accent-tinted bubble (`12pt` continuous
//    radius) with stacked attachment chips and Redo-in-Composer / Retry / Fork / Delete.
//  - AI message (Document-First): full reading width without heavy card boxes,
//    powered by `AssistantMarkdownView` (`MarkdownStreamView`), with Copy,
//    View Raw, Regenerate, Rewrite submenu, Fork Here, and Delete w/ After.
//  - Notice row: centered muted pill with optional Continue action.
//

import SwiftUI
import TamioAssistant
import TamioDesign

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Cross-Platform Pasteboard Helper

public enum AssistantPasteboard {
    public static func copy(_ text: String) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - User Message Row

public struct UserMessageRow: View {
    public let message: AssistantChatMessage
    public let compact: Bool
    public let canMutate: Bool
    public let onRedoEdit: () -> Void
    public let onRetry: () -> Void
    public let onForkHere: () -> Void
    public let onDelete: () -> Void
    public let onDeleteWithAfter: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var previewAttachment: AssistantAttachment?
    @Namespace private var zoomNamespace

    public init(
        message: AssistantChatMessage,
        compact: Bool = false,
        canMutate: Bool,
        onRedoEdit: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onForkHere: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDeleteWithAfter: @escaping () -> Void
    ) {
        self.message = message
        self.compact = compact
        self.canMutate = canMutate
        self.onRedoEdit = onRedoEdit
        self.onRetry = onRetry
        self.onForkHere = onForkHere
        self.onDelete = onDelete
        self.onDeleteWithAfter = onDeleteWithAfter
    }

    public var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: compact ? 20 : 48)

            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    attachmentStrip
                }

                if !message.trimmedText.isEmpty {
                    Text(message.trimmedText)
                        .font(compact ? .subheadline : .body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, compact ? 11 : 13)
                        .padding(.vertical, compact ? 8 : 10)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.14),
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.5)
                        )
                }

                #if os(macOS)
                if isHovered && canMutate {
                    HStack(spacing: 4) {
                        subtleActionButton(String(localized: "Copy"), systemImage: "doc.on.doc") {
                            AssistantPasteboard.copy(message.trimmedText)
                        }
                        subtleActionButton(String(localized: "Edit"), systemImage: "pencil") {
                            onRedoEdit()
                        }
                        subtleActionButton(String(localized: "Retry"), systemImage: "arrow.clockwise") {
                            onRetry()
                        }
                    }
                    .transition(.opacity)
                }
                #endif
            }
        }
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
        #endif
        .contextMenu {
            Button {
                AssistantPasteboard.copy(message.trimmedText)
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }

            if canMutate {
                Button(action: onRedoEdit) {
                    Label(String(localized: "Redo (Edit)"), systemImage: "pencil")
                }

                Button(action: onRetry) {
                    Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                }
            }

            Button(action: onForkHere) {
                Label(String(localized: "Fork Conversation Here"), systemImage: "arrow.triangle.branch")
            }

            if canMutate {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                Button(role: .destructive, action: onDeleteWithAfter) {
                    Label(String(localized: "Delete w/ After"), systemImage: "trash.slash")
                }
            }
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreviewSheet(attachment: attachment)
                .zoomTransitionDestination(sourceID: attachment.id, in: zoomNamespace)
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(message.attachments) { item in
                Button {
                    previewAttachment = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(item.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .zoomTransitionSource(id: item.id, in: zoomNamespace, cornerRadius: 8, appliesCardSurface: false)
            }
        }
    }

    private func subtleActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - AI Message Row (FlowDown Document-First Prose)

public struct AIMessageRow: View {
    public let message: AssistantChatMessage
    public let isStreaming: Bool
    public let isRewriting: Bool
    public let compact: Bool
    public let canMutate: Bool
    public let canRewrite: Bool
    public let codeActions: AssistantMarkdownCodeActions
    public let onViewRaw: () -> Void
    public let onRegenerate: () -> Void
    public let onRewrite: (AssistantRewriteAction) -> Void
    public let onForkHere: () -> Void
    public let onDelete: () -> Void
    public let onDeleteWithAfter: () -> Void

    @State private var isHovered = false
    @State private var copied = false

    public init(
        message: AssistantChatMessage,
        isStreaming: Bool,
        isRewriting: Bool = false,
        compact: Bool = false,
        canMutate: Bool,
        canRewrite: Bool,
        codeActions: AssistantMarkdownCodeActions = .none,
        onViewRaw: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onRewrite: @escaping (AssistantRewriteAction) -> Void,
        onForkHere: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDeleteWithAfter: @escaping () -> Void
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.isRewriting = isRewriting
        self.compact = compact
        self.canMutate = canMutate
        self.canRewrite = canRewrite
        self.codeActions = codeActions
        self.onViewRaw = onViewRaw
        self.onRegenerate = onRegenerate
        self.onRewrite = onRewrite
        self.onForkHere = onForkHere
        self.onDelete = onDelete
        self.onDeleteWithAfter = onDeleteWithAfter
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssistantMarkdownView(
                text: message.trimmedText,
                streamIdentity: message.id,
                isStreaming: isStreaming || isRewriting,
                compact: compact,
                codeActions: codeActions
            )

            if !isStreaming && !isRewriting {
                footerRow
            } else if isRewriting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(String(localized: "Rewriting…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
        #endif
        .contextMenu {
            Button {
                copyMarkdown()
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }

            Button(action: onViewRaw) {
                Label(String(localized: "View Raw"), systemImage: "doc.plaintext")
            }

            if canMutate {
                Button(action: onRegenerate) {
                    Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                }

                if canRewrite {
                    Menu {
                        ForEach(AssistantRewriteAction.allCases) { action in
                            Button {
                                onRewrite(action)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        Label(String(localized: "Rewrite"), systemImage: "wand.and.stars")
                    }
                }
            }

            Button(action: onForkHere) {
                Label(String(localized: "Fork Conversation Here"), systemImage: "arrow.triangle.branch")
            }

            if canMutate {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                Button(role: .destructive, action: onDeleteWithAfter) {
                    Label(String(localized: "Delete w/ After"), systemImage: "trash.slash")
                }
            }
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: 8) {
            if let model = message.modelLabel, !model.isEmpty {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if os(macOS)
            if isHovered {
                HStack(spacing: 4) {
                    actionIcon(copied ? "checkmark" : "doc.on.doc", help: String(localized: "Copy")) {
                        copyMarkdown()
                    }
                    if canMutate {
                        actionIcon("arrow.clockwise", help: String(localized: "Retry")) {
                            onRegenerate()
                        }
                        if canRewrite {
                            Menu {
                                ForEach(AssistantRewriteAction.allCases) { action in
                                    Button {
                                        onRewrite(action)
                                    } label: {
                                        Label(action.title, systemImage: action.systemImage)
                                    }
                                }
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 22)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(String(localized: "Rewrite"))
                        }
                    }
                    actionIcon("doc.plaintext", help: String(localized: "View Raw")) {
                        onViewRaw()
                    }
                }
                .transition(.opacity)
            }
            #endif

            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
    }

    private func actionIcon(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyMarkdown() {
        AssistantPasteboard.copy(message.trimmedText)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Notice Row

public struct NoticeRowView: View {
    public let text: String
    public let showContinue: Bool
    public let onContinue: () -> Void

    public init(text: String, showContinue: Bool, onContinue: @escaping () -> Void) {
        self.text = text
        self.showContinue = showContinue
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showContinue {
                Button(action: onContinue) {
                    Label(String(localized: "Continue"), systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - View Raw & Attachment Preview Sheets

public struct RawMessageSheetView: View {
    public let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(String(localized: "Raw Markdown"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        AssistantPasteboard.copy(text)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(
                            copied ? String(localized: "Copied") : String(localized: "Copy"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 580, minHeight: 380, idealHeight: 480)
        #endif
    }
}

public struct AttachmentPreviewSheet: View {
    public let attachment: AssistantAttachment
    @Environment(\.dismiss) private var dismiss

    public init(attachment: AssistantAttachment) {
        self.attachment = attachment
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if attachment.kind == .image, let data = attachment.imageData {
                        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                        if let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        #elseif canImport(UIKit)
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        #endif
                    } else if !attachment.textContent.isEmpty {
                        Text(attachment.textContent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .navigationTitle(attachment.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 340, idealHeight: 440)
        #endif
    }
}

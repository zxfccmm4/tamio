//
//  ConversationHistoryView.swift
//  TamioMobile
//
//  FlowDown-inspired conversation history manager:
//  - Grouped by Pinned / Today / Yesterday / Last 7 Days / Earlier
//  - Full-text search across conversation titles and message transcripts
//  - Live indicators for background-executing sessions and pending approvals
//  - Pin, Rename (title + emoji), Duplicate, Compress Context, Export Markdown,
//    and Delete / Clear All actions
//

import SwiftUI
import TamioModule

struct ConversationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var assistant: ServerAssistant

    @State private var bridge = MobileAgentBridge.shared
    @State private var searchText = ""
    @State private var matchedIDs: Set<UUID>?
    @State private var renamingConversation: AssistantConversation?
    @State private var showEraseAllConfirm = false

    private enum TimeBucket: Int, CaseIterable, Identifiable {
        case pinned, today, yesterday, lastSevenDays, earlier

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .pinned: String(localized: "Pinned")
            case .today: String(localized: "Today")
            case .yesterday: String(localized: "Yesterday")
            case .lastSevenDays: String(localized: "Previous 7 Days")
            case .earlier: String(localized: "Earlier")
            }
        }
    }

    private var visibleConversations: [AssistantConversation] {
        guard let matchedIDs, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return assistant.conversations
        }
        return assistant.conversations.filter { matchedIDs.contains($0.id) }
    }

    private var groupedSections: [(bucket: TimeBucket, items: [AssistantConversation])] {
        let cal = Calendar.current
        let now = Date()
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now

        var map: [TimeBucket: [AssistantConversation]] = [:]
        for conv in visibleConversations {
            let bucket: TimeBucket
            if conv.isPinned {
                bucket = .pinned
            } else if cal.isDateInToday(conv.updatedAt) {
                bucket = .today
            } else if cal.isDateInYesterday(conv.updatedAt) {
                bucket = .yesterday
            } else if conv.updatedAt >= sevenDaysAgo {
                bucket = .lastSevenDays
            } else {
                bucket = .earlier
            }
            map[bucket, default: []].append(conv)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let items = map[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groupedSections.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView {
                            Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Start a new conversation to audit or batch-manage your servers.")
                        } actions: {
                            Button("New Conversation") {
                                assistant.createNewConversation()
                                dismiss()
                            }
                            .appleProminentButton()
                        }
                    }
                } else {
                    List {
                        ForEach(groupedSections, id: \.bucket.id) { section in
                            Section(section.bucket.title) {
                                ForEach(section.items) { conv in
                                    conversationRow(conv)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search titles and messages"))
            .task(id: searchText) {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    matchedIDs = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                matchedIDs = await assistant.searchConversationIDs(query: query)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        assistant.createNewConversation()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Conversation")

                    Menu {
                        Button(role: .destructive) {
                            showEraseAllConfirm = true
                        } label: {
                            Label("Delete All Conversations", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .sheet(item: $renamingConversation) { conv in
                RenameConversationSheet(conversation: conv) { newTitle, newIcon in
                    assistant.renameConversation(conv.id, title: newTitle, icon: newIcon)
                }
            }
            .confirmationDialog(
                "Delete All Conversations?",
                isPresented: $showEraseAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    assistant.eraseAllConversations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all saved AI chat histories on this device.")
            }
        }
    }

    private func conversationRow(_ conv: AssistantConversation) -> some View {
        let isSelected = conv.id == assistant.activeConversationID
        let isRunning = assistant.executingConversationIDs.contains(conv.id)
        let needsApproval = bridge.hasPendingApproval(for: conv.id)

        return Button {
            assistant.selectConversation(conv.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Text(conv.icon.isEmpty ? "💬" : conv.icon)
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(conv.title)
                            .font(.subheadline.weight(isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if needsApproval {
                            Label("Approval", systemImage: "exclamationmark.circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text(conv.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    if !conv.lastMessagePreview.isEmpty {
                        Text(conv.lastMessagePreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Empty conversation")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if conv.targetScope.isFiltered || conv.messageCount > 0 {
                        HStack(spacing: 6) {
                            if case .group(let group) = conv.targetScope {
                                scopeTag(group, icon: "folder")
                            } else if case .hosts(let ids) = conv.targetScope, !ids.isEmpty {
                                scopeTag(String(localized: "\(ids.count) servers"), icon: "server.rack")
                            }
                            if conv.messageCount > 0 {
                                Text("\(conv.messageCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 1)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                assistant.togglePin(conv.id)
            } label: {
                Label(conv.isPinned ? "Unpin" : "Pin", systemImage: conv.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                assistant.deleteConversation(conv.id)
            }
        }
        .contextMenu {
            Button {
                assistant.togglePin(conv.id)
            } label: {
                Label(conv.isPinned ? "Unpin" : "Pin", systemImage: conv.isPinned ? "pin.slash" : "pin")
            }

            Button {
                renamingConversation = conv
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                assistant.duplicateConversation(conv.id)
                dismiss()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            if conv.messageCount > 0 {
                Button {
                    assistant.compressConversation(conv.id)
                    dismiss()
                } label: {
                    Label("Compress into New Chat", systemImage: "arrow.down.right.and.arrow.up.left")
                }

                ShareLink(item: assistant.exportMarkdown(for: conv.id)) {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            Button(role: .destructive) {
                assistant.deleteConversation(conv.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func scopeTag(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Rename Conversation Sheet

struct RenameConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: AssistantConversation
    let onSave: (String, String) -> Void

    @State private var title: String
    @State private var icon: String

    private static let quickEmojis = ["💬", "🖥️", "🩺", "🐳", "🔒", "💾", "🌐", "⚡️", "🛠️", "📊", "🗜️", "🔥"]

    init(conversation: AssistantConversation, onSave: @escaping (String, String) -> Void) {
        self.conversation = conversation
        self.onSave = onSave
        _title = State(initialValue: conversation.title)
        _icon = State(initialValue: conversation.icon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Conversation Title", text: $title)
                }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 8)], spacing: 8) {
                        ForEach(Self.quickEmojis, id: \.self) { emoji in
                            Button {
                                icon = emoji
                            } label: {
                                Text(emoji)
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        icon == emoji ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(icon == emoji ? Color.accentColor : .clear, lineWidth: 1.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Rename Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, icon)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

//
//  AssistantView.swift
//  TamioMobile
//
//  Refined iOS 26/27 Liquid Glass AI Server Assistant with FlowDown-inspired
//  multi-session history management:
//  - Leading History drawer button (with live background badge) + Provider switcher
//  - Trailing Ops Skills, Conversation Actions (Rename, Compress, Duplicate,
//    Export Markdown), and New Chat button
//  - Collapsible Reasoning (Thinking) & MCP Tool Call cards inside chat transcript
//  - Per-message Copy, Regenerate, Edit & Resend, Fork from Here, Delete
//  - Per-conversation isolated inline approval cards & draft preservation
//

import SwiftUI
import TamioModule
import UIKit

struct AssistantView: View {
    @EnvironmentObject private var store: TamioStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var assistant = ServerAssistant.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var skillStore = ServerOpsSkillStore.shared
    @State private var bridge = MobileAgentBridge.shared

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    @State private var showHistorySheet = false
    @State private var showProvidersSheet = false
    @State private var showSkillsSheet = false
    @State private var showModelPicker = false
    @State private var showScopePicker = false
    @State private var showRenameSheet = false
    @State private var editingMessage: AssistantChatMessage?
    @State private var editMessageDraft = ""

    private var appleReady: Bool { AppleIntelligenceStatus.current == .available }
    private var activeConversation: AssistantConversation { assistant.activeConversation }
    private var activeSession: ConversationSession { assistant.activeSession }

    private var effectiveSelection: AIActiveSelection {
        assistant.effectiveSelection(for: activeConversation.id)
    }

    private var activeIconSource: AIProviderIconSource {
        AIProviderIconSource.from(selection: effectiveSelection, store: providerStore)
    }

    private var activeCustomProvider: AIProviderConfig? {
        if case .custom(let id) = effectiveSelection {
            return assistant.resolvedProviderConfig(for: activeConversation.id, providerId: id)
        }
        return nil
    }

    private var activeApprovals: [MobileAgentBridge.PendingApproval] {
        bridge.pendingApprovals(for: activeConversation.id)
    }

    private var hasContent: Bool {
        !activeSession.messages.isEmpty || !activeApprovals.isEmpty || activeSession.isStreaming
    }

    private var groups: [String] {
        Set(store.machineGroup.machines.map(\.group))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Group {
            if !assistant.isReadyToChat {
                setupRequiredView
            } else {
                chatContent
            }
        }
        .appleGroupedBackground()
        .navigationTitle(hasContent ? activeConversation.title : String(localized: "Assistant"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showHistorySheet = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "clock.arrow.circlepath")
                        if assistant.backgroundActivityCount > 0 {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -2)
                        }
                    }
                }
                .accessibilityLabel("Conversations")
            }

            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }

            ToolbarItem(placement: .topBarLeading) {
                providerSwitcherMenu
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSkillsSheet = true
                } label: {
                    Image(systemName: assistant.pinnedSkillIDs.isEmpty ? "wand.and.stars" : "wand.and.stars.inverse")
                        .foregroundStyle(assistant.pinnedSkillIDs.isEmpty ? Color.primary : Color.accentColor)
                }
                .accessibilityLabel("Ops Skills")

                if hasContent {
                    Menu {
                        Button {
                            showRenameSheet = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button {
                            assistant.togglePin(activeConversation.id)
                        } label: {
                            Label(
                                activeConversation.isPinned ? "Unpin" : "Pin",
                                systemImage: activeConversation.isPinned ? "pin.slash" : "pin"
                            )
                        }

                        Button {
                            assistant.compressConversation(activeConversation.id)
                        } label: {
                            Label("Compress into New Chat", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        .disabled(activeSession.isStreaming)

                        Button {
                            assistant.duplicateConversation(activeConversation.id)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }

                        ShareLink(item: assistant.exportMarkdown(for: activeConversation.id)) {
                            Label("Export Markdown", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            assistant.deleteConversation(activeConversation.id)
                        } label: {
                            Label("Delete Conversation", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation Actions")
                }

                Button {
                    assistant.createNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Conversation")
            }
        }
        .onAppear {
            bridge.inlineApprovalActive = true
            inputText = assistant.draftText
        }
        .onDisappear {
            bridge.inlineApprovalActive = false
            assistant.draftText = inputText
        }
        .onChange(of: assistant.activeConversationID) { _, _ in
            inputText = assistant.draftText
        }
        .onChange(of: inputText) { _, next in
            if assistant.draftText != next {
                assistant.draftText = next
            }
        }
        .sheet(isPresented: $showHistorySheet) {
            ConversationHistoryView(assistant: assistant)
        }
        .sheet(isPresented: $showProvidersSheet) {
            NavigationStack {
                AIProviderSettingsView(store: providerStore, showsDoneButton: true)
            }
        }
        .sheet(isPresented: $showSkillsSheet) {
            NavigationStack {
                ServerOpsSkillsView(
                    store: skillStore,
                    assistant: assistant,
                    showsDoneButton: true,
                    onRunSkill: { skill in
                        if !assistant.pinnedSkillIDs.contains(skill.id) {
                            assistant.togglePinnedSkill(skill.id)
                        }
                        assistant.send(skill.effectiveRunPrompt)
                    }
                )
            }
        }
        .sheet(isPresented: $showModelPicker) {
            if let active = activeCustomProvider {
                AIModelPickerSheet(
                    providerName: active.name,
                    iconSource: AIProviderIconSource.from(provider: active),
                    selectedModel: Binding(
                        get: { assistant.activeModelLabel(for: activeConversation.id) },
                        set: { assistant.setActiveConversationModel($0, for: active.id) }
                    ),
                    availableModels: Binding(
                        get: { providerStore.provider(id: active.id)?.mergedModels ?? active.mergedModels },
                        set: { _ in }
                    ),
                    recommendedModels: active.kind.recommendedModels,
                    onRefreshModels: {
                        try await providerStore.fetchModels(for: active)
                    }
                )
            }
        }
        .sheet(isPresented: $showScopePicker) {
            TargetScopePickerSheet(
                machines: store.machineGroup.machines,
                groups: groups,
                scope: Binding(
                    get: { assistant.targetScope },
                    set: { assistant.targetScope = $0 }
                )
            )
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameConversationSheet(conversation: activeConversation) { newTitle, newIcon in
                assistant.renameConversation(activeConversation.id, title: newTitle, icon: newIcon)
            }
        }
        .sheet(item: $editingMessage) { msg in
            NavigationStack {
                Form {
                    Section("Edit Prompt") {
                        TextEditor(text: $editMessageDraft)
                            .frame(minHeight: 140)
                    }
                    Section {} footer: {
                        Text("Resending replaces messages after this prompt and generates a fresh response.")
                    }
                }
                .navigationTitle("Edit & Resend")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingMessage = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            let id = msg.id
                            let updated = editMessageDraft
                            editingMessage = nil
                            activeSession.editAndResend(messageID: id, newText: updated)
                        }
                        .fontWeight(.semibold)
                        .disabled(editMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Provider Switcher Menu

    private var providerSwitcherMenu: some View {
        let title = assistant.activeProviderLabel

        return Menu {
            if let active = activeCustomProvider {
                Section(active.name) {
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Switch Model (\(active.model))…", systemImage: "cpu")
                    }
                }
            }

            if appleReady {
                Button {
                    assistant.setActiveConversationProvider(.appleIntelligence)
                } label: {
                    Label(
                        "Apple Intelligence (On-Device)",
                        systemImage: effectiveSelection == .appleIntelligence ? "checkmark" : "sparkles"
                    )
                }
            }

            if !providerStore.enabledProviders.isEmpty {
                Section("AI Providers") {
                    ForEach(providerStore.enabledProviders) { provider in
                        Button {
                            assistant.setActiveConversationProvider(.custom(providerId: provider.id), modelOverride: provider.model)
                        } label: {
                            AIProviderMenuLabel(
                                title: "\(provider.name) (\(provider.model))",
                                provider: provider,
                                isSelected: effectiveSelection == .custom(providerId: provider.id)
                            )
                        }
                    }
                }
            }

            Divider()

            Button {
                showProvidersSheet = true
            } label: {
                Label("Manage AI Providers…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                AIProviderInlineIcon(source: activeIconSource, length: 15)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - First-Run Setup View

    private var setupRequiredView: some View {
        VStack(spacing: 24) {
            Spacer()

            HStack(spacing: 10) {
                AIProviderBadgeView(kind: .openAI, size: .regular)
                AIProviderBadgeView(kind: .anthropic, size: .regular)
                AIProviderBadgeView(kind: .gemini, size: .regular)
                AIProviderBadgeView(kind: .deepSeek, size: .regular)
                AIProviderBadgeView(kind: .ollama, size: .regular)
            }

            VStack(spacing: 8) {
                Text("Configure an AI Provider")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                Text("Connect OpenAI, Anthropic Claude, Gemini, DeepSeek, Ollama, or enable Apple Intelligence to batch-manage your SSH servers with live metrics and approval-gated commands.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                showProvidersSheet = true
            } label: {
                Label("Manage AI Providers", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .appleProminentButton()

            Label("Passwords and SSH private keys are never sent to AI.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        let session = activeSession
        let lastAssistantID = session.messages.last(where: { $0.role == .assistant })?.id

        return VStack(spacing: 0) {
            if !store.machineGroup.machines.isEmpty {
                targetScopeBar
            }

            if !hasContent {
                emptyChatState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.didPruneContext {
                                HStack(spacing: 6) {
                                    Image(systemName: "scissors")
                                        .font(.caption2)
                                    Text("Earlier turns were condensed to fit the context window.")
                                        .font(.caption2)
                                    Spacer()
                                    Button("Compress") {
                                        assistant.compressConversation(activeConversation.id)
                                    }
                                    .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            ForEach(session.messages) { message in
                                ChatMessageRow(
                                    message: message,
                                    canRegenerate: !session.isStreaming && message.id == lastAssistantID,
                                    canMutate: !session.isStreaming,
                                    onRegenerate: { session.regenerateLastReply() },
                                    onEdit: {
                                        editMessageDraft = message.text
                                        editingMessage = message
                                    },
                                    onForkHere: {
                                        assistant.duplicateConversation(activeConversation.id, upToMessageID: message.id)
                                    },
                                    onDelete: { session.deleteMessage(message.id) }
                                )
                                .id(message.id)
                            }

                            if session.isStreaming {
                                streamingBubble(session)
                                    .id("streaming-anchor")
                            }

                            if !activeApprovals.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.shield.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Text("Approval Required")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                    .padding(.leading, 4)

                                    ForEach(activeApprovals) { approval in
                                        InlineApprovalCard(
                                            approval: approval,
                                            onApprove: { bridge.resolve(approval.id, approved: true) },
                                            onApproveOneHour: { bridge.resolve(approval.id, approved: true, allowForOneHour: true) },
                                            onDeny: { bridge.resolve(approval.id, approved: false) }
                                        )
                                    }
                                }
                                .id("approval-anchor")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                        .frame(maxWidth: sizeClass == .regular ? 780 : .infinity)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: session.messages.count) { _, _ in
                        scrollToLatest(proxy, session: session)
                    }
                    .onChange(of: activeApprovals.count) { _, _ in
                        scrollToLatest(proxy, session: session)
                    }
                    .onChange(of: session.streamText.count) { _, _ in
                        if session.isStreaming {
                            proxy.scrollTo("streaming-anchor", anchor: .bottom)
                        }
                    }
                    .onChange(of: assistant.activeConversationID) { _, _ in
                        scrollToLatest(proxy, session: assistant.activeSession)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if !skillStore.enabledSkills.isEmpty && !inputFocused {
                    pinnedSkillsStrip
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                liquidGlassComposerBar(session)
            }
            .animation(.snappy(duration: 0.2), value: inputFocused)
            .frame(maxWidth: sizeClass == .regular ? 780 : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, session: ConversationSession) {
        withAnimation(.easeOut(duration: 0.2)) {
            if !bridge.pendingApprovals(for: session.conversationID).isEmpty {
                proxy.scrollTo("approval-anchor", anchor: .bottom)
            } else if session.isStreaming {
                proxy.scrollTo("streaming-anchor", anchor: .bottom)
            } else if let last = session.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Batch Target Scope Strip

    private var targetScopeBar: some View {
        let scopedCount = assistant.resolvedScopedMachines(for: activeConversation.id).count
        let totalCount = store.machineGroup.machines.count

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Button {
                    showScopePicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.caption2.weight(.semibold))
                        Text(scopeLabel(scopedCount: scopedCount, totalCount: totalCount))
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(assistant.targetScope.isFiltered ? Color.accentColor : .primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        assistant.targetScope.isFiltered
                            ? Color.accentColor.opacity(0.14)
                            : Color(uiColor: .secondarySystemGroupedBackground),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                assistant.targetScope.isFiltered
                                    ? Color.accentColor.opacity(0.35)
                                    : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)

                if assistant.targetScope.isFiltered {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { assistant.targetScope = .all }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset Target Scope")
                }

                ForEach(groups, id: \.self) { group in
                    let isSelected = assistant.targetScope == .group(group)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            assistant.targetScope = isSelected ? .all : .group(group)
                        }
                    } label: {
                        Text(group)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.14)
                                    : Color(uiColor: .secondarySystemGroupedBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func scopeLabel(scopedCount: Int, totalCount: Int) -> String {
        switch assistant.targetScope {
        case .all:
            return String(localized: "All Servers (\(totalCount))")
        case .group(let group):
            return "\(group) (\(scopedCount))"
        case .hosts:
            return String(localized: "\(scopedCount) Selected")
        }
    }

    // MARK: - Empty Chat State

    private struct QuickPrompt: Identifiable {
        var id: String { title }
        let title: String
        let subtitle: String
        let systemImage: String
        let tint: Color
        let prompt: String
    }

    private var quickPrompts: [QuickPrompt] {
        [
            QuickPrompt(
                title: String(localized: "Fleet Health Check"),
                subtitle: String(localized: "CPU, memory, disk & load across servers"),
                systemImage: "heart.text.square",
                tint: .green,
                prompt: String(localized: "Run a fleet health check across my servers: summarize CPU, memory, disk usage, load average, and flag any anomalies.")
            ),
            QuickPrompt(
                title: String(localized: "Batch Disk & Log Audit"),
                subtitle: String(localized: "Large dirs, journalctl & Docker space"),
                systemImage: "internaldrive",
                tint: .orange,
                prompt: String(localized: "Check disk usage across my servers and find the largest directories, systemd journal size, and reclaimable Docker space.")
            ),
            QuickPrompt(
                title: String(localized: "Docker Fleet Audit"),
                subtitle: String(localized: "Exited, restarting & unhealthy containers"),
                systemImage: "shippingbox",
                tint: .blue,
                prompt: String(localized: "Check Docker containers across my servers and highlight any exited, restarting, or unhealthy containers.")
            ),
            QuickPrompt(
                title: String(localized: "Security & SSH Baseline"),
                subtitle: String(localized: "Open ports, SSH policy & failed logins"),
                systemImage: "lock.shield",
                tint: .purple,
                prompt: String(localized: "Audit open listening ports, SSH authentication policy, and recent failed login attempts across my servers.")
            ),
        ]
    }

    private var emptyChatState: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    AIProviderBadgeView(source: activeIconSource, size: .large)

                    Text("Tamio AI Assistant")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    if let active = activeCustomProvider {
                        Button {
                            showModelPicker = true
                        } label: {
                            HStack(spacing: 5) {
                                Text(active.model)
                                    .font(.caption.monospaced().weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.11), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(String(localized: "Apple Intelligence · On-Device"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                .padding(.top, 18)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 11),
                        GridItem(.flexible(), spacing: 11),
                    ],
                    spacing: 11
                ) {
                    ForEach(quickPrompts) { sample in
                        Button {
                            assistant.send(sample.prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: sample.systemImage)
                                        .font(.system(size: 16, weight: .semibold))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(sample.tint)
                                        .frame(width: 32, height: 32)
                                        .background(sample.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sample.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(sample.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
                            )
                            .shadow(
                                color: colorScheme == .dark ? .clear : Color.black.opacity(0.03),
                                radius: 8,
                                x: 0,
                                y: 2
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        showSkillsSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption.weight(.semibold))
                            Text("Browse \(skillStore.enabledSkills.count) Ops Skills")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    if assistant.conversations.count > 1 {
                        Button {
                            showHistorySheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption.weight(.semibold))
                                Text("History (\(assistant.conversations.count))")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Label(
                    "Passwords and SSH private keys are never sent to AI.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: sizeClass == .regular ? 720 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Streaming Bubble

    private func streamingBubble(_ session: ConversationSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toolStatus = session.activeToolStatus {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(toolStatus)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }

            if !session.streamReasoning.isEmpty {
                ReasoningDisclosureBox(text: session.streamReasoning, defaultExpanded: session.streamText.isEmpty)
            }

            if session.streamText.isEmpty {
                if session.activeToolStatus == nil && session.streamReasoning.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                AssistantMarkdownView(text: session.streamText)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pinned Skills Strip

    private var pinnedSkillsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(skillStore.enabledSkills) { skill in
                    let pinned = assistant.pinnedSkillIDs.contains(skill.id)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            assistant.togglePinnedSkill(skill.id)
                        }
                    } label: {
                        Label(skill.name, systemImage: pinned ? "checkmark.circle.fill" : skill.category.systemImage)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(pinned ? Color.accentColor : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                pinned
                                    ? Color.accentColor.opacity(0.14)
                                    : Color(uiColor: .secondarySystemGroupedBackground),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        pinned ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.05),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - iOS 26 Liquid Glass Composer Bar

    private func liquidGlassComposerBar(_ session: ConversationSession) -> some View {
        let canSend = !session.isStreaming && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let controlHeight: CGFloat = 44

        return AppleGlassContainer(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Ask to check metrics, run batch commands, or manage servers…",
                    text: $inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: controlHeight)
                .appleInteractiveGlass(
                    in: RoundedRectangle(cornerRadius: controlHeight / 2, style: .continuous),
                    fallback: Color(uiColor: .secondarySystemGroupedBackground)
                )
                .focused($inputFocused)
                .onSubmit { sendCurrentInput() }

                if session.isStreaming {
                    Button {
                        session.stopGenerating()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: controlHeight, height: controlHeight)
                            .appleInteractiveGlass(
                                in: Circle(),
                                tint: .red,
                                fallback: Color.red
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop Generating")
                } else {
                    Button {
                        sendCurrentInput()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.65))
                            .frame(width: controlHeight, height: controlHeight)
                            .appleInteractiveGlass(
                                in: Circle(),
                                tint: canSend ? .accentColor : nil,
                                fallback: canSend
                                    ? Color.accentColor
                                    : Color(uiColor: .secondarySystemGroupedBackground)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .animation(.snappy(duration: 0.2), value: canSend)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private func sendCurrentInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activeSession.isStreaming else { return }
        inputText = ""
        assistant.draftText = ""
        activeSession.send(trimmed)
    }
}

// MARK: - Chat Message Row (with Reasoning & Collapsible Tool Cards)

private struct ChatMessageRow: View {
    let message: AssistantChatMessage
    let canRegenerate: Bool
    let canMutate: Bool
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    let onForkHere: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: 320, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if canMutate {
                        Button(action: onEdit) {
                            Label("Edit & Resend", systemImage: "pencil")
                        }
                        Button(action: onForkHere) {
                            Label("Fork Conversation Here", systemImage: "arrow.triangle.branch")
                        }
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty {
                    ReasoningDisclosureBox(text: message.reasoning, defaultExpanded: false)
                }
                if !message.text.isEmpty {
                    AssistantMarkdownView(text: message.text)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if canRegenerate {
                    Button(action: onRegenerate) {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                if canMutate {
                    Button(action: onForkHere) {
                        Label("Fork Conversation Here", systemImage: "arrow.triangle.branch")
                    }
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .toolCall:
            if let execution = message.toolExecution {
                ToolExecutionDisclosureCard(title: message.text, execution: execution)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = execution.output
                        } label: {
                            Label("Copy Tool Output", systemImage: "doc.on.doc")
                        }
                        if canMutate {
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }

        case .notice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

        case .error:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canMutate {
                    Button {
                        ServerAssistant.shared.activeSession.retryAfterError()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Collapsible Reasoning Disclosure

private struct ReasoningDisclosureBox: View {
    let text: String
    @State private var expanded: Bool

    init(text: String, defaultExpanded: Bool) {
        self.text = text
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2.weight(.semibold))
                    Text("Thinking Process")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Collapsible MCP Tool Execution Card

private struct ToolExecutionDisclosureCard: View {
    let title: String
    let execution: AssistantToolExecution

    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false

    private var durationLabel: String {
        if execution.durationMs >= 1000 {
            return String(format: "%.1fs", Double(execution.durationMs) / 1000.0)
        }
        return "\(execution.durationMs)ms"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: execution.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(execution.isError ? .red : .green)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !execution.targetHosts.isEmpty {
                        Text(execution.targetHosts.prefix(3).joined(separator: ", ") + (execution.targetHosts.count > 3 ? " +\(execution.targetHosts.count - 3)" : ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if execution.durationMs > 0 {
                        Text(durationLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !execution.argumentsJSON.isEmpty, execution.argumentsJSON != "{}" {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Arguments")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(execution.argumentsJSON)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !execution.output.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Output")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = execution.output
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            ScrollView([.horizontal, .vertical]) {
                                Text(execution.output.prefix(6_000))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                }
                .padding(10)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.85 : 0.9),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.85),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    execution.isError ? Color.red.opacity(0.3) : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Inline Approval Card

private struct InlineApprovalCard: View {
    let approval: MobileAgentBridge.PendingApproval
    let onApprove: () -> Void
    let onApproveOneHour: () -> Void
    let onDeny: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let req = approval.request
        let accent: Color = approval.isDestructive ? .red : .orange

        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: approval.isDestructive ? "exclamationmark.shield.fill" : "terminal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(req.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let task = req.task, !task.isEmpty {
                        Text(task)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)
            }

            if !req.hosts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(req.hosts.prefix(12), id: \.self) { host in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                Text(host)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        if req.hosts.count > 12 {
                            Text("+\(req.hosts.count - 12)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !req.detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(req.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.85 : 0.9),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            }

            HStack(spacing: 8) {
                Button(role: approval.isDestructive ? .destructive : nil, action: onApprove) {
                    Label("Allow", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .appleProminentButton()
                .tint(approval.isDestructive ? .red : .accentColor)

                Button(action: onApproveOneHour) {
                    Text("1 Hour")
                        .font(.subheadline.weight(.medium))
                }
                .appleGlassButton()

                Button(role: .cancel, action: onDeny) {
                    Text("Deny")
                        .font(.subheadline)
                }
                .appleGlassButton()
            }
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Target Scope Picker Sheet

private struct TargetScopePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let machines: [RDMachine]
    let groups: [String]
    @Binding var scope: AssistantTargetScope

    @State private var selectedIDs: Set<RDMachine.ID> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Quick Scope") {
                    Button {
                        scope = .all
                        dismiss()
                    } label: {
                        HStack {
                            Label("All Servers (\(machines.count))", systemImage: "server.rack")
                            Spacer()
                            if scope == .all {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)

                    ForEach(groups, id: \.self) { group in
                        let count = machines.filter { $0.group == group }.count
                        Button {
                            scope = .group(group)
                            dismiss()
                        } label: {
                            HStack {
                                Label("\(group) (\(count))", systemImage: "folder")
                                Spacer()
                                if scope == .group(group) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section("Select Specific Servers") {
                    ForEach(machines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { machine in
                        let picked = selectedIDs.contains(machine.id)
                        Button {
                            if picked { selectedIDs.remove(machine.id) } else { selectedIDs.insert(machine.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(machine.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(machine.remoteAddress)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Target Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        scope = selectedIDs.isEmpty ? .all : .hosts(selectedIDs)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .onAppear {
                if case .hosts(let ids) = scope {
                    selectedIDs = ids
                }
            }
        }
    }
}

// MARK: - Lightweight Native SwiftUI Markdown Renderer

private struct AssistantMarkdownView: View {
    let text: String

    private enum Block: Identifiable {
        case text(Int, String)
        case code(Int, language: String, content: String)
        case table(Int, headers: [String], rows: [[String]])

        var id: Int {
            switch self {
            case .text(let i, _), .code(let i, _, _), .table(let i, _, _): i
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseBlocks(text)) { block in
                switch block {
                case .text(_, let content):
                    inlineMarkdownText(content)
                case .code(_, let language, let code):
                    codeBlockView(language: language, code: code)
                case .table(_, let headers, let rows):
                    tableView(headers: headers, rows: rows)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ raw: String) -> some View {
        let lines = raw.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    EmptyView()
                } else if trimmed.hasPrefix("### ") {
                    markdownSpan(String(trimmed.dropFirst(4)))
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                } else if trimmed.hasPrefix("## ") {
                    markdownSpan(String(trimmed.dropFirst(3)))
                        .font(.headline)
                        .padding(.top, 3)
                } else if trimmed.hasPrefix("# ") {
                    markdownSpan(String(trimmed.dropFirst(2)))
                        .font(.headline.weight(.bold))
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        markdownSpan(String(trimmed.dropFirst(2)))
                            .font(.subheadline)
                    }
                } else {
                    markdownSpan(trimmed)
                        .font(.subheadline)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func markdownSpan(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(content)
    }

    private func codeBlockView(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "shell" : language)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0 ..< headers.count, id: \.self) { col in
                            markdownSpan(col < row.count ? row[col] : "")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private func parseBlocks(_ input: String) -> [Block] {
        var blocks: [Block] = []
        var textLines: [String] = []
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var idx = 0

        func flushText() {
            let joined = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.text(blocks.count, joined))
            }
            textLines.removeAll()
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count, !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[idx])
                    idx += 1
                }
                blocks.append(.code(blocks.count, language: lang, content: codeLines.joined(separator: "\n")))
                idx += 1
                continue
            }

            if trimmed.contains("|"), idx + 1 < lines.count {
                let nextTrimmed = lines[idx + 1].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.contains("|"), nextTrimmed.contains("-") {
                    let headers = splitTableRow(trimmed)
                    if !headers.isEmpty {
                        flushText()
                        var rows: [[String]] = []
                        idx += 2
                        while idx < lines.count {
                            let rowTrimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                            guard rowTrimmed.contains("|") else { break }
                            rows.append(splitTableRow(rowTrimmed))
                            idx += 1
                        }
                        blocks.append(.table(blocks.count, headers: headers, rows: rows))
                        continue
                    }
                }
            }

            textLines.append(line)
            idx += 1
        }
        flushText()
        return blocks
    }

    private func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

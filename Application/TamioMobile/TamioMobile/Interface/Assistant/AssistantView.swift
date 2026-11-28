//
//  AssistantView.swift
//  TamioMobile
//
//  iOS & iPadOS AI Server Assistant built on `TamioAssistant` & `TamioAssistantUI`:
//  - Preserves iOS 26.1+ Liquid Glass `.assistantBottomAccessory` tab-bar morphing
//    (automatically expanding to the full composer when typing OR when a tool
//    waits for in-place approval!)
//  - Document-first `Lakr233/MarkdownView` transcript with streaming fade-in,
//    folded `ActivitySummaryRow`, live `TraceSheetView`, Rewrite presets,
//    Redo-in-Composer, and smart sticky-bottom scrolling
//  - Unified FlowDown composer with file attachments, tool group toggles,
//    floating cache hint, and in-place spring-morphed `ToolApprovalCardView`
//

import SwiftUI
import TamioAssistant
import TamioAssistantUI
import TamioModule
import UIKit
import UniformTypeIdentifiers

struct AssistantView: View {
    @EnvironmentObject private var store: TamioStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var assistant = ServerAssistant.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var skillStore = ServerOpsSkillStore.shared
    @State private var bridge = AssistantAgentBridge.shared

    @State private var inputText = ""
    @State private var pendingAttachments: [AssistantAttachment] = []
    @FocusState private var inputFocused: Bool

    @State private var showHistorySheet = false
    @State private var showProvidersSheet = false
    @State private var showSkillsSheet = false
    @State private var showModelPicker = false
    @State private var showScopePicker = false
    @State private var showRenameSheet = false
    @State private var showFileImporter = false
    @State private var toastMessage: String?

    private var appleReady: Bool { AppleIntelligenceStatus.current == .available }
    private var pccReady: Bool { providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available }
    private var activeConversation: AssistantConversation { assistant.activeConversation }
    private var activeSession: ConversationSession { assistant.activeSession }

    private var usesTabBarAccessoryComposer: Bool {
        if #available(iOS 26.1, *) {
            return sizeClass == .compact
        }
        return false
    }

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

    private var hasContent: Bool {
        activeSession.messages.contains(where: \.hasVisibleContent)
            || activeSession.approvalGate.hasPendingRequest
            || activeSession.isStreaming
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
                                activeConversation.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
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
                            _ = assistant.duplicateConversation(activeConversation.id)
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
            assistant.isComposerActive = false
            inputFocused = false
        }
        .onChange(of: assistant.isComposerActive) { _, active in
            if active, !inputFocused {
                inputText = assistant.draftText
                Task { @MainActor in
                    await Task.yield()
                    inputFocused = true
                }
            }
        }
        .onChange(of: inputFocused) { _, focused in
            if !focused, assistant.isComposerActive {
                assistant.isComposerActive = false
            }
        }
        .onChange(of: assistant.activeConversationID) { _, _ in
            inputText = assistant.draftText
            pendingAttachments = []
        }
        .onChange(of: inputText) { _, next in
            if assistant.draftText != next {
                assistant.draftText = next
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .sourceCode, .json, .yaml, .log, .image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let item = AssistantAttachmentLoader.load(from: url) {
                    pendingAttachments.append(item)
                }
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

            if pccReady {
                Button {
                    assistant.setActiveConversationProvider(.applePrivateCloudCompute)
                } label: {
                    Label(
                        "Apple Intelligence (PCC)",
                        systemImage: effectiveSelection == .applePrivateCloudCompute ? "checkmark" : "cloud"
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
        let scopedCount = assistant.resolvedScopedMachines(for: activeConversation.id).count
        let showExpandedComposer = !usesTabBarAccessoryComposer || assistant.isComposerActive || session.approvalGate.hasPendingRequest

        return VStack(spacing: 0) {
            if !store.machineGroup.machines.isEmpty {
                targetScopeBar
            }

            if usesTabBarAccessoryComposer, !skillStore.enabledSkills.isEmpty {
                pinnedSkillsStrip
                    .padding(.bottom, 6)
            }

            if !hasContent {
                emptyChatState
            } else {
                AssistantTranscriptView(
                    assistant: assistant,
                    session: session,
                    compact: false,
                    maxReadingWidth: sizeClass == .regular ? 780 : nil,
                    horizontalPadding: 16,
                    bottomPadding: 28,
                    codeActions: AssistantMarkdownCodeActions(
                        onSaveSnippet: { code, language in
                            saveSnippet(code: code, language: language)
                        }
                    ),
                    onRefillComposer: { text, attachments in
                        inputText = text
                        assistant.draftText = text
                        pendingAttachments = attachments
                        assistant.isComposerActive = true
                        inputFocused = true
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showExpandedComposer {
                VStack(spacing: 6) {
                    if !usesTabBarAccessoryComposer, !skillStore.enabledSkills.isEmpty, !inputFocused, !session.approvalGate.hasPendingRequest {
                        pinnedSkillsStrip
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    UnifiedComposerView(
                        assistant: assistant,
                        session: session,
                        text: $inputText,
                        attachments: $pendingAttachments,
                        compact: false,
                        scopeLabel: store.machineGroup.machines.isEmpty ? nil : "\(scopedCount)",
                        isScopeFiltered: assistant.targetScope.isFiltered,
                        onTapScope: store.machineGroup.machines.isEmpty ? nil : { showScopePicker = true },
                        onTapSkills: { showSkillsSheet = true },
                        onAttachFile: { showFileImporter = true },
                        externalFocus: $inputFocused,
                        onDismissKeyboard: {
                            assistant.isComposerActive = false
                        },
                        onSend: { text, attachments in
                            HapticsPreference.impact()
                            assistant.draftText = ""
                            inputFocused = false
                            assistant.isComposerActive = false
                            session.send(text, attachments: attachments)
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                .animation(.snappy(duration: 0.2), value: inputFocused)
                .frame(maxWidth: sizeClass == .regular ? 780 : .infinity)
                .frame(maxWidth: .infinity)
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

    // MARK: - Helpers

    private func saveSnippet(code: String, language: String?) {
        let firstLine = code.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "AI Snippet"
        var snippet = RDSnippet()
        snippet.name = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(48))
        snippet.group = "AI Assistant"
        snippet.code = code
        if let language, !language.isEmpty {
            snippet.comment = "Saved from Tamio AI (\(language))"
        }
        store.snippetGroup.insert(snippet)
        HapticsPreference.impact()
        flashToast(String(localized: "Saved to Snippets"))
    }

    private func flashToast(_ message: String) {
        withAnimation(.snappy) { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.snappy) {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

// MARK: - iOS 26.1+ TabView Bottom Accessory Composer

extension View {
    @ViewBuilder
    func assistantBottomAccessory(isEnabled: Bool) -> some View {
        if #available(iOS 26.1, *) {
            modifier(AssistantTabBarAccessoryModifier(isEnabled: isEnabled))
        } else {
            self
        }
    }
}

@available(iOS 26.1, *)
private struct AssistantTabBarAccessoryModifier: ViewModifier {
    let isEnabled: Bool
    @State private var assistant = ServerAssistant.shared

    func body(content: Content) -> some View {
        content
            .tabViewBottomAccessory(
                isEnabled: isEnabled
                    && assistant.isReadyToChat
                    && !assistant.isComposerActive
                    && !assistant.activeSession.approvalGate.hasPendingRequest
            ) {
                AssistantTabBarAccessoryComposer()
            }
    }
}

@available(iOS 26.1, *)
private struct AssistantTabBarAccessoryComposer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var assistant = ServerAssistant.shared

    private var session: ConversationSession { assistant.activeSession }
    private var isInline: Bool { placement == .inline }
    private var trimmedDraft: String { assistant.draftText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !session.isStreaming && !trimmedDraft.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                assistant.isComposerActive = true
            } label: {
                HStack(spacing: 6) {
                    Text(trimmedDraft.isEmpty
                        ? (isInline ? String(localized: "Ask Tamio AI…") : String(localized: "Ask to check metrics, run commands, or manage servers…"))
                        : trimmedDraft)
                        .font(.subheadline)
                        .foregroundStyle(trimmedDraft.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if session.isStreaming {
                Button {
                    session.stopGenerating()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop Generating")
            } else {
                Button {
                    if canSend {
                        let text = trimmedDraft
                        assistant.draftText = ""
                        session.send(text)
                    } else {
                        assistant.isComposerActive = true
                    }
                } label: {
                    Image(systemName: canSend ? "arrow.up" : "keyboard")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            canSend ? Color.accentColor : Color.primary.opacity(0.08),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(canSend ? String(localized: "Send") : String(localized: "Type a message"))
            }
        }
        .padding(.horizontal, isInline ? 12 : 14)
        .padding(.vertical, isInline ? 6 : 8)
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

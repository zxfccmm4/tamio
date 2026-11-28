//
//  MacAssistantView.swift
//  Tamio (macOS)
//
//  Native macOS AI Fleet Assistant built on `TamioAssistant` & `TamioAssistantUI`:
//  - FlowDown time-bucketed multi-session sidebar with debounced full-text
//    search, pin, rename, duplicate, compress, export Markdown, and live
//    running / pending-approval badges
//  - Document-first transcript powered by `Lakr233/MarkdownView`, folded
//    `ActivitySummaryRow` + live `TraceSheetView`, Rewrite presets, View Raw,
//    Redo-in-Composer, and smart sticky-bottom scrolling
//  - Unified FlowDown composer with file/image attachments (picker + drag-drop),
//    tool capability group toggles, Ask/Agent switch, floating cache hint,
//    and in-place spring-morphed `ToolApprovalCardView`
//  - Full AI Providers & Ops Skills managers
//

import AppKit
import SwiftUI
import TamioAssistant
import TamioAssistantUI
import TamioDesign
import TamioModule
import UniformTypeIdentifiers

struct MacAssistantView: View {
    @EnvironmentObject private var store: TamioStore
    @State private var assistant = ServerAssistant.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var skillStore = ServerOpsSkillStore.shared
    @State private var bridge = AssistantAgentBridge.shared

    @State private var inputText = ""
    @State private var pendingAttachments: [AssistantAttachment] = []
    @State private var showHistorySidebar = true
    @State private var showProvidersSheet = false
    @State private var showSkillsSheet = false
    @State private var showHostScopePopover = false
    @State private var historySearch = ""
    @State private var matchedSearchIDs: Set<UUID>?
    @State private var toastMessage: String?

    // Dialog states
    @State private var renamingConversation: AssistantConversation?
    @State private var renameTitle = ""
    @State private var renameEmoji = ""

    private var appleReady: Bool { AppleIntelligenceStatus.current == .available }
    private var pccReady: Bool { providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available }
    private var activeConversation: AssistantConversation { assistant.activeConversation }
    private var activeSession: ConversationSession { assistant.activeSession }
    private var effectiveSelection: AIActiveSelection { assistant.effectiveSelection(for: activeConversation.id) }

    private var hasContent: Bool {
        activeSession.messages.contains(where: \.hasVisibleContent)
            || activeSession.approvalGate.hasPendingRequest
            || activeSession.isStreaming
    }

    private var visibleConversations: [AssistantConversation] {
        let q = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let matchedSearchIDs else { return assistant.conversations }
        return assistant.conversations.filter { matchedSearchIDs.contains($0.id) }
    }

    private var historySections: [AssistantHistorySection] {
        AssistantHistoryGrouping.sections(from: visibleConversations)
    }

    private var allGroups: [String] {
        Array(Set(store.machineGroup.machines.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    private var pinnedSkills: [ServerOpsSkill] {
        let ids = assistant.pinnedSkillIDs
        return skillStore.enabledSkills.filter { ids.contains($0.id) }
    }

    private var scopedCountLabel: String {
        let count = assistant.resolvedScopedMachines(for: activeConversation.id).count
        switch assistant.targetScope {
        case .all: return String(localized: "All (\(count))")
        case .group(let group): return "\(group) (\(count))"
        case .hosts: return String(localized: "\(count) Hosts")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showHistorySidebar {
                conversationSidebar
                    .frame(width: 244)
                Divider()
            }

            mainChatColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: historySearch) {
            let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                matchedSearchIDs = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            matchedSearchIDs = await assistant.searchConversationIDs(query: query)
        }
        .onAppear {
            bridge.install()
            bridge.inlineApprovalActive = true
            inputText = assistant.draftText
        }
        .onDisappear {
            bridge.inlineApprovalActive = false
            assistant.draftText = inputText
        }
        .onChange(of: assistant.activeConversationID) { _, _ in
            inputText = assistant.draftText
            pendingAttachments = []
        }
        .onChange(of: inputText) { _, next in
            if assistant.draftText != next { assistant.draftText = next }
        }
        .sheet(isPresented: $showProvidersSheet) {
            MacAIProviderSettingsSheet(store: providerStore, assistant: assistant) {
                showProvidersSheet = false
            }
        }
        .sheet(isPresented: $showSkillsSheet) {
            MacOpsSkillsSheet(store: skillStore, assistant: assistant) {
                showSkillsSheet = false
            }
        }
        .sheet(item: $renamingConversation) { conv in
            SheetScaffold("Rename Conversation") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("Emoji", text: $renameEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        TextField("Conversation Title", text: $renameTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding()
                .frame(width: 380)
            } footer: {
                Spacer()
                Button("Cancel") { renamingConversation = nil }
                    .buttonStyle(.rx)
                Button("Save") {
                    assistant.renameConversation(conv.id, title: renameTitle, icon: renameEmoji.isEmpty ? nil : renameEmoji)
                    renamingConversation = nil
                }
                .buttonStyle(.rxPrimary)
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Conversation History Sidebar (Time-Bucketed)

    private var conversationSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Conversations")
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                Spacer()
                Button {
                    assistant.createNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("New Conversation")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TextField("Search titles & messages", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(historySections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.rxSectionLabel)
                                .foregroundStyle(.rxInkTertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 2)

                            ForEach(section.conversations) { conv in
                                sidebarConversationRow(conv)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func sidebarConversationRow(_ conv: AssistantConversation) -> some View {
        let isSelected = conv.id == assistant.activeConversationID
        let isRunning = assistant.executingConversationIDs.contains(conv.id)
        let needsApproval = bridge.hasPendingApproval(for: conv.id)

        return Button {
            assistant.selectConversation(conv.id)
        } label: {
            HStack(spacing: 7) {
                if conv.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                if !conv.icon.isEmpty {
                    Text(conv.icon)
                        .font(.system(size: 12))
                }
                Text(conv.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if isRunning {
                    ProgressView().controlSize(.mini)
                }
                if needsApproval {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            conversationContextMenuItems(for: conv)
        }
    }

    @ViewBuilder
    private func conversationContextMenuItems(for conv: AssistantConversation) -> some View {
        Button {
            renameTitle = conv.title
            renameEmoji = conv.icon
            renamingConversation = conv
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            assistant.togglePin(conv.id)
        } label: {
            Label(conv.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: conv.isPinned ? "pin.slash" : "pin")
        }

        Button {
            _ = assistant.duplicateConversation(conv.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button {
            assistant.compressConversation(conv.id)
        } label: {
            Label("Compress into New Chat", systemImage: "arrow.down.right.and.arrow.up.left")
        }

        Button {
            exportConversationMarkdown(conv)
        } label: {
            Label("Export Markdown…", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            assistant.deleteConversation(conv.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func exportConversationMarkdown(_ conv: AssistantConversation) {
        let md = assistant.exportMarkdown(for: conv.id)
        let panel = NSSavePanel()
        let safeTitle = conv.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "Conversation" : safeTitle).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Main Chat Column

    private var mainChatColumn: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider()

            if assistant.isReadyToChat {
                scopeAndSkillsBar
                Divider()
            }

            if !assistant.isReadyToChat {
                setupRequiredView
            } else if !hasContent {
                emptyChatView
            } else {
                AssistantTranscriptView(
                    assistant: assistant,
                    session: activeSession,
                    compact: false,
                    maxReadingWidth: 820,
                    horizontalPadding: 22,
                    bottomPadding: 20,
                    codeActions: AssistantMarkdownCodeActions(
                        onSaveSnippet: { code, lang in
                            saveSnippet(code: code, language: lang)
                        }
                    ),
                    onRefillComposer: { text, attachments in
                        inputText = text
                        assistant.draftText = text
                        pendingAttachments = attachments
                    }
                )
            }

            if assistant.isReadyToChat {
                UnifiedComposerView(
                    assistant: assistant,
                    session: activeSession,
                    text: $inputText,
                    attachments: $pendingAttachments,
                    compact: false,
                    scopeLabel: store.machineGroup.machines.isEmpty ? nil : scopedCountLabel,
                    isScopeFiltered: assistant.targetScope.isFiltered,
                    onTapScope: store.machineGroup.machines.isEmpty ? nil : { showHostScopePopover.toggle() },
                    onTapSkills: { showSkillsSheet = true },
                    onAttachFile: { openFileAttachmentPicker() },
                    onSend: { text, attachments in
                        assistant.draftText = ""
                        activeSession.send(text, attachments: attachments)
                    }
                )
                .frame(maxWidth: 820)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showHistorySidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.rx)
            .help("Toggle Conversation History")

            providerAndModelMenu

            Spacer()

            Button {
                showSkillsSheet = true
            } label: {
                Label("Ops Skills (\(skillStore.enabledSkills.count))", systemImage: "wand.and.stars")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.rx)

            Button {
                showProvidersSheet = true
            } label: {
                Label("AI Providers", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.rx)

            Menu {
                conversationContextMenuItems(for: activeConversation)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Conversation Actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var providerAndModelMenu: some View {
        Menu {
            if appleReady {
                Button {
                    assistant.setActiveConversationProvider(.appleIntelligence)
                } label: {
                    Label("Apple Intelligence (On-Device)", systemImage: effectiveSelection == .appleIntelligence ? "checkmark" : "sparkles")
                }
            }
            if pccReady {
                Button {
                    assistant.setActiveConversationProvider(.applePrivateCloudCompute)
                } label: {
                    Label("Apple Intelligence (PCC)", systemImage: effectiveSelection == .applePrivateCloudCompute ? "checkmark" : "cloud")
                }
            }
            if !providerStore.enabledProviders.isEmpty {
                Divider()
                ForEach(providerStore.enabledProviders) { provider in
                    let isSelectedProvider = effectiveSelection == .custom(providerId: provider.id)
                    let activeModel = isSelectedProvider ? assistant.activeModelLabel() : provider.model
                    let models = provider.mergedModels
                    if models.count > 1 {
                        Menu {
                            ForEach(models, id: \.self) { m in
                                Button {
                                    assistant.setActiveConversationModel(m, for: provider.id)
                                } label: {
                                    Label(m, systemImage: (isSelectedProvider && activeModel == m) ? "checkmark" : "cpu")
                                }
                            }
                        } label: {
                            Label(
                                "\(provider.name) (\(provider.model))",
                                systemImage: isSelectedProvider ? "checkmark" : provider.kind.systemImage
                            )
                        }
                    } else {
                        Button {
                            assistant.setActiveConversationProvider(.custom(providerId: provider.id), modelOverride: provider.model)
                        } label: {
                            Label(
                                "\(provider.name) (\(provider.model))",
                                systemImage: isSelectedProvider ? "checkmark" : provider.kind.systemImage
                            )
                        }
                    }
                }
            }
            Divider()
            Button("Manage AI Providers…") { showProvidersSheet = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(assistant.activeProviderLabel)
                    .font(.rxBodyStrong)
                let model = assistant.activeModelLabel()
                if !model.isEmpty {
                    Text("· \(model)")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Target Scope & Pinned Skills Bar

    private var scopeAndSkillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopePill(
                    title: String(localized: "All Servers (\(store.machineGroup.machines.count))"),
                    icon: "server.rack",
                    selected: assistant.targetScope == .all
                ) {
                    assistant.targetScope = .all
                }

                ForEach(allGroups, id: \.self) { group in
                    let count = store.machineGroup.machines.filter { $0.group == group }.count
                    scopePill(
                        title: "\(group) (\(count))",
                        icon: "folder",
                        selected: assistant.targetScope == .group(group)
                    ) {
                        assistant.targetScope = .group(group)
                    }
                }

                let selectedHostCount: Int = {
                    if case .hosts(let ids) = assistant.targetScope { return ids.count }
                    return 0
                }()
                Button {
                    showHostScopePopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .semibold))
                        Text(selectedHostCount > 0 ? String(localized: "\(selectedHostCount) Selected") : String(localized: "Select Hosts"))
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        selectedHostCount > 0 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                        in: Capsule()
                    )
                    .foregroundStyle(selectedHostCount > 0 ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHostScopePopover, arrowEdge: .bottom) {
                    MacHostScopePopover(
                        machines: store.machineGroup.machines,
                        scope: Binding(
                            get: { assistant.targetScope },
                            set: { assistant.targetScope = $0 }
                        )
                    )
                }

                if !pinnedSkills.isEmpty {
                    Divider().frame(height: 14).padding(.horizontal, 2)
                    ForEach(pinnedSkills) { skill in
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text(skill.name)
                                .font(.caption.weight(.medium))
                            Button {
                                assistant.togglePinnedSkill(skill.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private func scopePill(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var setupRequiredView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 38))
                .foregroundStyle(Color.accentColor)
            Text("Configure an AI Provider")
                .font(.title3.bold())
            Text("Connect OpenAI, Anthropic Claude, Gemini, DeepSeek, Ollama, or enable Apple Intelligence to manage your SSH servers with live metrics and approval-gated MCP tools.")
                .font(.subheadline)
                .foregroundStyle(.rxInkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Manage AI Providers…") { showProvidersSheet = true }
                .buttonStyle(.rxPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyChatView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Text("Tamio AI Fleet Assistant")
                    .font(.title2.bold())
                Text("Inspect live metrics, diagnose services, and run approval-gated commands across your servers.")
                    .font(.subheadline)
                    .foregroundStyle(.rxInkSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    quickPromptButton("Fleet Health Check", "CPU, memory, disk & load across servers", "heart.text.square",
                                      "Run a fleet health check across my servers: summarize CPU, memory, disk usage, load average, and flag any anomalies.")
                    quickPromptButton("Batch Disk & Log Audit", "Large dirs, journalctl & Docker space", "internaldrive",
                                      "Check disk usage across my servers and find the largest directories, systemd journal size, and reclaimable Docker space.")
                    quickPromptButton("Docker Fleet Audit", "Exited, restarting & unhealthy containers", "shippingbox",
                                      "Check Docker containers across my servers and highlight any exited, restarting, or unhealthy containers.")
                    quickPromptButton("Security & SSH Baseline", "Open ports, SSH policy & failed logins", "lock.shield",
                                      "Audit open listening ports, SSH authentication policy, and recent failed login attempts across my servers.")
                }
                .frame(maxWidth: 680)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func quickPromptButton(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ icon: String, _ prompt: String) -> some View {
        Button {
            activeSession.send(prompt)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.rxBodyStrong).foregroundStyle(.rxInk)
                    Text(subtitle).font(.rxHelp).foregroundStyle(.rxInkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .rxCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Attachments & Snippets

    private func openFileAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .yaml, .log, .image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let item = AssistantAttachmentLoader.load(from: url) {
                pendingAttachments.append(item)
            }
        }
    }

    private func saveSnippet(code: String, language: String?) {
        let firstLine = code.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "AI Snippet"
        let cleanName = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(48))
        var snippet = RDSnippet()
        snippet.name = cleanName.isEmpty ? "AI Snippet" : cleanName
        snippet.group = "AI Assistant"
        snippet.code = code
        if let language, !language.isEmpty {
            snippet.comment = "Saved from Tamio AI (\(language))"
        }
        store.snippetGroup.insert(snippet)
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

// MARK: - Host Scope Multi-Select Popover

private struct MacHostScopePopover: View {
    let machines: [RDMachine]
    @Binding var scope: AssistantTargetScope
    @State private var search = ""

    private var selectedIDs: Set<RDMachine.ID> {
        if case .hosts(let ids) = scope { return ids }
        return []
    }

    private var filtered: [RDMachine] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return machines }
        return machines.filter {
            $0.name.lowercased().contains(q)
                || $0.remoteAddress.lowercased().contains(q)
                || $0.group.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target Servers").font(.rxBodyStrong)
                Spacer()
                if !selectedIDs.isEmpty {
                    Button("Clear") { scope = .all }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            TextField("Filter servers", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { machine in
                        let checked = selectedIDs.contains(machine.id)
                        Button {
                            var next = selectedIDs
                            if checked { next.remove(machine.id) } else { next.insert(machine.id) }
                            scope = next.isEmpty ? .all : .hosts(next)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(machine.name).font(.subheadline)
                                    Text(machine.remoteAddress).font(.caption2.monospaced()).foregroundStyle(.rxInkSecondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 280)
    }
}

// MARK: - AI Providers & Preferences Sheet

private struct MacAIProviderSettingsSheet: View {
    @Bindable var store: AIProviderStore
    @Bindable var assistant: ServerAssistant
    let close: () -> Void

    @State private var editingID: String?
    @State private var kind: AIProviderKind = .openAI
    @State private var name = ""
    @State private var baseURL = ""
    @State private var appendV1Suffix = true
    @State private var model = ""
    @State private var apiKey = ""
    @State private var discoveredModels: [String] = []
    @State private var isTesting = false
    @State private var isFetchingModels = false
    @State private var testResult: AIProviderTestResult?
    @State private var fetchError: String?

    private var appleStatus: AppleIntelligenceStatus { .current }
    private var pccStatus: ApplePrivateCloudComputeStatus { .current }

    private var draftConfig: AIProviderConfig {
        AIProviderConfig(
            id: editingID ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name,
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.defaultBaseURL : baseURL,
            appendV1Suffix: appendV1Suffix,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.defaultModel : model,
            availableModels: discoveredModels.isEmpty ? kind.recommendedModels : discoveredModels
        )
    }

    var body: some View {
        SheetScaffold("AI Providers") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apple Intelligence").font(.rxBodyStrong)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence (On-Device)").font(.subheadline.weight(.medium))
                                Text(appleStatus.localizedDescription).font(.caption).foregroundStyle(.rxInkSecondary)
                            }
                            Spacer()
                            Button(store.activeSelection == .appleIntelligence ? String(localized: "Active") : String(localized: "Use")) {
                                store.selectActive(.appleIntelligence)
                            }
                            .buttonStyle(.rx)
                            .disabled(appleStatus != .available)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence (PCC)").font(.subheadline.weight(.medium))
                                Text(pccStatus.localizedDescription).font(.caption).foregroundStyle(.rxInkSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $store.privateCloudComputeEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                            Button(store.activeSelection == .applePrivateCloudCompute ? String(localized: "Active") : String(localized: "Use")) {
                                store.selectActive(.applePrivateCloudCompute)
                            }
                            .buttonStyle(.rx)
                            .disabled(pccStatus != .available || !store.privateCloudComputeEnabled)
                        }
                    }
                    .padding(12)
                    .rxCard()

                    if !store.providers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configured Providers").font(.rxBodyStrong)
                            ForEach(store.providers) { provider in
                                let isActive = store.activeSelection == .custom(providerId: provider.id)
                                HStack(spacing: 10) {
                                    Image(systemName: provider.kind.systemImage)
                                        .foregroundStyle(provider.kind.tintColor)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(provider.name).font(.subheadline.weight(.medium))
                                            if isActive {
                                                Text("Active")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        Text("\(provider.model) · \(provider.resolvedBaseURL)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.rxInkSecondary)
                                    }
                                    Spacer()
                                    Button("Edit") { loadForEditing(provider) }
                                        .buttonStyle(.rx)
                                    Button("Use") { store.selectActive(.custom(providerId: provider.id)) }
                                        .buttonStyle(.rx)
                                        .disabled(isActive)
                                    Button("Delete", role: .destructive) {
                                        if editingID == provider.id { resetForm() }
                                        store.deleteProvider(id: provider.id)
                                    }
                                    .buttonStyle(.rx)
                                }
                                if provider.id != store.providers.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(12)
                        .rxCard()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(editingID == nil ? String(localized: "Add Remote Provider") : String(localized: "Edit Remote Provider"))
                                .font(.rxBodyStrong)
                            Spacer()
                            if editingID != nil {
                                Button("Cancel Edit") { resetForm() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }

                        Picker("Provider", selection: $kind) {
                            ForEach(AIProviderKind.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .onChange(of: kind) { _, next in
                            if editingID == nil {
                                name = next.displayName
                                baseURL = next.defaultBaseURL
                                appendV1Suffix = next.defaultAppendV1Suffix
                                model = next.defaultModel
                                discoveredModels = next.recommendedModels
                                testResult = nil
                                fetchError = nil
                            }
                        }

                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                        Toggle("Automatically append /v1 suffix", isOn: $appendV1Suffix)
                            .font(.caption)

                        HStack(spacing: 8) {
                            TextField("Model", text: $model).textFieldStyle(.roundedBorder)
                            let choices = Array(Set(discoveredModels + kind.recommendedModels)).sorted()
                            if !choices.isEmpty {
                                Menu("Presets") {
                                    ForEach(choices, id: \.self) { m in
                                        Button(m) { model = m }
                                    }
                                }
                                .fixedSize()
                            }
                            Button {
                                fetchModels()
                            } label: {
                                if isFetchingModels {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("Fetch Models")
                                }
                            }
                            .buttonStyle(.rx)
                            .disabled(isFetchingModels)
                        }

                        SecureField(kind.requiresAPIKey ? String(localized: "API Key") : String(localized: "API Key (Optional)"), text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        if let result = testResult {
                            HStack(spacing: 6) {
                                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.succeeded ? .green : .red)
                                Text(result.succeeded ? "\(result.message) (\(result.latencyMs) ms)" : result.message)
                                    .font(.caption)
                                    .foregroundStyle(result.succeeded ? .green : .red)
                            }
                        }
                        if let fetchError {
                            Text(fetchError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        HStack(spacing: 8) {
                            Button {
                                runConnectionTest()
                            } label: {
                                if isTesting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("Test Connection")
                                }
                            }
                            .buttonStyle(.rx)
                            .disabled(isTesting)

                            Spacer()

                            Button(editingID == nil ? String(localized: "Add Provider") : String(localized: "Save Changes")) {
                                saveProvider()
                            }
                            .buttonStyle(.rxPrimary)
                        }
                    }
                    .padding(12)
                    .rxCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Assistant Preferences").font(.rxBodyStrong)
                        Toggle("Show Activity Steps Inline (list thoughts & tool calls in chat)", isOn: $assistant.inlineActivityStepsEnabled)
                            .font(.subheadline)
                        Toggle("Cross-Session Memory (inject recent chat summaries)", isOn: $assistant.crossSessionMemoryEnabled)
                            .font(.subheadline)
                        HStack {
                            Text("Context Token Budget").font(.subheadline)
                            Spacer()
                            Picker("", selection: $assistant.contextTokenBudget) {
                                Text("32K").tag(32_000)
                                Text("64K").tag(64_000)
                                Text("128K").tag(128_000)
                                Text("200K").tag(200_000)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                    .padding(12)
                    .rxCard()
                }
                .padding()
            }
            .frame(width: 580, height: 600)
            .onAppear {
                if baseURL.isEmpty {
                    name = kind.displayName
                    baseURL = kind.defaultBaseURL
                    appendV1Suffix = kind.defaultAppendV1Suffix
                    model = kind.defaultModel
                    discoveredModels = kind.recommendedModels
                }
            }
        } footer: {
            Spacer()
            Button("Done", action: close).buttonStyle(.rxPrimary)
        }
    }

    private func loadForEditing(_ provider: AIProviderConfig) {
        editingID = provider.id
        kind = provider.kind
        name = provider.name
        baseURL = provider.baseURL
        appendV1Suffix = provider.appendV1Suffix
        model = provider.model
        discoveredModels = provider.availableModels
        apiKey = store.apiKey(for: provider.id) ?? ""
        testResult = nil
        fetchError = nil
    }

    private func resetForm() {
        editingID = nil
        kind = .openAI
        name = kind.displayName
        baseURL = kind.defaultBaseURL
        appendV1Suffix = kind.defaultAppendV1Suffix
        model = kind.defaultModel
        apiKey = ""
        discoveredModels = kind.recommendedModels
        testResult = nil
        fetchError = nil
    }

    private func saveProvider() {
        let cfg = draftConfig
        if editingID != nil {
            try? store.updateProvider(cfg, apiKey: apiKey)
        } else {
            try? store.addProvider(cfg, apiKey: apiKey, makeActive: true)
        }
        resetForm()
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil
        fetchError = nil
        let cfg = draftConfig
        let key = apiKey
        Task {
            let result = await store.testConnection(for: cfg, apiKeyOverride: key.isEmpty ? nil : key)
            testResult = result
            if !result.discoveredModels.isEmpty {
                discoveredModels = result.discoveredModels
            }
            isTesting = false
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil
        let cfg = draftConfig
        let key = apiKey
        Task {
            do {
                let models = try await store.fetchModels(for: cfg, apiKeyOverride: key.isEmpty ? nil : key)
                if !models.isEmpty {
                    discoveredModels = models
                    if model.isEmpty { model = models[0] }
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }
}

// MARK: - Ops Skills Sheet

private struct MacOpsSkillsSheet: View {
    @Bindable var store: ServerOpsSkillStore
    let assistant: ServerAssistant
    let close: () -> Void

    @State private var search = ""
    @State private var selectedCategory: ServerOpsSkillCategory?
    @State private var importURL = ""
    @State private var isImportingURL = false
    @State private var importStatus: String?

    private var filteredSkills: [ServerOpsSkill] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.skills.filter { skill in
            if let cat = selectedCategory, skill.category != cat { return false }
            if q.isEmpty { return true }
            return skill.name.lowercased().contains(q)
                || skill.description.lowercased().contains(q)
        }
    }

    var body: some View {
        SheetScaffold("Ops Skills") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Import SKILL.md from GitHub or raw URL…", text: $importURL)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            importFromURL()
                        } label: {
                            if isImportingURL {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Import URL")
                            }
                        }
                        .buttonStyle(.rx)
                        .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingURL)

                        Button("Import File…") {
                            importFromFile()
                        }
                        .buttonStyle(.rx)
                    }

                    if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.rxInkSecondary)
                    }

                    HStack(spacing: 8) {
                        TextField("Search skills", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Picker("Category", selection: $selectedCategory) {
                            Text("All Categories").tag(ServerOpsSkillCategory?.none)
                            ForEach(ServerOpsSkillCategory.allCases) { cat in
                                Text(cat.displayName).tag(ServerOpsSkillCategory?.some(cat))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredSkills) { skill in
                            let isPinned = assistant.pinnedSkillIDs.contains(skill.id)
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { skill.isEnabled },
                                    set: { _ in store.toggleEnabled(id: skill.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Image(systemName: skill.category.systemImage)
                                            .font(.caption)
                                            .foregroundStyle(Color.accentColor)
                                        Text(skill.name).font(.subheadline.weight(.medium))
                                        if !skill.isBuiltIn {
                                            Text("Custom")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.purple.opacity(0.14), in: Capsule())
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.rxInkSecondary)
                                }

                                Spacer()

                                Button {
                                    assistant.togglePinnedSkill(skill.id)
                                } label: {
                                    Image(systemName: isPinned ? "pin.fill" : "pin")
                                        .foregroundStyle(isPinned ? .orange : .secondary)
                                }
                                .buttonStyle(.rx)
                                .help(isPinned ? String(localized: "Unpin from chat") : String(localized: "Pin to current chat"))

                                Button("Run") {
                                    assistant.activeSession.send(skill.effectiveRunPrompt)
                                    close()
                                }
                                .buttonStyle(.rx)

                                if !skill.isBuiltIn {
                                    Button(role: .destructive) {
                                        store.deleteSkill(id: skill.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.rx)
                                }
                            }
                            .padding(10)
                            .rxCard()
                        }
                    }
                    .padding(16)
                }
            }
            .frame(width: 640, height: 540)
        } footer: {
            Spacer()
            Button("Done", action: close).buttonStyle(.rxPrimary)
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let skill = store.importFromMarkdown(text, sourceURL: url.lastPathComponent)
            importStatus = String(localized: "Imported skill \"\(skill.name)\".")
        } catch {
            importStatus = error.localizedDescription
        }
    }

    private func importFromURL() {
        let raw = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isImportingURL = true
        importStatus = nil
        Task {
            do {
                let skill = try await store.importFromURL(raw)
                importURL = ""
                importStatus = String(localized: "Imported skill \"\(skill.name)\".")
            } catch {
                importStatus = error.localizedDescription
            }
            isImportingURL = false
        }
    }
}

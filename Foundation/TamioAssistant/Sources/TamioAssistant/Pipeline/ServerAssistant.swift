//
//  ServerAssistant.swift
//  TamioAssistant
//
//  Multi-session manager uniting macOS and iOS AI Assistants:
//  - Conversation CRUD, pinning, renaming, duplication, forking, compression, search
//  - Per-conversation Provider / Model / Target Scope / Interaction Mode / Tools toggle
//  - Capability-grouped built-in tools (`AssistantToolSet` builder)
//  - FlowDown `inlineActivityStepsEnabled` preference & `toolsChangeHint` signal
//

import Foundation
import Observation
import TamioModule

@MainActor
@Observable
public final class ServerAssistant {
    public static let shared = ServerAssistant()

    private static let crossSessionMemoryKey = "sb.moe.tamio.ai.crossSessionMemory"
    private static let contextBudgetKey = "sb.moe.tamio.ai.contextTokenBudget"
    private static let inlineActivityStepsKey = "sb.moe.tamio.ai.inlineActivitySteps"
    private static let enabledToolGroupsKey = "sb.moe.tamio.ai.enabledToolGroups"

    public private(set) var conversations: [AssistantConversation] = []
    public private(set) var activeConversationID: UUID
    public private(set) var executingConversationIDs: Set<UUID> = []

    /// Transient floating notice above the composer when offered tools change mid-chat.
    public private(set) var toolsChangeHintText: String?
    private var toolsChangeHintTask: Task<Void, Never>?

    public var crossSessionMemoryEnabled: Bool {
        didSet { UserDefaults.standard.set(crossSessionMemoryEnabled, forKey: Self.crossSessionMemoryKey) }
    }

    public var contextTokenBudget: Int {
        didSet { UserDefaults.standard.set(contextTokenBudget, forKey: Self.contextBudgetKey) }
    }

    /// FlowDown `InlineActivityStepsSetting`: lists every thought and tool call line
    /// directly under the ActivitySummary header instead of collapsing to one row.
    public var inlineActivityStepsEnabled: Bool {
        didSet { UserDefaults.standard.set(inlineActivityStepsEnabled, forKey: Self.inlineActivityStepsKey) }
    }

    /// Globally enabled tool capability groups offered in Agent mode.
    public var enabledToolGroups: Set<AssistantToolGroup> {
        didSet {
            let raw = enabledToolGroups.map(\.rawValue).sorted()
            UserDefaults.standard.set(raw, forKey: Self.enabledToolGroupsKey)
        }
    }

    public let providerStore: AIProviderStore
    public let skillStore: ServerOpsSkillStore
    public let bridge: AssistantAgentBridge

    /// True while the user is actively typing in iOS compact composer.
    public var isComposerActive = false

    private let diskStore: AssistantConversationDiskStore
    private let remoteClient: RemoteLLMClient
    private var sessions: [UUID: ConversationSession] = [:]
    private let builtInMCPTools: [TamioMCPBuiltinTool]

    public init(
        providerStore: AIProviderStore? = nil,
        skillStore: ServerOpsSkillStore? = nil,
        bridge: AssistantAgentBridge? = nil,
        diskStore: AssistantConversationDiskStore = .shared,
        remoteClient: RemoteLLMClient = RemoteLLMClient()
    ) {
        self.providerStore = providerStore ?? .shared
        self.skillStore = skillStore ?? .shared
        self.bridge = bridge ?? .shared
        self.diskStore = diskStore
        self.remoteClient = remoteClient
        self.builtInMCPTools = TamioMCPBuiltinTool.allBuiltInMCPTools()

        self.crossSessionMemoryEnabled = UserDefaults.standard.bool(forKey: Self.crossSessionMemoryKey)
        let savedBudget = UserDefaults.standard.integer(forKey: Self.contextBudgetKey)
        self.contextTokenBudget = savedBudget > 0 ? savedBudget : 64_000
        self.inlineActivityStepsEnabled = UserDefaults.standard.bool(forKey: Self.inlineActivityStepsKey)

        if let rawGroups = UserDefaults.standard.stringArray(forKey: Self.enabledToolGroupsKey) {
            let parsed = Set(rawGroups.compactMap(AssistantToolGroup.init(rawValue:)))
            self.enabledToolGroups = parsed
        } else {
            self.enabledToolGroups = Set(AssistantToolGroup.allCases)
        }

        let loaded = diskStore.loadIndex()
        if let first = Self.sorted(loaded).first {
            self.conversations = Self.sorted(loaded)
            self.activeConversationID = first.id
        } else {
            let initial = AssistantConversation()
            self.conversations = [initial]
            self.activeConversationID = initial.id
            diskStore.saveIndex([initial])
        }
    }

    // MARK: - Active Conversation & Session Accessors

    public var activeConversation: AssistantConversation {
        conversation(id: activeConversationID) ?? conversations.first ?? AssistantConversation()
    }

    public var activeSession: ConversationSession {
        session(for: activeConversationID)
    }

    public func conversation(id: UUID) -> AssistantConversation? {
        conversations.first { $0.id == id }
    }

    public func sessionIfLoaded(for id: UUID) -> ConversationSession? {
        sessions[id]
    }

    public func session(for id: UUID) -> ConversationSession {
        if let cached = sessions[id] { return cached }
        let msgs = diskStore.loadMessages(for: id)
        let created = ConversationSession(conversationID: id, messages: msgs, manager: self, remoteClient: remoteClient)
        sessions[id] = created
        return created
    }

    public var pendingApprovalConversationIDs: Set<UUID> {
        Set(sessions.values.compactMap { $0.approvalGate.hasPendingRequest ? $0.conversationID : nil })
    }

    public var backgroundActivityCount: Int {
        let runningOthers = executingConversationIDs.filter { $0 != activeConversationID }.count
        let approvalOthers = pendingApprovalConversationIDs.filter { $0 != activeConversationID }.count
        return runningOthers + approvalOthers
    }

    public func denyAllPendingApprovals() {
        for session in sessions.values {
            session.approvalGate.denyPending()
        }
    }

    // MARK: - Convenience Forwarding

    public var messages: [AssistantChatMessage] { activeSession.messages }
    public var streamText: String { activeSession.streamText }
    public var streamReasoning: String { activeSession.streamReasoning }
    public var isStreaming: Bool { activeSession.isStreaming }
    public var activeToolStatus: String? { activeSession.activeToolStatus }

    public var targetScope: AssistantTargetScope {
        get { sanitizedScope(activeConversation.targetScope) }
        set {
            updateMetadata(activeConversationID) { $0.targetScope = newValue }
        }
    }

    public var pinnedSkillIDs: Set<String> {
        get { activeConversation.pinnedSkillIDs }
        set {
            updateMetadata(activeConversationID) { $0.pinnedSkillIDs = newValue }
            activeSession.resetOnDeviceContext()
        }
    }

    public var draftText: String {
        get { activeConversation.draftText }
        set {
            guard let idx = conversations.firstIndex(where: { $0.id == activeConversationID }),
                  conversations[idx].draftText != newValue
            else { return }
            conversations[idx].draftText = newValue
            diskStore.saveIndex(conversations)
        }
    }

    public func togglePinnedSkill(_ skillID: String) {
        var set = pinnedSkillIDs
        if set.contains(skillID) { set.remove(skillID) } else { set.insert(skillID) }
        pinnedSkillIDs = set
    }

    public func send(_ text: String, attachments: [AssistantAttachment] = []) {
        activeSession.send(text, attachments: attachments)
    }

    public func stopGenerating() {
        activeSession.stopGenerating()
    }

    // MARK: - Tools Configuration & Cache-Invalidation Hint (FlowDown Pattern)

    public func toolsEnabled(for conversationID: UUID) -> Bool {
        conversation(id: conversationID)?.effectiveToolsEnabled ?? true
    }

    public func setToolsEnabled(_ enabled: Bool, for conversationID: UUID) {
        let before = toolsEnabled(for: conversationID)
        updateMetadata(conversationID) { $0.toolsEnabled = enabled }
        maybeShowToolsChangeHint(
            conversationID: conversationID,
            toolsEnabledBefore: before,
            toolsEnabledAfter: enabled,
            selectionChanged: false
        )
    }

    public func toggleToolGroup(_ group: AssistantToolGroup, in conversationID: UUID) {
        let beforeTools = toolsEnabled(for: conversationID)
        let turnedOn: Bool
        if enabledToolGroups.contains(group) {
            enabledToolGroups.remove(group)
            turnedOn = false
        } else {
            enabledToolGroups.insert(group)
            turnedOn = true
        }
        let afterTools = AssistantToolsSelectionPolicy.toolsEnabledAfterSelection(
            selectionTurnedOn: turnedOn,
            toolsEnabled: beforeTools,
            modelSupportsTools: true
        )
        if afterTools != beforeTools {
            updateMetadata(conversationID) { $0.toolsEnabled = afterTools }
        }
        maybeShowToolsChangeHint(
            conversationID: conversationID,
            toolsEnabledBefore: beforeTools,
            toolsEnabledAfter: afterTools,
            selectionChanged: true
        )
    }

    private func maybeShowToolsChangeHint(
        conversationID: UUID,
        toolsEnabledBefore: Bool,
        toolsEnabledAfter: Bool,
        selectionChanged: Bool
    ) {
        let msgs = session(for: conversationID).messages
        guard AssistantToolsSelectionPolicy.shouldHintToolsChange(
            toolsEnabledBefore: toolsEnabledBefore,
            toolsEnabledAfter: toolsEnabledAfter,
            selectionChanged: selectionChanged,
            conversationHasMessages: AssistantToolsSelectionPolicy.conversationHasMessages(msgs)
        ) else { return }

        toolsChangeHintTask?.cancel()
        toolsChangeHintText = String(localized: "Tools changed. The next reply may take a little longer.")
        toolsChangeHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toolsChangeHintText = nil
        }
    }

    /// Builds a frozen `AssistantToolSet` snapshot for one turn of `conversationID`.
    public func makeToolSet(for conversationID: UUID) -> AssistantToolSet {
        guard toolsEnabled(for: conversationID) else {
            return .empty
        }
        let mode = interactionMode(for: conversationID)
        if mode == .ask {
            return AssistantToolSet(tools: [RequestAgentModeTool()], injectReason: false)
        }
        var active: [any AssistantTool] = builtInMCPTools.filter { enabledToolGroups.contains($0.group) }
        if enabledToolGroups.contains(.skills) {
            active.append(LoadOpsSkillTool(lookupSkill: { [skillStore] query in
                skillStore.skill(idOrName: query)
            }))
        }
        return AssistantToolSet(tools: active, injectReason: true)
    }

    // MARK: - Provider Resolution

    public func effectiveSelection(for conversationID: UUID? = nil) -> AIActiveSelection {
        let appleReady = AppleIntelligenceStatus.current == .available
        let pccReady = providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available
        if let cid = conversationID ?? Optional(activeConversationID),
           let override = conversation(id: cid)?.providerSelection
        {
            switch override {
            case .appleIntelligence where appleReady:
                return .appleIntelligence
            case .applePrivateCloudCompute where pccReady:
                return .applePrivateCloudCompute
            case .custom(let id) where providerStore.providers.contains(where: { $0.id == id && $0.isEnabled }):
                return .custom(providerId: id)
            default:
                break
            }
        }
        return providerStore.effectiveSelection(appleIntelligenceAvailable: appleReady, pccAvailable: pccReady)
    }

    public func resolvedProviderConfig(for conversationID: UUID, providerId: String) -> AIProviderConfig? {
        guard var config = providerStore.provider(id: providerId), config.isEnabled else { return nil }
        if let overrideModel = conversation(id: conversationID)?.modelOverride, !overrideModel.isEmpty {
            config.model = overrideModel
        }
        return config
    }

    public var isReadyToChat: Bool {
        switch effectiveSelection(for: activeConversationID) {
        case .appleIntelligence:
            return AppleIntelligenceStatus.current == .available
        case .applePrivateCloudCompute:
            return providerStore.privateCloudComputeEnabled && ApplePrivateCloudComputeStatus.current == .available
        case .custom(let providerId):
            guard let config = resolvedProviderConfig(for: activeConversationID, providerId: providerId) else { return false }
            return providerStore.hasCredential(for: config) && !config.model.isEmpty
        }
    }

    public var activeProviderLabel: String {
        let appleReady = AppleIntelligenceStatus.current == .available
        switch effectiveSelection(for: activeConversationID) {
        case .appleIntelligence:
            return String(localized: "Apple Intelligence")
        case .applePrivateCloudCompute:
            return String(localized: "Apple Intelligence (PCC)")
        case .custom(let id):
            return providerStore.provider(id: id)?.name ?? providerStore.activeDisplayName(appleIntelligenceAvailable: appleReady)
        }
    }

    public func activeModelLabel(for conversationID: UUID? = nil) -> String {
        let cid = conversationID ?? activeConversationID
        switch effectiveSelection(for: cid) {
        case .appleIntelligence:
            return String(localized: "On-Device")
        case .applePrivateCloudCompute:
            return String(localized: "Private Cloud Compute")
        case .custom(let id):
            return resolvedProviderConfig(for: cid, providerId: id)?.model ?? ""
        }
    }

    public func setActiveConversationProvider(_ selection: AIActiveSelection, modelOverride: String? = nil) {
        providerStore.selectActive(selection)
        updateMetadata(activeConversationID) { conv in
            conv.providerSelection = selection
            conv.modelOverride = modelOverride
        }
    }

    public func setActiveConversationModel(_ model: String, for providerId: String) {
        providerStore.setModel(model, for: providerId)
        updateMetadata(activeConversationID) { conv in
            conv.providerSelection = .custom(providerId: providerId)
            conv.modelOverride = model
        }
    }

    // MARK: - Conversation CRUD

    @discardableResult
    public func createNewConversation(
        targetScope: AssistantTargetScope? = nil,
        pinnedSkills: Set<String>? = nil,
        select: Bool = true
    ) -> AssistantConversation {
        if select,
           let current = conversation(id: activeConversationID),
           current.messageCount == 0,
           activeSession.messages.isEmpty,
           !activeSession.isStreaming,
           targetScope == nil
        {
            return current
        }

        let conv = AssistantConversation(
            targetScope: targetScope ?? .all,
            pinnedSkillIDs: pinnedSkills ?? []
        )
        conversations.insert(conv, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
        if select {
            activeConversationID = conv.id
        }
        return conv
    }

    public func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeConversationID = id
        _ = session(for: id)
    }

    public func renameConversation(_ id: UUID, title: String, icon: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateMetadata(id) { conv in
            conv.title = trimmed
            if let icon, !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conv.icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            conv.shouldAutoRename = false
        }
    }

    public func togglePin(_ id: UUID) {
        updateMetadata(id) { conv in
            conv.isPinned.toggle()
        }
    }

    @discardableResult
    public func duplicateConversation(_ id: UUID, upToMessageID: UUID? = nil) -> AssistantConversation? {
        guard let source = conversation(id: id) else { return nil }
        var sourceMessages = session(for: id).messages
        if let cutoff = upToMessageID, let idx = sourceMessages.firstIndex(where: { $0.id == cutoff }) {
            sourceMessages = Array(sourceMessages[...idx])
        }
        let clonedMessages = sourceMessages.map { msg in
            AssistantChatMessage(
                id: UUID(),
                role: msg.role,
                text: msg.text,
                reasoning: msg.reasoning,
                thinkingDuration: msg.thinkingDuration,
                isPlaceholderText: msg.isPlaceholderText,
                turnGroupID: msg.turnGroupID,
                toolExecution: msg.toolExecution,
                attachments: msg.attachments,
                timestamp: msg.timestamp,
                modelLabel: msg.modelLabel
            )
        }
        let copyTitle = String(localized: "\(source.title) Copy")
        let cloned = AssistantConversation(
            title: copyTitle,
            icon: source.icon,
            shouldAutoRename: false,
            isPinned: false,
            lastMessagePreview: Self.previewText(from: clonedMessages),
            messageCount: clonedMessages.count,
            providerSelection: source.providerSelection,
            modelOverride: source.modelOverride,
            targetScope: source.targetScope,
            pinnedSkillIDs: source.pinnedSkillIDs,
            interactionMode: source.interactionMode,
            toolsEnabled: source.toolsEnabled
        )
        conversations.insert(cloned, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveMessages(clonedMessages, for: cloned.id)
        diskStore.saveIndex(conversations)
        sessions[cloned.id] = ConversationSession(conversationID: cloned.id, messages: clonedMessages, manager: self, remoteClient: remoteClient)
        activeConversationID = cloned.id
        return cloned
    }

    public func compressConversation(_ id: UUID) {
        guard let source = conversation(id: id) else { return }
        let sourceMessages = session(for: id).messages
        guard !sourceMessages.isEmpty else { return }

        guard case .custom(let providerId) = effectiveSelection(for: id),
              let config = resolvedProviderConfig(for: id, providerId: providerId)
        else {
            let digest = ConversationContextBuilder.buildOnDeviceHistoryDigest(from: sourceMessages, maxChars: 2_400)
            let fresh = AssistantConversation(
                title: source.title,
                icon: "🗜️",
                shouldAutoRename: false,
                lastMessagePreview: String(digest.prefix(120)),
                messageCount: 1,
                targetScope: source.targetScope,
                pinnedSkillIDs: source.pinnedSkillIDs
            )
            let msg = AssistantChatMessage(role: .assistant, text: digest)
            conversations.insert(fresh, at: 0)
            conversations = Self.sorted(conversations)
            diskStore.saveMessages([msg], for: fresh.id)
            diskStore.saveIndex(conversations)
            sessions[fresh.id] = ConversationSession(conversationID: fresh.id, messages: [msg], manager: self, remoteClient: remoteClient)
            activeConversationID = fresh.id
            return
        }

        let transcript = ConversationContextBuilder.exportMarkdown(conversation: source, messages: sourceMessages)
        let fresh = AssistantConversation(
            title: source.title,
            icon: "🗜️",
            shouldAutoRename: false,
            providerSelection: source.providerSelection,
            modelOverride: source.modelOverride,
            targetScope: source.targetScope,
            pinnedSkillIDs: source.pinnedSkillIDs,
            interactionMode: source.interactionMode,
            toolsEnabled: source.toolsEnabled
        )
        conversations.insert(fresh, at: 0)
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
        activeConversationID = fresh.id

        let newSession = session(for: fresh.id)
        let apiKey = providerStore.apiKey(for: config.id)
        newSession.runCompressionStream(
            sourceTitle: source.title,
            sourceTranscript: transcript,
            config: config,
            apiKey: apiKey
        )
    }

    public func deleteConversation(_ id: UUID) {
        sessions[id]?.stopGenerating()
        sessions.removeValue(forKey: id)
        executingConversationIDs.remove(id)
        conversations.removeAll { $0.id == id }
        diskStore.deleteMessages(for: id)

        if conversations.isEmpty {
            let fresh = AssistantConversation()
            conversations = [fresh]
            activeConversationID = fresh.id
        } else if activeConversationID == id {
            activeConversationID = conversations[0].id
        }
        diskStore.saveIndex(conversations)
        AssistantPlatformHooks.shared.onExecutingSessionsChanged?(executingConversationIDs)
    }

    public func eraseAllConversations() {
        for (_, sess) in sessions {
            sess.stopGenerating()
        }
        sessions.removeAll()
        executingConversationIDs.removeAll()
        diskStore.eraseAll()

        let fresh = AssistantConversation()
        conversations = [fresh]
        activeConversationID = fresh.id
        diskStore.saveIndex(conversations)
        AssistantPlatformHooks.shared.onExecutingSessionsChanged?(executingConversationIDs)
    }

    public func exportMarkdown(for id: UUID) -> String {
        guard let conv = conversation(id: id) else { return "" }
        let msgs = session(for: id).messages
        return ConversationContextBuilder.exportMarkdown(conversation: conv, messages: msgs)
    }

    public func searchConversationIDs(query: String) async -> Set<UUID> {
        await diskStore.matchingConversationIDs(query: query, in: conversations)
    }

    // MARK: - Internal Session Callbacks

    func persistMessages(_ messages: [AssistantChatMessage], for id: UUID) {
        diskStore.saveMessages(messages, for: id)
        updateMetadata(id, touchUpdatedAt: true) { conv in
            conv.messageCount = messages.count
            conv.lastMessagePreview = Self.previewText(from: messages)
        }
    }

    func markExecuting(_ id: UUID, running: Bool) {
        if running {
            executingConversationIDs.insert(id)
        } else {
            executingConversationIDs.remove(id)
        }
        AssistantPlatformHooks.shared.onExecutingSessionsChanged?(executingConversationIDs)
    }

    func applyAutoTitle(for id: UUID, title: String, emoji: String?) {
        guard let conv = conversation(id: id), conv.shouldAutoRename else { return }
        updateMetadata(id) { item in
            item.title = title
            if let emoji, !emoji.isEmpty {
                item.icon = emoji
            }
            item.shouldAutoRename = false
        }
    }

    func saveSummary(_ summary: String, messageCount: Int, for id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        updateMetadata(id) { item in
            item.summary = summary
            item.summaryMessageCount = messageCount
        }
    }

    func updateMetadata(_ id: UUID, touchUpdatedAt: Bool = false, _ mutate: (inout AssistantConversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[idx])
        if touchUpdatedAt {
            conversations[idx].updatedAt = Date()
        }
        conversations = Self.sorted(conversations)
        diskStore.saveIndex(conversations)
    }

    // MARK: - Scope, Mode & System Prompt

    public func sanitizedScope(_ scope: AssistantTargetScope) -> AssistantTargetScope {
        let validIDs = Set(TamioStore.shared.machineGroup.machines.map(\.id))
        let validGroups = Set(TamioStore.shared.machineGroup.machines.map(\.group).filter { !$0.isEmpty })
        switch scope {
        case .all:
            return .all
        case .group(let group):
            return validGroups.contains(group) ? .group(group) : .all
        case .hosts(let ids):
            let remaining = ids.intersection(validIDs)
            return remaining.isEmpty ? .all : .hosts(remaining)
        }
    }

    public func resolvedScopedMachines(for conversationID: UUID? = nil) -> [RDMachine] {
        let all = TamioStore.shared.machineGroup.machines
        let rawScope = (conversationID.flatMap { conversation(id: $0)?.targetScope }) ?? activeConversation.targetScope
        switch sanitizedScope(rawScope) {
        case .all:
            return all
        case .group(let group):
            return all.filter { $0.group == group }
        case .hosts(let ids):
            return all.filter { ids.contains($0.id) }
        }
    }

    public func interactionMode(for conversationID: UUID) -> AssistantInteractionMode {
        conversation(id: conversationID)?.effectiveMode ?? .agent
    }

    public func setInteractionMode(_ mode: AssistantInteractionMode, for conversationID: UUID) {
        let before = interactionMode(for: conversationID)
        updateMetadata(conversationID) { conv in
            conv.interactionMode = mode
        }
        if before != mode {
            maybeShowToolsChangeHint(
                conversationID: conversationID,
                toolsEnabledBefore: toolsEnabled(for: conversationID),
                toolsEnabledAfter: toolsEnabled(for: conversationID),
                selectionChanged: true
            )
        }
    }

    public func buildInstructions(for conversationID: UUID, compactForOnDevice: Bool) -> String {
        let conv = conversation(id: conversationID) ?? activeConversation
        let scope = sanitizedScope(conv.targetScope)
        let scoped = resolvedScopedMachines(for: conversationID)

        let scopeDescription: String
        switch scope {
        case .all:
            let names = scoped.prefix(20).map(\.name).joined(separator: ", ")
            scopeDescription = scoped.isEmpty
                ? "The user has not added any SSH servers yet."
                : "Active target scope: ALL servers (\(scoped.count) total: \(names)\(scoped.count > 20 ? ", …" : ""))."
        case .group(let group):
            let names = scoped.map(\.name).joined(separator: ", ")
            scopeDescription = "Active target scope: group \"\(group)\" (\(scoped.count) servers: \(names)). Default batch operations to this group unless the user names different servers."
        case .hosts:
            let names = scoped.map(\.name).joined(separator: ", ")
            scopeDescription = "Active target scope: selected \(scoped.count) server(s): \(names). Default batch operations to these exact hosts unless the user names different servers."
        }

        var prompt = conv.effectiveMode == .ask ? """
        You are Tamio AI in read-only **Ask** mode inside Tamio.
        \(scopeDescription)

        Rules:
        1. Reply in the same language the user writes in (e.g. Simplified Chinese if the user writes in Chinese).
        2. Answer directly from the user's question and any attached terminal output without executing commands on servers. You may suggest shell commands in fenced ```sh blocks for the user to insert or run manually.
        3. If answering accurately requires running a command or querying live server state, call `request_agent_mode` with a concise reason so the user can approve switching to Agent mode.
        4. Keep answers crisp and scannable.
        """ : """
        You are Tamio AI, the built-in SSH fleet management assistant inside Tamio.
        \(scopeDescription)

        Rules:
        1. Reply in the same language the user writes in (e.g. Simplified Chinese if the user writes in Chinese).
        2. Always query real data with tools before answering about servers, metrics, logs, services, or containers. Never fabricate hostnames, IP addresses, or command outputs.
        3. Every tool accepts a required `reason` field: write a crisp, natural phrase in the user's language explaining why you are making that call (shown directly in the activity banner and approval card).
        4. For batch operations across multiple servers, prefer a single `run_command` call with `targets` (`{"all": true}`, `{"group": "..."}`, `{"tag": "..."}`, or `{"hosts": [...]}`): Tamio executes across servers concurrently and asks the user to confirm once. For commands expected to take >30s, use `start_command` + `poll_command`.
        5. Every write or command execution (`run_command`, `start_command`, `run_snippet`, `add_*`, `update_*`, `remove_*`) prompts the user for approval in the composer and is recorded in server activity history. Always pass a concise `task` label (e.g. "Check disk usage", "Restart nginx") so related steps stay grouped in history.
        6. Never ask for or expose passwords or private keys; Tamio authenticates automatically with its saved credentials.
        7. Keep answers crisp and scannable: lead with a 1-sentence conclusion, then use clean Markdown tables or bullet lists for per-server results, highlighting anomalies and actionable next steps.
        8. If the user declines an approval card, acknowledge it calmly and do not retry the declined action without being asked.
        """

        if enabledToolGroups.contains(.skills) && conv.effectiveToolsEnabled {
            let skillFragment = skillStore.buildSystemPromptFragment(
                pinnedSkillIDs: conv.pinnedSkillIDs,
                compactForOnDevice: compactForOnDevice
            )
            if !skillFragment.isEmpty {
                prompt += "\n\n" + skillFragment
            }
        }

        if crossSessionMemoryEnabled, !compactForOnDevice {
            let recent = recentMemorySummaries(excluding: conversationID)
            if !recent.isEmpty {
                prompt += "\n\n" + recent
            }
        }
        return prompt
    }

    private func recentMemorySummaries(excluding currentID: UUID) -> String {
        let items = conversations
            .filter { $0.id != currentID && !($0.summary ?? "").isEmpty }
            .prefix(8)
        guard !items.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        var lines = ["Recent server ops conversation summaries (background context only):"]
        for (i, item) in items.enumerated() {
            lines.append("\(i + 1). [\(df.string(from: item.updatedAt))] \(item.title): \(item.summary ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func sorted(_ items: [AssistantConversation]) -> [AssistantConversation] {
        items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    private static func previewText(from messages: [AssistantChatMessage]) -> String {
        guard let last = messages.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.trimmedText.isEmpty && !$0.isPlaceholderText }) else {
            return ""
        }
        let cleaned = last.trimmedText.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 120 ? String(cleaned.prefix(120)) + "…" : cleaned
    }
}

/// Preserves macOS call-site compatibility.
public typealias MacServerAssistant = ServerAssistant

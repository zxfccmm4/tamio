//
//  AssistantConversation.swift
//  TamioAssistant
//
//  Conversation metadata, target server scope, interaction mode, and
//  FlowDown-inspired per-conversation tool toggle policy.
//

import Foundation
import TamioModule

// MARK: - Target Scope (Persisted per Conversation)

public nonisolated enum AssistantTargetScope: Codable, Equatable, Hashable, Sendable {
    case all
    case group(String)
    case hosts(Set<RDMachine.ID>)

    public var isFiltered: Bool {
        switch self {
        case .all: false
        case .group, .hosts: true
        }
    }
}

// MARK: - Interaction Mode

public nonisolated enum AssistantInteractionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case agent
    case ask

    public var localizedTitle: String {
        switch self {
        case .agent: String(localized: "Agent")
        case .ask: String(localized: "Ask")
        }
    }

    public var systemImage: String {
        switch self {
        case .agent: "bolt.shield"
        case .ask: "bubble.left.and.text.bubble.right"
        }
    }
}

// MARK: - Conversation Metadata

public nonisolated struct AssistantConversation: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var icon: String
    public var shouldAutoRename: Bool
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMessagePreview: String
    public var messageCount: Int
    public var providerSelection: AIActiveSelection?
    public var modelOverride: String?
    public var targetScope: AssistantTargetScope
    public var pinnedSkillIDs: Set<String>
    public var draftText: String
    public var summary: String?
    public var summaryMessageCount: Int
    public var interactionMode: AssistantInteractionMode?
    /// Per-conversation override for enabling tools (nil = follow global default `true`).
    public var toolsEnabled: Bool?

    public var effectiveMode: AssistantInteractionMode {
        interactionMode ?? .agent
    }

    public var effectiveToolsEnabled: Bool {
        toolsEnabled ?? true
    }

    public init(
        id: UUID = UUID(),
        title: String = String(localized: "New Conversation"),
        icon: String = "💬",
        shouldAutoRename: Bool = true,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessagePreview: String = "",
        messageCount: Int = 0,
        providerSelection: AIActiveSelection? = nil,
        modelOverride: String? = nil,
        targetScope: AssistantTargetScope = .all,
        pinnedSkillIDs: Set<String> = [],
        draftText: String = "",
        summary: String? = nil,
        summaryMessageCount: Int = 0,
        interactionMode: AssistantInteractionMode? = nil,
        toolsEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shouldAutoRename = shouldAutoRename
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
        self.messageCount = messageCount
        self.providerSelection = providerSelection
        self.modelOverride = modelOverride
        self.targetScope = targetScope
        self.pinnedSkillIDs = pinnedSkillIDs
        self.draftText = draftText
        self.summary = summary
        self.summaryMessageCount = summaryMessageCount
        self.interactionMode = interactionMode
        self.toolsEnabled = toolsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, icon, shouldAutoRename, isPinned, createdAt, updatedAt
        case lastMessagePreview, messageCount, providerSelection, modelOverride
        case targetScope, pinnedSkillIDs, draftText, summary, summaryMessageCount
        case interactionMode, toolsEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? String(localized: "New Conversation")
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "💬"
        shouldAutoRename = try c.decodeIfPresent(Bool.self, forKey: .shouldAutoRename) ?? true
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview) ?? ""
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        providerSelection = try c.decodeIfPresent(AIActiveSelection.self, forKey: .providerSelection)
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        targetScope = try c.decodeIfPresent(AssistantTargetScope.self, forKey: .targetScope) ?? .all
        pinnedSkillIDs = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedSkillIDs) ?? []
        draftText = try c.decodeIfPresent(String.self, forKey: .draftText) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryMessageCount = try c.decodeIfPresent(Int.self, forKey: .summaryMessageCount) ?? 0
        interactionMode = try c.decodeIfPresent(AssistantInteractionMode.self, forKey: .interactionMode)
        toolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .toolsEnabled)
    }
}

// MARK: - Tools Selection Policy (FlowDown Pattern)

/// Pure policy decisions behind the composer's Tools menu & cache-invalidation hint.
public nonisolated enum AssistantToolsSelectionPolicy {
    /// Picking any tool group turns the master tools toggle on; deselecting never turns it off.
    public static func toolsEnabledAfterSelection(
        selectionTurnedOn: Bool,
        toolsEnabled: Bool,
        modelSupportsTools: Bool
    ) -> Bool {
        if toolsEnabled { return true }
        return selectionTurnedOn && modelSupportsTools
    }

    /// Changing offered tools mid-conversation invalidates provider prompt caches;
    /// show a lightweight hint only when the conversation already has sent messages.
    public static func shouldHintToolsChange(
        toolsEnabledBefore: Bool,
        toolsEnabledAfter: Bool,
        selectionChanged: Bool,
        conversationHasMessages: Bool
    ) -> Bool {
        guard conversationHasMessages else { return false }
        if toolsEnabledBefore != toolsEnabledAfter { return true }
        return toolsEnabledAfter && selectionChanged
    }

    public static func conversationHasMessages(_ messages: [AssistantChatMessage]) -> Bool {
        messages.contains { $0.role == .user || $0.role == .assistant }
    }
}

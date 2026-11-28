//
//  ConversationHistoryGrouping.swift
//  TamioAssistantUI
//
//  FlowDown-style time-bucketed grouping for conversation history sidebars and
//  sheets: Pinned, Today, Yesterday, Previous 7 Days, Earlier.
//

import Foundation
import TamioAssistant

public struct AssistantHistorySection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let conversations: [AssistantConversation]

    public init(id: String, title: String, conversations: [AssistantConversation]) {
        self.id = id
        self.title = title
        self.conversations = conversations
    }
}

public enum AssistantHistoryGrouping {
    public static func sections(
        from conversations: [AssistantConversation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AssistantHistorySection] {
        var pinned: [AssistantConversation] = []
        var today: [AssistantConversation] = []
        var yesterday: [AssistantConversation] = []
        var lastSevenDays: [AssistantConversation] = []
        var earlier: [AssistantConversation] = []

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfSevenDays = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        for conv in conversations {
            if conv.isPinned {
                pinned.append(conv)
            } else if conv.updatedAt >= startOfToday {
                today.append(conv)
            } else if conv.updatedAt >= startOfYesterday {
                yesterday.append(conv)
            } else if conv.updatedAt >= startOfSevenDays {
                lastSevenDays.append(conv)
            } else {
                earlier.append(conv)
            }
        }

        var result: [AssistantHistorySection] = []
        if !pinned.isEmpty {
            result.append(AssistantHistorySection(id: "pinned", title: String(localized: "Pinned"), conversations: pinned))
        }
        if !today.isEmpty {
            result.append(AssistantHistorySection(id: "today", title: String(localized: "Today"), conversations: today))
        }
        if !yesterday.isEmpty {
            result.append(AssistantHistorySection(id: "yesterday", title: String(localized: "Yesterday"), conversations: yesterday))
        }
        if !lastSevenDays.isEmpty {
            result.append(AssistantHistorySection(id: "last7", title: String(localized: "Previous 7 Days"), conversations: lastSevenDays))
        }
        if !earlier.isEmpty {
            result.append(AssistantHistorySection(id: "earlier", title: String(localized: "Earlier"), conversations: earlier))
        }
        return result
    }
}

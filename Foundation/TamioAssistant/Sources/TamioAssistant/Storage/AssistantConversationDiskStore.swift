//
//  AssistantConversationDiskStore.swift
//  TamioAssistant
//
//  Two-tier atomic disk persistence (index.json + per-conversation JSON) with
//  background full-text search across titles, summaries, messages, tool reasons,
//  and target hosts. Uses the existing `TamioAssistant/` directory layout so
//  conversations saved by earlier builds load seamlessly.
//

import Foundation

public nonisolated final class AssistantConversationDiskStore: Sendable {
    public static let shared = AssistantConversationDiskStore()

    private let baseDirectory: URL
    private let conversationsDirectory: URL
    private let indexURL: URL
    private let ioQueue = DispatchQueue(label: "sb.moe.tamio.assistant.disk", qos: .utility)

    public init(baseDirectory: URL? = nil) {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "sb.moe.tamio"
            base = support
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("TamioAssistant", isDirectory: true)
        }
        self.baseDirectory = base
        self.conversationsDirectory = base.appendingPathComponent("conversations", isDirectory: true)
        self.indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
    }

    private func messagesURL(for id: UUID) -> URL {
        conversationsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    public func loadIndex() -> [AssistantConversation] {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: indexURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AssistantConversation].self, from: data)) ?? []
        }
    }

    public func saveIndex(_ conversations: [AssistantConversation]) {
        ioQueue.async { [indexURL, conversationsDirectory] in
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(conversations) else { return }
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    public func loadMessages(for id: UUID) -> [AssistantChatMessage] {
        ioQueue.sync {
            let url = messagesURL(for: id)
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([AssistantChatMessage].self, from: data)) ?? []
        }
    }

    public func saveMessages(_ messages: [AssistantChatMessage], for id: UUID) {
        let url = messagesURL(for: id)
        ioQueue.async { [conversationsDirectory] in
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(messages) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    public func deleteMessages(for id: UUID) {
        let url = messagesURL(for: id)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func eraseAll() {
        ioQueue.async { [indexURL, conversationsDirectory] in
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: conversationsDirectory)
            try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Searches titles, previews, summaries, message prose, tool names, reasons, and hosts.
    public func matchingConversationIDs(query: String, in conversations: [AssistantConversation]) async -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Set(conversations.map(\.id)) }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                var matches = Set<UUID>()
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                for conv in conversations {
                    let meta = "\(conv.title) \(conv.lastMessagePreview) \(conv.summary ?? "")".lowercased()
                    if tokens.allSatisfy({ meta.contains($0) }) {
                        matches.insert(conv.id)
                        continue
                    }
                    let url = self.messagesURL(for: conv.id)
                    if let data = try? Data(contentsOf: url),
                       let msgs = try? decoder.decode([AssistantChatMessage].self, from: data)
                    {
                        let haystack = msgs.map {
                            "\($0.text) \($0.toolExecution?.toolName ?? "") \($0.toolExecution?.reason ?? "") \($0.toolExecution?.targetHosts.joined(separator: " ") ?? "")"
                        }
                        .joined(separator: "\n")
                        .lowercased()
                        if tokens.allSatisfy({ haystack.contains($0) }) {
                            matches.insert(conv.id)
                        }
                    }
                }
                continuation.resume(returning: matches)
            }
        }
    }
}

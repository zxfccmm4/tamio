//
//  AssistantAttachment.swift
//  TamioAssistant
//
//  First-class composer and message attachments (terminal snapshots, text/log
//  files, and images) inspired by FlowDown's RichEditor attachment model.
//

import Foundation

public nonisolated struct AssistantAttachment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case terminalSnapshot
        case textFile
        case image
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    /// Plain text representation (redacted terminal output, log file content, etc.).
    public var textContent: String
    /// Optional binary payload (PNG/JPEG data for image attachments).
    public var imageData: Data?
    /// MIME type for image attachments (e.g. "image/png", "image/jpeg").
    public var mimeType: String?
    /// Optional badge metadata (e.g. host name or secret redaction count).
    public var subtitle: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        textContent: String = "",
        imageData: Data? = nil,
        mimeType: String? = nil,
        subtitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.textContent = textContent
        self.imageData = imageData
        self.mimeType = mimeType
        self.subtitle = subtitle
    }

    public var systemImage: String {
        switch kind {
        case .terminalSnapshot: "terminal"
        case .textFile: "doc.text"
        case .image: "photo"
        }
    }

    /// Formats a text/terminal attachment into a fenced block for LLM prompt injection.
    public func formattedPromptBlock() -> String {
        let trimmed = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let label = subtitle.map { "\($0) · \(name)" } ?? name
        switch kind {
        case .terminalSnapshot:
            return "[Terminal Output: \(label)]\n```\n\(trimmed)\n```"
        case .textFile:
            return "[File: \(label)]\n```\n\(trimmed)\n```"
        case .image:
            return "[Image: \(label)]"
        }
    }
}

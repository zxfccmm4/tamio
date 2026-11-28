//
//  AssistantProviders.swift
//  TamioAssistant
//
//  Cross-platform multi-provider AI configuration and Keychain-backed
//  credential store supporting on-device Apple Intelligence, Private Cloud
//  Compute, OpenAI-compatible, and Anthropic Messages remote providers.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Keychain
import Observation
import SwiftUI

// MARK: - Apple Intelligence Availability

public enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    case requiresNewerOS
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unavailable

    public static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return .notEnabled
                case .modelNotReady:
                    return .modelNotReady
                @unknown default:
                    return .unavailable
                }
            }
        }
        #endif
        return .requiresNewerOS
    }

    public var localizedDescription: String {
        switch self {
        case .available:
            return String(localized: "Runs on device with no API key required.")
        case .requiresNewerOS:
            #if os(macOS)
            return String(localized: "Requires macOS 26 or later. Configure a remote AI provider instead.")
            #else
            return String(localized: "Requires iOS 26 or later. Configure a remote AI provider instead.")
            #endif
        case .deviceNotEligible:
            return String(localized: "This device does not support Apple Intelligence. Configure a remote AI provider instead.")
        case .notEnabled:
            return String(localized: "Enable Apple Intelligence in Settings, or configure a remote AI provider.")
        case .modelNotReady:
            return String(localized: "Apple Intelligence model is downloading. You can also configure a remote AI provider.")
        case .unavailable:
            return String(localized: "Apple Intelligence is currently unavailable. Configure a remote AI provider instead.")
        }
    }
}

// MARK: - Apple Intelligence Private Cloud Compute Availability

private enum PrivateCloudComputeEntitlement {
    static let key = "com.apple.developer.private-cloud-compute"

    static let isGranted: Bool = {
        #if os(macOS)
        let ext = "provisionprofile"
        #else
        let ext = "mobileprovision"
        #endif
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: ext),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else {
            return false
        }
        let xmlString = String(text[start.lowerBound ..< end.upperBound])
        guard let plistData = xmlString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return false
        }
        return (entitlements[key] as? Bool) == true
    }()
}

public enum ApplePrivateCloudComputeStatus: Equatable, Sendable {
    case available
    case missingEntitlement
    case requiresNewerOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case systemNotReady
    case unavailable

    public static var current: ApplePrivateCloudComputeStatus {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27.0, iOS 27.0, *) {
            guard PrivateCloudComputeEntitlement.isGranted else {
                return .missingEntitlement
            }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .deviceNotEligible
                case .systemNotReady:
                    if SystemLanguageModel.default.availability == .unavailable(.appleIntelligenceNotEnabled) {
                        return .appleIntelligenceNotEnabled
                    }
                    return .systemNotReady
                @unknown default:
                    return .unavailable
                }
            }
        }
        #endif
        return .requiresNewerOS
    }

    public var isEligibleHardwareAndOS: Bool {
        switch self {
        case .requiresNewerOS, .deviceNotEligible, .missingEntitlement:
            return false
        default:
            return true
        }
    }

    public var localizedDescription: String {
        switch self {
        case .available:
            return String(localized: "Runs on Apple's Private Cloud Compute with end-to-end privacy and no API key required.")
        case .missingEntitlement:
            return String(localized: "This build is signed without Apple's managed Private Cloud Compute entitlement.")
        case .requiresNewerOS:
            #if os(macOS)
            return String(localized: "Requires macOS 27 or later with Private Cloud Compute entitlement.")
            #else
            return String(localized: "Requires iOS 27 or later with Private Cloud Compute entitlement.")
            #endif
        case .deviceNotEligible:
            return String(localized: "This device does not support Apple Intelligence Private Cloud Compute.")
        case .appleIntelligenceNotEnabled:
            return String(localized: "Turn on Apple Intelligence in System Settings to use Private Cloud Compute.")
        case .systemNotReady:
            return String(localized: "Private Cloud Compute is not ready yet. Check your network, iCloud sign-in, or app entitlement.")
        case .unavailable:
            return String(localized: "Apple Intelligence Private Cloud Compute is currently unavailable.")
        }
    }
}

// MARK: - Wire Format & Provider Kind

public nonisolated enum AIWireFormat: String, Codable, Hashable, Sendable {
    case openAIChatCompletions
    case anthropicMessages
}

public nonisolated enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case openRouter
    case magpie
    case xAI
    case ollama
    case openAICompatible
    case anthropicCompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .magpie: "Magpie"
        case .xAI: "xAI Grok"
        case .ollama: String(localized: "Ollama (Local)")
        case .openAICompatible: String(localized: "OpenAI Compatible")
        case .anthropicCompatible: String(localized: "Anthropic Compatible")
        }
    }

    public var shortDescription: String {
        switch self {
        case .openAI: "GPT-4.1 · o4-mini"
        case .anthropic: "Claude Sonnet · Haiku"
        case .gemini: "Gemini 2.5 Flash / Pro"
        case .deepSeek: "DeepSeek Chat / Reasoner"
        case .openRouter: String(localized: "Multi-model router")
        case .magpie: String(localized: "Local AI gateway")
        case .xAI: "Grok 3"
        case .ollama: String(localized: "LAN / self-hosted")
        case .openAICompatible: String(localized: "Custom /v1 endpoint")
        case .anthropicCompatible: String(localized: "Custom Messages API")
        }
    }

    public var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .anthropic: "brain.head.profile"
        case .gemini: "wand.and.stars"
        case .deepSeek: "magnifyingglass.circle"
        case .openRouter: "network"
        case .magpie: "bird"
        case .xAI: "bolt.circle"
        case .ollama: "desktopcomputer"
        case .openAICompatible: "server.rack"
        case .anthropicCompatible: "slider.horizontal.3"
        }
    }

    public var tintColor: Color {
        switch self {
        case .openAI: .green
        case .anthropic: .orange
        case .gemini: .blue
        case .deepSeek: .indigo
        case .openRouter: .purple
        case .magpie: .teal
        case .xAI: .primary
        case .ollama: .secondary
        case .openAICompatible: .cyan
        case .anthropicCompatible: .pink
        }
    }

    public var protocolBadgeText: String {
        switch wireFormat {
        case .openAIChatCompletions: "OpenAI API"
        case .anthropicMessages: "Anthropic API"
        }
    }

    public var wireFormat: AIWireFormat {
        switch self {
        case .anthropic, .anthropicCompatible:
            return .anthropicMessages
        case .openAI, .gemini, .deepSeek, .openRouter, .magpie, .xAI, .ollama, .openAICompatible:
            return .openAIChatCompletions
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .magpie: "http://127.0.0.1:3425/v1"
        case .xAI: "https://api.x.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .openAICompatible: "https://api.openai.com/v1"
        case .anthropicCompatible: "https://api.anthropic.com/v1"
        }
    }

    public var defaultAppendV1Suffix: Bool {
        switch self {
        case .gemini, .openRouter: false
        default: true
        }
    }

    public var requiresAPIKey: Bool {
        self != .ollama && self != .magpie
    }

    public var defaultAuthToken: String? {
        switch self {
        case .magpie: "magpie-tamio"
        default: nil
        }
    }

    public var recommendedModels: [String] {
        switch self {
        case .openAI:
            ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o", "o4-mini"]
        case .anthropic:
            ["claude-sonnet-4-20250514", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .gemini:
            ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .deepSeek:
            ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter:
            ["anthropic/claude-sonnet-4", "openai/gpt-4.1-mini", "google/gemini-2.5-flash", "deepseek/deepseek-chat-v3-0324"]
        case .magpie:
            ["anthropic/claude-sonnet-4-6", "openai/gpt-5.4", "google/gemini-2.5-pro", "deepseek/deepseek-chat"]
        case .xAI:
            ["grok-3-mini", "grok-3", "grok-2-latest"]
        case .ollama:
            ["qwen2.5:14b", "llama3.3", "deepseek-r1:14b", "mistral"]
        case .openAICompatible:
            ["gpt-4.1-mini", "gpt-4o-mini", "deepseek-chat"]
        case .anthropicCompatible:
            ["claude-sonnet-4-20250514", "claude-3-5-haiku-latest"]
        }
    }

    public var defaultModel: String {
        recommendedModels.first ?? ""
    }
}

// MARK: - Custom Provider Icon & Config

public nonisolated struct AIProviderCustomIcon: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case brandAsset
        case symbol
    }

    public var kind: Kind
    public var value: String
    public var tintName: String

    public init(kind: Kind, value: String, tintName: String = "accent") {
        self.kind = kind
        self.value = value
        self.tintName = tintName
    }
}

public nonisolated struct AIProviderConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    public var appendV1Suffix: Bool
    public var model: String
    public var availableModels: [String]
    public var customUserAgent: String?
    public var customIcon: AIProviderCustomIcon?
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: AIProviderKind,
        baseURL: String? = nil,
        appendV1Suffix: Bool? = nil,
        model: String? = nil,
        availableModels: [String]? = nil,
        customUserAgent: String? = nil,
        customIcon: AIProviderCustomIcon? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.appendV1Suffix = appendV1Suffix ?? kind.defaultAppendV1Suffix
        self.model = model ?? kind.defaultModel
        self.availableModels = availableModels ?? kind.recommendedModels
        self.customUserAgent = customUserAgent
        self.customIcon = customIcon
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public var resolvedBaseURL: String {
        AIURLBuilder.normalizedBaseURL(baseURL, appendV1: appendV1Suffix)
    }

    public var mergedModels: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in ([model] + availableModels + kind.recommendedModels) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

public nonisolated enum AIActiveSelection: Codable, Equatable, Hashable, Sendable {
    case appleIntelligence
    case applePrivateCloudCompute
    case custom(providerId: String)
}

// MARK: - URL Builder & Test Result

public nonisolated enum AIURLBuilder {
    public static func normalizedBaseURL(_ raw: String, appendV1: Bool) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if !trimmed.isEmpty, !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard appendV1, !trimmed.isEmpty else { return trimmed }

        if let url = URL(string: trimmed) {
            let path = url.path.lowercased()
            let alreadyVersioned = path.hasSuffix("/v1")
                || path.hasSuffix("/v1beta")
                || path.hasSuffix("/v1beta/openai")
                || path.hasSuffix("/v2")
                || path.hasSuffix("/v3")
                || path.hasSuffix("/v4")
                || path.hasSuffix("/chat/completions")
                || path.hasSuffix("/messages")
            if !alreadyVersioned {
                return trimmed + "/v1"
            }
        }
        return trimmed
    }

    public static func endpointURL(baseURL: String, appendV1: Bool, path: String) -> URL? {
        let base = normalizedBaseURL(baseURL, appendV1: appendV1)
        guard !base.isEmpty else { return nil }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if base.lowercased().hasSuffix("/" + cleanPath.lowercased()) {
            return URL(string: base)
        }
        return URL(string: "\(base)/\(cleanPath)")
    }
}

public nonisolated struct AIProviderTestResult: Equatable, Sendable {
    public let succeeded: Bool
    public let latencyMs: Int
    public let message: String
    public let discoveredModels: [String]

    public init(succeeded: Bool, latencyMs: Int, message: String, discoveredModels: [String]) {
        self.succeeded = succeeded
        self.latencyMs = latencyMs
        self.message = message
        self.discoveredModels = discoveredModels
    }
}

// MARK: - Provider Store

@MainActor
@Observable
public final class AIProviderStore {
    public static let shared = AIProviderStore()

    private static let providersStorageKey = "sb.moe.tamio.ai.providers.v1"
    private static let activeSelectionStorageKey = "sb.moe.tamio.ai.activeSelection.v1"
    private static let pccEnabledStorageKey = "sb.moe.tamio.ai.pccEnabled.v1"
    private static let keychainService = "sb.moe.tamio.ai.apikeys"

    public private(set) var providers: [AIProviderConfig] = []
    public private(set) var activeSelection: AIActiveSelection = .appleIntelligence
    public var privateCloudComputeEnabled: Bool = true {
        didSet {
            defaults.set(privateCloudComputeEnabled, forKey: Self.pccEnabledStorageKey)
        }
    }

    private let defaults: UserDefaults
    private let keychain: Keychain
    private let session: URLSession

    public init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.keychain = Keychain(service: Self.keychainService)
        self.session = session
        if let storedPCC = defaults.object(forKey: Self.pccEnabledStorageKey) as? Bool {
            self.privateCloudComputeEnabled = storedPCC
        }
        loadFromDisk()
    }

    public var enabledProviders: [AIProviderConfig] {
        providers.filter(\.isEnabled)
    }

    public func provider(id: String) -> AIProviderConfig? {
        providers.first { $0.id == id }
    }

    public func effectiveSelection(
        appleIntelligenceAvailable: Bool,
        pccAvailable: Bool = ApplePrivateCloudComputeStatus.current == .available
    ) -> AIActiveSelection {
        let pccUsable = privateCloudComputeEnabled && pccAvailable
        switch activeSelection {
        case .custom(let id):
            if providers.contains(where: { $0.id == id && $0.isEnabled }) {
                return .custom(providerId: id)
            }
            if pccUsable { return .applePrivateCloudCompute }
            if appleIntelligenceAvailable { return .appleIntelligence }
            if let fallback = enabledProviders.first { return .custom(providerId: fallback.id) }
            return .appleIntelligence
        case .applePrivateCloudCompute:
            if pccUsable { return .applePrivateCloudCompute }
            if appleIntelligenceAvailable { return .appleIntelligence }
            if let fallback = enabledProviders.first { return .custom(providerId: fallback.id) }
            return .applePrivateCloudCompute
        case .appleIntelligence:
            if appleIntelligenceAvailable { return .appleIntelligence }
            if pccUsable { return .applePrivateCloudCompute }
            if let fallback = enabledProviders.first { return .custom(providerId: fallback.id) }
            return .appleIntelligence
        }
    }

    public func activeDisplayName(appleIntelligenceAvailable: Bool) -> String {
        switch effectiveSelection(appleIntelligenceAvailable: appleIntelligenceAvailable) {
        case .appleIntelligence:
            return String(localized: "Apple Intelligence")
        case .applePrivateCloudCompute:
            return String(localized: "Apple Intelligence (PCC)")
        case .custom(let id):
            return provider(id: id)?.name ?? String(localized: "Custom AI")
        }
    }

    public func activeModelSummary(appleIntelligenceAvailable: Bool) -> String {
        switch effectiveSelection(appleIntelligenceAvailable: appleIntelligenceAvailable) {
        case .appleIntelligence:
            return String(localized: "On-Device")
        case .applePrivateCloudCompute:
            return String(localized: "Private Cloud Compute")
        case .custom(let id):
            return provider(id: id)?.model ?? ""
        }
    }

    public func apiKey(for providerId: String) -> String? {
        try? keychain.getString(providerId)
    }

    public func hasCredential(for config: AIProviderConfig) -> Bool {
        if !config.kind.requiresAPIKey { return true }
        guard let key = apiKey(for: config.id) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func addProvider(_ config: AIProviderConfig, apiKey: String?, makeActive: Bool = true) throws {
        var clean = config
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.baseURL = clean.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.model = clean.model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try keychain.set(key, key: clean.id)
        }
        providers.append(clean)
        if makeActive {
            activeSelection = .custom(providerId: clean.id)
        }
        persist()
    }

    public func updateProvider(_ config: AIProviderConfig, apiKey: String?) throws {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        var clean = config
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.baseURL = clean.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.model = clean.model.trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = apiKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try? keychain.remove(clean.id)
            } else {
                try keychain.set(trimmed, key: clean.id)
            }
        }
        providers[index] = clean
        if !clean.isEnabled, activeSelection == .custom(providerId: clean.id) {
            activeSelection = enabledProviders.first.map { .custom(providerId: $0.id) } ?? .appleIntelligence
        }
        persist()
    }

    public func deleteProvider(id: String) {
        providers.removeAll { $0.id == id }
        try? keychain.remove(id)
        if activeSelection == .custom(providerId: id) {
            activeSelection = enabledProviders.first.map { .custom(providerId: $0.id) } ?? .appleIntelligence
        }
        persist()
    }

    public func selectActive(_ selection: AIActiveSelection) {
        activeSelection = selection
        persist()
    }

    public func setModel(_ model: String, for providerId: String) {
        guard let index = providers.firstIndex(where: { $0.id == providerId }) else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        providers[index].model = trimmed
        if !providers[index].availableModels.contains(trimmed) {
            providers[index].availableModels.insert(trimmed, at: 0)
        }
        persist()
    }

    public func importFromBackup(
        providers imported: [AIProviderConfig],
        apiKeys: [String: String],
        activeSelection importedSelection: AIActiveSelection?,
        replaceExisting: Bool
    ) {
        if replaceExisting {
            for existing in providers {
                try? keychain.remove(existing.id)
            }
            providers = imported
        } else {
            for item in imported {
                if let idx = providers.firstIndex(where: { $0.id == item.id }) {
                    providers[idx] = item
                } else {
                    providers.append(item)
                }
            }
        }
        for (providerID, rawKey) in apiKeys {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? keychain.set(trimmed, key: providerID)
            }
        }
        if let importedSelection {
            switch importedSelection {
            case .appleIntelligence:
                if replaceExisting { activeSelection = .appleIntelligence }
            case .applePrivateCloudCompute:
                if replaceExisting { activeSelection = .applePrivateCloudCompute }
            case .custom(let id):
                if providers.contains(where: { $0.id == id && $0.isEnabled }) {
                    activeSelection = .custom(providerId: id)
                }
            }
        }
        persist()
    }

    public func fetchModels(for config: AIProviderConfig, apiKeyOverride: String? = nil) async throws -> [String] {
        let effectiveKey = (apiKeyOverride ?? apiKey(for: config.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "models"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyAuthHeaders(to: &request, config: config, apiKey: effectiveKey)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.httpError(statusCode: http.statusCode, message: Self.extractErrorMessage(from: body))
        }

        let models = Self.parseModelIDs(from: data)
        if let idx = providers.firstIndex(where: { $0.id == config.id }), !models.isEmpty {
            providers[idx].availableModels = models
            persist()
        }
        return models
    }

    public func testConnection(for config: AIProviderConfig, apiKeyOverride: String? = nil) async -> AIProviderTestResult {
        let start = ContinuousClock.now
        let effectiveKey = (apiKeyOverride ?? apiKey(for: config.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if config.kind.requiresAPIKey, (effectiveKey ?? "").isEmpty {
            return AIProviderTestResult(
                succeeded: false,
                latencyMs: 0,
                message: String(localized: "Please enter an API key first."),
                discoveredModels: []
            )
        }

        do {
            let models = try await fetchModels(for: config, apiKeyOverride: effectiveKey)
            let ms = elapsedMilliseconds(since: start)
            let msg = models.isEmpty
                ? String(localized: "Connected")
                : String(localized: "Connected · \(models.count) models available")
            return AIProviderTestResult(succeeded: true, latencyMs: ms, message: msg, discoveredModels: models)
        } catch {
            if config.kind.wireFormat == .anthropicMessages {
                do {
                    try await pingAnthropicEndpoint(config: config, apiKey: effectiveKey)
                    let ms = elapsedMilliseconds(since: start)
                    return AIProviderTestResult(
                        succeeded: true,
                        latencyMs: ms,
                        message: String(localized: "Connected"),
                        discoveredModels: []
                    )
                } catch {
                    return AIProviderTestResult(
                        succeeded: false,
                        latencyMs: elapsedMilliseconds(since: start),
                        message: error.localizedDescription,
                        discoveredModels: []
                    )
                }
            }
            return AIProviderTestResult(
                succeeded: false,
                latencyMs: elapsedMilliseconds(since: start),
                message: error.localizedDescription,
                discoveredModels: []
            )
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func pingAnthropicEndpoint(config: AIProviderConfig, apiKey: String?) async throws {
        guard let url = AIURLBuilder.endpointURL(
            baseURL: config.baseURL,
            appendV1: config.appendV1Suffix,
            path: "messages"
        ) else {
            throw RemoteLLMError.invalidURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, config: config, apiKey: apiKey)

        let body: [String: Any] = [
            "model": config.model.isEmpty ? config.kind.defaultModel : config.model,
            "max_tokens": 8,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLLMError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RemoteLLMError.httpError(statusCode: http.statusCode, message: Self.extractErrorMessage(from: text))
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, config: AIProviderConfig, apiKey: String?) {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = (trimmedKey?.isEmpty == false) ? trimmedKey : config.kind.defaultAuthToken

        switch config.kind.wireFormat {
        case .openAIChatCompletions:
            if let token = effectiveToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            if let token = effectiveToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let ua = config.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    public nonisolated static func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let items = json["data"] as? [[String: Any]] {
            return items.compactMap { $0["id"] as? String }.sorted()
        }
        if let items = json["models"] as? [[String: Any]] {
            return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
        }
        return []
    }

    public nonisolated static func extractErrorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String, !msg.isEmpty
            {
                return msg
            }
            if let msg = json["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }

    private func loadFromDisk() {
        if let data = defaults.data(forKey: Self.providersStorageKey),
           let decoded = try? JSONDecoder().decode([AIProviderConfig].self, from: data)
        {
            providers = decoded
        }
        if let data = defaults.data(forKey: Self.activeSelectionStorageKey),
           let decoded = try? JSONDecoder().decode(AIActiveSelection.self, from: data)
        {
            activeSelection = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Self.providersStorageKey)
        }
        if let data = try? JSONEncoder().encode(activeSelection) {
            defaults.set(data, forKey: Self.activeSelectionStorageKey)
        }
    }
}

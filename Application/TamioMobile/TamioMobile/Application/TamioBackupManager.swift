//
//  TamioBackupManager.swift
//  TamioMobile
//
//  One-click Export & Import for transferring all Tamio servers, SSH
//  identities, snippets, port forwards, known hosts, AI providers (with
//  Keychain API keys), and custom ops skills between devices.
//  Supports both AES-256-GCM passphrase-encrypted and plain JSON bundles.
//

import CryptoKit
import Foundation
import Security
import SwiftUI
import TamioAssistant
import TamioModule
import UniformTypeIdentifiers

// MARK: - Backup Options & Models

struct TamioBackupOptions: Equatable, Sendable {
    var includeServersAndCredentials = true
    var includeSnippetsAndForwards = true
    var includeAIProvidersAndKeys = true
    var includeSkillsAndPreferences = true

    var hasAnySelection: Bool {
        includeServersAndCredentials
            || includeSnippetsAndForwards
            || includeAIProvidersAndKeys
            || includeSkillsAndPreferences
    }

    var includesSecrets: Bool {
        includeServersAndCredentials || includeAIProvidersAndKeys
    }
}

enum TamioBackupImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge
    case replace

    var id: String { rawValue }
}

nonisolated struct TamioBackupPayload: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var exportedAt: Date = Date()
    var appVersion: String = ""

    var servers: [RDMachine] = []
    var identities: [RDIdentity] = []
    var snippets: [RDSnippet] = []
    var portForwards: [RDPortForward] = []
    var knownHosts: [KnownHostEntry] = []

    var aiProviders: [AIProviderConfig] = []
    var aiAPIKeys: [String: String] = [:]
    var activeAISelection: AIActiveSelection?
    var customSkills: [ServerOpsSkill] = []
    var disabledBuiltInSkillIDs: [String] = []
    var aiContextTokenBudget: Int?
    var aiCrossSessionMemoryEnabled: Bool?
}

/// Top-level file wrapper written to `.tamiobackup` / `.json`.
nonisolated struct TamioBackupEnvelope: Codable, Sendable {
    static let magic = "sb.moe.tamio.backup"
    static let currentFormatVersion = 1

    var format: String = magic
    var version: Int = currentFormatVersion
    var encrypted: Bool
    var exportedAt: Date = Date()

    // Present when encrypted == true (PBKDF2-HMAC-SHA256 + AES-256-GCM)
    var salt: Data?
    var rounds: Int?
    var ciphertext: Data?

    // Present when encrypted == false
    var payload: TamioBackupPayload?
}

struct TamioBackupPreview: Sendable {
    let exportedAt: Date
    let appVersion: String
    let wasEncrypted: Bool
    let payload: TamioBackupPayload

    var serverCount: Int { payload.servers.count }
    var sharedIdentityCount: Int { payload.identities.filter { !$0.isPrivate }.count }
    var snippetCount: Int { payload.snippets.count }
    var portForwardCount: Int { payload.portForwards.count }
    var aiProviderCount: Int { payload.aiProviders.count }
    var aiKeyCount: Int { payload.aiAPIKeys.count }
    var customSkillCount: Int { payload.customSkills.count }
}

enum TamioBackupInspectResult: Sendable {
    case ready(TamioBackupPreview)
    case needsPassphrase(TamioBackupEnvelope)
}

enum TamioBackupError: LocalizedError, Sendable {
    case emptySelection
    case passphraseTooShort
    case invalidFile
    case wrongPassphrase
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return String(localized: "Select at least one category to export.")
        case .passphraseTooShort:
            return String(localized: "Passphrase must be at least 4 characters.")
        case .invalidFile:
            return String(localized: "This file is not a valid Tamio backup.")
        case .wrongPassphrase:
            return String(localized: "Incorrect passphrase. Unable to decrypt this backup.")
        case .encryptionFailed:
            return String(localized: "Failed to encrypt backup data.")
        }
    }
}

// MARK: - SwiftUI FileDocument Wrapper

struct TamioBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Backup Manager

@MainActor
enum TamioBackupManager {
    private static let pbkdf2Rounds = 100_000

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Tamio-Backup-\(formatter.string(from: Date())).tamiobackup.json"
    }

    /// Reads a user-picked or AirDropped backup file safely across security scopes
    /// and iCloud Drive file coordination.
    static func readBackupData(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var readResult: Result<Data, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                readResult = .success(try Data(contentsOf: coordinatedURL))
            } catch {
                readResult = .failure(error)
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        switch readResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        case nil:
            return try Data(contentsOf: url)
        }
    }

    static func makeExportData(
        options: TamioBackupOptions,
        passphrase: String?
    ) throws -> Data {
        guard options.hasAnySelection else { throw TamioBackupError.emptySelection }

        let store = TamioStore.shared
        let providerStore = AIProviderStore.shared
        let skillStore = ServerOpsSkillStore.shared
        let assistant = ServerAssistant.shared

        var payload = TamioBackupPayload(
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1"
        )

        if options.includeServersAndCredentials {
            payload.servers = store.machineGroup.machines
            payload.identities = store.identityGroup.identities
            payload.knownHosts = KnownHosts.shared.syncEntries()
        }

        if options.includeSnippetsAndForwards {
            payload.snippets = store.snippetGroup.snippets
            payload.portForwards = store.portForwardGroup.forwards
        }

        if options.includeAIProvidersAndKeys {
            payload.aiProviders = providerStore.providers
            payload.activeAISelection = providerStore.activeSelection
            var keys: [String: String] = [:]
            for provider in providerStore.providers {
                if let key = providerStore.apiKey(for: provider.id), !key.isEmpty {
                    keys[provider.id] = key
                }
            }
            payload.aiAPIKeys = keys
        }

        if options.includeSkillsAndPreferences {
            payload.customSkills = skillStore.skills.filter { !$0.isBuiltIn }
            payload.disabledBuiltInSkillIDs = skillStore.skills.filter { $0.isBuiltIn && !$0.isEnabled }.map(\.id)
            payload.aiContextTokenBudget = assistant.contextTokenBudget
            payload.aiCrossSessionMemoryEnabled = assistant.crossSessionMemoryEnabled
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let envelope: TamioBackupEnvelope
        if let passphrase {
            let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { throw TamioBackupError.passphraseTooShort }

            let plain = try encoder.encode(payload)
            let salt = randomSalt(count: 16)
            guard let key = deriveKey(passphrase: trimmed, salt: salt, rounds: pbkdf2Rounds),
                  let sealed = try? CryptoKit.AES.GCM.seal(plain, using: key).combined
            else {
                throw TamioBackupError.encryptionFailed
            }
            envelope = TamioBackupEnvelope(
                encrypted: true,
                exportedAt: payload.exportedAt,
                salt: salt,
                rounds: pbkdf2Rounds,
                ciphertext: sealed,
                payload: nil
            )
        } else {
            envelope = TamioBackupEnvelope(
                encrypted: false,
                exportedAt: payload.exportedAt,
                payload: payload
            )
        }

        return try encoder.encode(envelope)
    }

    static func inspect(data: Data) throws -> TamioBackupInspectResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(TamioBackupEnvelope.self, from: data),
           envelope.format == TamioBackupEnvelope.magic
        {
            if envelope.encrypted {
                guard envelope.salt != nil, envelope.ciphertext != nil else {
                    throw TamioBackupError.invalidFile
                }
                return .needsPassphrase(envelope)
            }
            guard let payload = envelope.payload else { throw TamioBackupError.invalidFile }
            return .ready(
                TamioBackupPreview(
                    exportedAt: envelope.exportedAt,
                    appVersion: payload.appVersion,
                    wasEncrypted: false,
                    payload: payload
                )
            )
        }

        // Also accept raw un-enveloped TamioBackupPayload JSON if edited manually.
        if let rawPayload = try? decoder.decode(TamioBackupPayload.self, from: data) {
            return .ready(
                TamioBackupPreview(
                    exportedAt: rawPayload.exportedAt,
                    appVersion: rawPayload.appVersion,
                    wasEncrypted: false,
                    payload: rawPayload
                )
            )
        }

        throw TamioBackupError.invalidFile
    }

    static func decrypt(envelope: TamioBackupEnvelope, passphrase: String) throws -> TamioBackupPreview {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let salt = envelope.salt,
              let ciphertext = envelope.ciphertext
        else {
            throw TamioBackupError.invalidFile
        }
        let rounds = max(10_000, min(envelope.rounds ?? pbkdf2Rounds, 500_000))
        guard let key = deriveKey(passphrase: trimmed, salt: salt, rounds: rounds),
              let box = try? CryptoKit.AES.GCM.SealedBox(combined: ciphertext),
              let plain = try? CryptoKit.AES.GCM.open(box, using: key)
        else {
            throw TamioBackupError.wrongPassphrase
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TamioBackupPayload.self, from: plain) else {
            throw TamioBackupError.invalidFile
        }
        return TamioBackupPreview(
            exportedAt: envelope.exportedAt,
            appVersion: payload.appVersion,
            wasEncrypted: true,
            payload: payload
        )
    }

    static func applyImport(
        _ payload: TamioBackupPayload,
        mode: TamioBackupImportMode
    ) {
        let replace = mode == .replace
        let store = TamioStore.shared

        // 1. SSH Identities (must precede servers so associatedIdentity resolves immediately)
        if replace || !payload.identities.isEmpty {
            var group = store.identityGroup
            if replace { group.items.removeAll() }
            for identity in payload.identities {
                group.insert(identity)
            }
            store.identityGroup = group
        }

        // 2. Servers
        if replace || !payload.servers.isEmpty {
            var group = store.machineGroup
            if replace { group.items.removeAll() }
            for server in payload.servers {
                group.insert(server)
            }
            store.machineGroup = group
        }

        // 3. Snippets
        if replace || !payload.snippets.isEmpty {
            var group = store.snippetGroup
            if replace { group.items.removeAll() }
            for snippet in payload.snippets {
                group.insert(snippet)
            }
            store.snippetGroup = group
        }

        // 4. Port Forwards
        if replace || !payload.portForwards.isEmpty {
            var group = store.portForwardGroup
            if replace { group.items.removeAll() }
            for forward in payload.portForwards {
                group.insert(forward)
            }
            store.portForwardGroup = group
        }

        // 5. Known Hosts
        if !payload.knownHosts.isEmpty {
            KnownHosts.shared.applySynced(put: payload.knownHosts, remove: [])
        }

        // 6. AI Providers & API Keys
        if replace || !payload.aiProviders.isEmpty || !payload.aiAPIKeys.isEmpty {
            AIProviderStore.shared.importFromBackup(
                providers: payload.aiProviders,
                apiKeys: payload.aiAPIKeys,
                activeSelection: payload.activeAISelection,
                replaceExisting: replace
            )
        }

        // 7. Custom Ops Skills & Assistant Preferences
        if replace || !payload.customSkills.isEmpty || !payload.disabledBuiltInSkillIDs.isEmpty {
            ServerOpsSkillStore.shared.importFromBackup(
                customSkills: payload.customSkills,
                disabledBuiltInIDs: Set(payload.disabledBuiltInSkillIDs),
                replaceExisting: replace
            )
        }
        if let budget = payload.aiContextTokenBudget, budget >= 16_000 {
            ServerAssistant.shared.contextTokenBudget = budget
        }
        if let memory = payload.aiCrossSessionMemoryEnabled {
            ServerAssistant.shared.crossSessionMemoryEnabled = memory
        }

        store.flushPendingWrites()
    }

    // MARK: - Crypto Helpers

    private static func randomSalt(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Pure-CryptoKit RFC 2898 PBKDF2-HMAC-SHA256 (1 block = 32 bytes for AES-256).
    private static func deriveKey(passphrase: String, salt: Data, rounds: Int) -> SymmetricKey? {
        guard rounds > 0 else { return nil }
        let key = SymmetricKey(data: Data(passphrase.utf8))
        var saltBlock = salt
        saltBlock.append(contentsOf: [0, 0, 0, 1]) // Big-endian block index 1

        var u = Data(HMAC<SHA256>.authenticationCode(for: saltBlock, using: key))
        var output = [UInt8](u)
        if rounds > 1 {
            for _ in 1 ..< rounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for i in 0 ..< output.count {
                    output[i] ^= u[i]
                }
            }
        }
        return SymmetricKey(data: Data(output))
    }
}

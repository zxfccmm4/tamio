//
//  MacBackupTransfer.swift
//  Tamio (macOS)
//
//  One-click AES-256-GCM encrypted or plain JSON Export & Import backup for
//  macOS, 100% file-format compatible with iOS TamioMobile `.tamiobackup.json`.
//

import AppKit
import CryptoKit
import Foundation
import SwiftUI
import TamioDesign
import TamioModule
import UniformTypeIdentifiers

// MARK: - Backup Models (Wire-Compatible with iOS TamioBackupManager)

struct MacBackupOptions: Equatable, Sendable {
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
}

enum MacBackupImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge
    case replace
    var id: String { rawValue }
}

nonisolated struct MacBackupPayload: Codable, Sendable {
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

nonisolated struct MacBackupEnvelope: Codable, Sendable {
    static let magic = "sb.moe.tamio.backup"
    static let currentFormatVersion = 1

    var format: String = magic
    var version: Int = currentFormatVersion
    var encrypted: Bool
    var exportedAt: Date = Date()

    var salt: Data?
    var rounds: Int?
    var ciphertext: Data?
    var payload: MacBackupPayload?
}

struct MacBackupPreview: Sendable {
    let exportedAt: Date
    let appVersion: String
    let wasEncrypted: Bool
    let payload: MacBackupPayload

    var serverCount: Int { payload.servers.count }
    var sharedIdentityCount: Int { payload.identities.filter { !$0.isPrivate }.count }
    var snippetCount: Int { payload.snippets.count }
    var portForwardCount: Int { payload.portForwards.count }
    var aiProviderCount: Int { payload.aiProviders.count }
    var aiKeyCount: Int { payload.aiAPIKeys.count }
    var customSkillCount: Int { payload.customSkills.count }
}

enum MacBackupInspectResult: Sendable {
    case ready(MacBackupPreview)
    case needsPassphrase(MacBackupEnvelope)
}

enum MacBackupError: LocalizedError, Sendable {
    case emptySelection
    case passphraseTooShort
    case invalidFile
    case wrongPassphrase
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: return String(localized: "Select at least one category to export.")
        case .passphraseTooShort: return String(localized: "Passphrase must be at least 4 characters.")
        case .invalidFile: return String(localized: "This file is not a valid Tamio backup.")
        case .wrongPassphrase: return String(localized: "Incorrect passphrase. Unable to decrypt this backup.")
        case .encryptionFailed: return String(localized: "Failed to encrypt backup data.")
        }
    }
}

// MARK: - Backup Manager

@MainActor
enum MacBackupManager {
    private static let pbkdf2Rounds = 100_000

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Tamio-Backup-\(formatter.string(from: Date())).tamiobackup.json"
    }

    static func makeExportData(options: MacBackupOptions, passphrase: String?) throws -> Data {
        guard options.hasAnySelection else { throw MacBackupError.emptySelection }

        let store = TamioStore.shared
        let providerStore = AIProviderStore.shared
        let skillStore = ServerOpsSkillStore.shared
        let assistant = MacServerAssistant.shared

        var payload = MacBackupPayload(
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.22"
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

        let envelope: MacBackupEnvelope
        if let passphrase {
            let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { throw MacBackupError.passphraseTooShort }

            let plain = try encoder.encode(payload)
            let salt = randomSalt(count: 16)
            guard let key = deriveKey(passphrase: trimmed, salt: salt, rounds: pbkdf2Rounds),
                  let sealed = try? CryptoKit.AES.GCM.seal(plain, using: key).combined
            else {
                throw MacBackupError.encryptionFailed
            }
            envelope = MacBackupEnvelope(
                encrypted: true,
                exportedAt: payload.exportedAt,
                salt: salt,
                rounds: pbkdf2Rounds,
                ciphertext: sealed,
                payload: nil
            )
        } else {
            envelope = MacBackupEnvelope(
                encrypted: false,
                exportedAt: payload.exportedAt,
                payload: payload
            )
        }

        return try encoder.encode(envelope)
    }

    static func inspect(data: Data) throws -> MacBackupInspectResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(MacBackupEnvelope.self, from: data),
           envelope.format == MacBackupEnvelope.magic
        {
            if envelope.encrypted {
                guard envelope.salt != nil, envelope.ciphertext != nil else { throw MacBackupError.invalidFile }
                return .needsPassphrase(envelope)
            }
            guard let payload = envelope.payload else { throw MacBackupError.invalidFile }
            return .ready(MacBackupPreview(exportedAt: envelope.exportedAt, appVersion: payload.appVersion, wasEncrypted: false, payload: payload))
        }

        if let rawPayload = try? decoder.decode(MacBackupPayload.self, from: data) {
            return .ready(MacBackupPreview(exportedAt: rawPayload.exportedAt, appVersion: rawPayload.appVersion, wasEncrypted: false, payload: rawPayload))
        }

        throw MacBackupError.invalidFile
    }

    static func decrypt(envelope: MacBackupEnvelope, passphrase: String) throws -> MacBackupPreview {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let salt = envelope.salt, let ciphertext = envelope.ciphertext else {
            throw MacBackupError.invalidFile
        }
        let rounds = max(10_000, min(envelope.rounds ?? pbkdf2Rounds, 500_000))
        guard let key = deriveKey(passphrase: trimmed, salt: salt, rounds: rounds),
              let box = try? CryptoKit.AES.GCM.SealedBox(combined: ciphertext),
              let plain = try? CryptoKit.AES.GCM.open(box, using: key)
        else {
            throw MacBackupError.wrongPassphrase
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(MacBackupPayload.self, from: plain) else {
            throw MacBackupError.invalidFile
        }
        return MacBackupPreview(exportedAt: envelope.exportedAt, appVersion: payload.appVersion, wasEncrypted: true, payload: payload)
    }

    static func applyImport(_ payload: MacBackupPayload, mode: MacBackupImportMode) {
        let store = TamioStore.shared
        let replace = (mode == .replace)

        if !payload.identities.isEmpty || replace {
            var next = store.identityGroup
            if replace { next.items.removeAll() }
            for item in payload.identities { next.insert(item) }
            store.identityGroup = next
        }
        if !payload.servers.isEmpty || replace {
            var next = store.machineGroup
            if replace { next.items.removeAll() }
            for item in payload.servers { next.insert(item) }
            store.machineGroup = next
        }
        if !payload.snippets.isEmpty || replace {
            var next = store.snippetGroup
            if replace { next.items.removeAll() }
            for item in payload.snippets { next.insert(item) }
            store.snippetGroup = next
        }
        if !payload.portForwards.isEmpty || replace {
            var next = store.portForwardGroup
            if replace { next.items.removeAll() }
            for item in payload.portForwards { next.insert(item) }
            store.portForwardGroup = next
        }
        if !payload.knownHosts.isEmpty {
            KnownHosts.shared.applySynced(put: payload.knownHosts, remove: [])
        }
        if !payload.aiProviders.isEmpty || !payload.aiAPIKeys.isEmpty || payload.activeAISelection != nil || replace {
            AIProviderStore.shared.importFromBackup(
                providers: payload.aiProviders,
                apiKeys: payload.aiAPIKeys,
                activeSelection: payload.activeAISelection,
                replaceExisting: replace
            )
        }
        if !payload.customSkills.isEmpty || !payload.disabledBuiltInSkillIDs.isEmpty || replace {
            ServerOpsSkillStore.shared.importFromBackup(
                customSkills: payload.customSkills,
                disabledBuiltInIDs: Set(payload.disabledBuiltInSkillIDs),
                replaceExisting: replace
            )
        }
        if let budget = payload.aiContextTokenBudget {
            MacServerAssistant.shared.contextTokenBudget = budget
        }
        if let memory = payload.aiCrossSessionMemoryEnabled {
            MacServerAssistant.shared.crossSessionMemoryEnabled = memory
        }
    }

    private static func randomSalt(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data, rounds: Int) -> SymmetricKey? {
        let passwordData = Data(passphrase.utf8)
        guard !passwordData.isEmpty, rounds > 0 else { return nil }
        let prfKey = SymmetricKey(data: passwordData)
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])

        var u = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: prfKey))
        var result = u
        if rounds > 1 {
            for _ in 1 ..< rounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: prfKey))
                for idx in 0 ..< result.count { result[idx] ^= u[idx] }
            }
        }
        return SymmetricKey(data: result)
    }
}

// MARK: - Settings UI (Native macOS NSSavePanel / NSOpenPanel)

struct MacBackupTransferSettings: View {
    @State private var options = MacBackupOptions()
    @State private var encryptBackup = true
    @State private var passphrase = ""
    @State private var statusMessage: String?
    @State private var pendingEnvelope: MacBackupEnvelope?
    @State private var decryptPassphrase = ""
    @State private var decryptError: String?
    @State private var importPreview: MacBackupPreview?
    @State private var importMode: MacBackupImportMode = .merge

    private var canExport: Bool {
        options.hasAnySelection
            && (!encryptBackup || passphrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4)
    }

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Servers & SSH credentials",
                description: "Saved hosts, SSH keys, passwords, and known_hosts entries.",
                isOn: $options.includeServersAndCredentials
            )

            SwitchRow(
                "Snippets & port forwards",
                description: "Command snippets and saved SSH port forwarding rules.",
                isOn: $options.includeSnippetsAndForwards
            )

            SwitchRow(
                "AI providers & API keys",
                description: "Configured remote AI endpoints, models, and Keychain API keys.",
                isOn: $options.includeAIProvidersAndKeys
            )

            SwitchRow(
                "Ops skills & AI preferences",
                description: "Custom SKILL.md runbooks, enabled states, memory, and context budget.",
                isOn: $options.includeSkillsAndPreferences
            )

            SwitchRow(
                "Encrypt backup with passphrase",
                description: "Exports an AES-256-GCM .tamiobackup.json compatible with Tamio on iPhone, iPad, and Mac.",
                isOn: $encryptBackup
            )

            if encryptBackup {
                RXFormRow("Passphrase", description: "Minimum 4 characters.") {
                    SecureField("Passphrase", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            RXFormRow("Transfer backup", description: LocalizedStringKey(statusMessage ?? String(localized: "Export or import selected categories as a .tamiobackup.json file."))) {
                HStack(spacing: RX.Space.s2) {
                    Button("Export Backup…") { exportBackup() }
                        .buttonStyle(.rxPrimary)
                        .disabled(!canExport)

                    Button("Import Backup…") { importBackup() }
                        .buttonStyle(.rx)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingEnvelope != nil },
            set: { if !$0 { pendingEnvelope = nil; decryptPassphrase = ""; decryptError = nil } }
        )) {
            SheetScaffold("Unlock Backup") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter the passphrase used when exporting this backup.")
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                    SecureField("Passphrase", text: $decryptPassphrase)
                        .textFieldStyle(.roundedBorder)
                    if let decryptError {
                        Text(decryptError)
                            .font(.rxHelp)
                            .foregroundStyle(.rxDanger)
                    }
                }
                .padding()
                .frame(width: 380)
            } footer: {
                Spacer()
                Button("Cancel") { pendingEnvelope = nil }
                    .buttonStyle(.rx)
                Button("Unlock") { unlockPending() }
                    .buttonStyle(.rxPrimary)
                    .disabled(decryptPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: Binding(
            get: { importPreview != nil },
            set: { if !$0 { importPreview = nil } }
        )) {
            if let preview = importPreview {
                SheetScaffold("Confirm Import") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Backup exported \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)

                        VStack(alignment: .leading, spacing: 6) {
                            summaryRow("Servers", count: preview.serverCount)
                            summaryRow("SSH Keys", count: preview.sharedIdentityCount)
                            summaryRow("Snippets", count: preview.snippetCount)
                            summaryRow("Port Forwards", count: preview.portForwardCount)
                            summaryRow("AI Providers", count: preview.aiProviderCount)
                            summaryRow("AI API Keys", count: preview.aiKeyCount)
                            summaryRow("Custom Ops Skills", count: preview.customSkillCount)
                        }
                        .padding(12)
                        .rxCard()

                        Picker("Import Mode", selection: $importMode) {
                            Text("Merge (Keep Existing)").tag(MacBackupImportMode.merge)
                            Text("Replace All").tag(MacBackupImportMode.replace)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .frame(width: 420)
                } footer: {
                    Spacer()
                    Button("Cancel") { importPreview = nil }
                        .buttonStyle(.rx)
                    Button("Import") {
                        MacBackupManager.applyImport(preview.payload, mode: importMode)
                        importPreview = nil
                        statusMessage = String(localized: "Configuration imported.")
                    }
                    .buttonStyle(.rxPrimary)
                }
            }
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.rxInkSecondary)
            Spacer()
            Text("\(count)").font(.rxBodyStrong.monospacedDigit())
        }
    }

    private func exportBackup() {
        do {
            let data = try MacBackupManager.makeExportData(
                options: options,
                passphrase: encryptBackup ? passphrase : nil
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MacBackupManager.suggestedFilename()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = String(localized: "Backup exported to \(url.lastPathComponent).")
        } catch {
            Dialogs.presentError(with: error.localizedDescription)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data, .item]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            switch try MacBackupManager.inspect(data: data) {
            case .ready(let preview):
                importPreview = preview
            case .needsPassphrase(let envelope):
                decryptPassphrase = ""
                decryptError = nil
                pendingEnvelope = envelope
            }
        } catch {
            Dialogs.presentError(with: error.localizedDescription)
        }
    }

    private func unlockPending() {
        guard let envelope = pendingEnvelope else { return }
        do {
            let preview = try MacBackupManager.decrypt(envelope: envelope, passphrase: decryptPassphrase)
            pendingEnvelope = nil
            decryptPassphrase = ""
            decryptError = nil
            importPreview = preview
        } catch {
            decryptError = error.localizedDescription
        }
    }
}

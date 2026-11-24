//
//  BackupTransferView.swift
//  TamioMobile
//
//  One-click Export & Import UI for transferring all servers, SSH keys,
//  snippets, port forwards, AI providers (with API keys), and custom ops
//  skills to another device via AirDrop, Files, or iCloud Drive.
//

import SPIndicator
import SwiftUI
import TamioModule
import UniformTypeIdentifiers

struct BackupTransferView: View {
    @ObservedObject private var store = TamioStore.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var skillStore = ServerOpsSkillStore.shared

    // Export state
    @State private var options = TamioBackupOptions()
    @State private var encryptBackup = true
    @State private var exportPassphrase = ""
    @State private var exportDocument: TamioBackupDocument?
    @State private var exportFilename = ""
    @State private var showingExporter = false
    @State private var shareURL: URL?

    // Import state
    @State private var showingImporter = false
    @State private var pendingEncryptedEnvelope: TamioBackupEnvelope?
    @State private var decryptPassphrase = ""
    @State private var decryptError: String?
    @State private var importPreview: TamioBackupPreview?
    @State private var importMode: TamioBackupImportMode = .merge

    @State private var errorMessage: String?

    private var customSkillCount: Int {
        skillStore.skills.filter { !$0.isBuiltIn }.count
    }

    private var canExport: Bool {
        guard options.hasAnySelection else { return false }
        if encryptBackup {
            return exportPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
        }
        return true
    }

    var body: some View {
        List {
            // MARK: Current Inventory
            Section {
                LabeledContent("Servers", value: "\(store.machineGroup.machines.count)")
                LabeledContent("SSH Keys & Credentials", value: "\(store.identityGroup.identities.count)")
                LabeledContent("Snippets & Port Forwards", value: "\(store.snippetGroup.snippets.count + store.portForwardGroup.forwards.count)")
                LabeledContent("AI Providers", value: "\(providerStore.providers.count)")
                LabeledContent("Custom Ops Skills", value: "\(customSkillCount)")
            } header: {
                Text("Current Device")
            }

            // MARK: One-Click Export
            Section {
                Toggle("Servers & SSH Credentials", isOn: $options.includeServersAndCredentials)
                Toggle("Snippets & Port Forwards", isOn: $options.includeSnippetsAndForwards)
                Toggle("AI Providers & API Keys", isOn: $options.includeAIProvidersAndKeys)
                Toggle("Ops Skills & AI Preferences", isOn: $options.includeSkillsAndPreferences)

                Toggle("Encrypt with Passphrase", isOn: $encryptBackup)

                if encryptBackup {
                    SecureField("Passphrase (min 4 characters)", text: $exportPassphrase)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Button {
                    triggerExport(saveToFiles: false)
                } label: {
                    Label("Export & Share Backup", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canExport)

                Button {
                    triggerExport(saveToFiles: true)
                } label: {
                    Label("Save Backup to Files…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!canExport)
            } header: {
                Text("Export Configuration")
            } footer: {
                Text(encryptBackup
                    ? "Exports an AES-256-GCM encrypted backup file you can AirDrop or save to Files for importing on another device."
                    : "Unencrypted JSON contains plaintext SSH passwords, private keys, and AI API keys. Keep the file private and delete it after transfer.")
            }

            // MARK: One-Click Import
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Backup File…", systemImage: "square.and.arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Import Configuration")
            } footer: {
                Text("Choose a .tamiobackup.json file exported from another device. You can preview all items and choose Merge or Replace before applying.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Export & Import")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            } else {
                presentToast(String(localized: "Backup Exported"))
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImportedFile(result)
        }
        .sheet(isPresented: Binding(
            get: { pendingEncryptedEnvelope != nil },
            set: { if !$0 { pendingEncryptedEnvelope = nil; decryptPassphrase = ""; decryptError = nil } }
        )) {
            passphrasePromptSheet
        }
        .sheet(isPresented: Binding(
            get: { importPreview != nil },
            set: { if !$0 { importPreview = nil } }
        )) {
            if let preview = importPreview {
                importPreviewSheet(preview)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Passphrase Unlock Sheet

    private var passphrasePromptSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Backup Passphrase", text: $decryptPassphrase)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Encrypted Backup")
                } footer: {
                    if let decryptError {
                        Text(decryptError)
                            .foregroundStyle(.red)
                    } else {
                        Text("Enter the passphrase used when exporting this backup.")
                    }
                }
            }
            .navigationTitle("Unlock Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingEncryptedEnvelope = nil
                        decryptPassphrase = ""
                        decryptError = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") {
                        guard let envelope = pendingEncryptedEnvelope else { return }
                        do {
                            let preview = try TamioBackupManager.decrypt(
                                envelope: envelope,
                                passphrase: decryptPassphrase
                            )
                            pendingEncryptedEnvelope = nil
                            decryptPassphrase = ""
                            decryptError = nil
                            importPreview = preview
                        } catch {
                            decryptError = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(decryptPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Import Preview Sheet

    private func importPreviewSheet(_ preview: TamioBackupPreview) -> some View {
        NavigationStack {
            Form {
                Section("Backup Contents") {
                    LabeledContent("Exported", value: preview.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Encryption", value: preview.wasEncrypted ? String(localized: "AES-256-GCM") : String(localized: "Plain JSON"))
                    LabeledContent("Servers", value: "\(preview.serverCount)")
                    LabeledContent("SSH Keys", value: "\(preview.sharedIdentityCount)")
                    LabeledContent("Snippets", value: "\(preview.snippetCount)")
                    LabeledContent("Port Forwards", value: "\(preview.portForwardCount)")
                    LabeledContent("AI Providers", value: "\(preview.aiProviderCount)")
                    LabeledContent("AI API Keys", value: "\(preview.aiKeyCount)")
                    LabeledContent("Custom Ops Skills", value: "\(preview.customSkillCount)")
                }

                Section {
                    Picker("Import Mode", selection: $importMode) {
                        Text("Merge (Keep Existing)").tag(TamioBackupImportMode.merge)
                        Text("Replace All").tag(TamioBackupImportMode.replace)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Import Mode")
                } footer: {
                    Text(importMode == .merge
                        ? "Adds new items and updates matching IDs without deleting existing servers or AI providers on this device."
                        : "Replaces all existing servers, SSH keys, snippets, port forwards, and AI providers with the contents of this backup.")
                }
            }
            .navigationTitle("Confirm Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { importPreview = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        TamioBackupManager.applyImport(preview.payload, mode: importMode)
                        importPreview = nil
                        presentToast(String(localized: "Configuration Imported"))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerExport(saveToFiles: Bool) {
        let perform = {
            do {
                let data = try TamioBackupManager.makeExportData(
                    options: options,
                    passphrase: encryptBackup ? exportPassphrase : nil
                )
                let filename = TamioBackupManager.suggestedFilename()
                if saveToFiles {
                    exportDocument = TamioBackupDocument(data: data)
                    exportFilename = filename
                    showingExporter = true
                } else {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try data.write(to: tempURL, options: .atomic)
                    shareURL = tempURL
                    presentShareSheet(for: tempURL)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        if options.includesSecrets {
            TamioUtil.deviceOwnershipAuthenticate { ok in
                if ok { perform() }
            }
        } else {
            perform()
        }
    }

    private func presentShareSheet(for url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let presenter = UIWindow.shutUpKeyWindow?.topMostViewController {
            activity.popoverPresentationController?.sourceView = presenter.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
            presenter.present(activity, animated: true)
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                switch try TamioBackupManager.inspect(data: data) {
                case .ready(let preview):
                    importPreview = preview
                case .needsPassphrase(let envelope):
                    decryptPassphrase = ""
                    decryptError = nil
                    pendingEncryptedEnvelope = envelope
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func presentToast(_ title: String) {
        let indicator = SPIndicatorView(title: title, preset: .done)
        indicator.presentWindow = UIWindow.shutUpKeyWindow
        indicator.present(haptic: .success, completion: nil)
    }
}

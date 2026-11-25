//
//  BackupTransferView.swift
//  TamioMobile
//
//  Polished Apple HIG Export & Import hub aligned with AboutView & SettingView:
//  - Hero icon header & compact 2×2 current inventory grid
//  - Selective backup toggles with tinted AppleFeatureBadge icons
//  - Optional AES-256-GCM passphrase protection + prominent Liquid Glass CTAs
//  - Clean fileImporter flow with encrypted unlock & visual Import Preview sheet
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

    // Import state (native UIDocumentPickerViewController with asCopy: true + single modal sheet)
    @State private var pendingImport: PendingBackupImport?
    @State private var activePickerDelegate: BackupDocumentPickerDelegate?

    @State private var errorMessage: String?

    private var customSkillCount: Int {
        skillStore.skills.filter { !$0.isBuiltIn }.count
    }

    private var snippetsAndForwardsCount: Int {
        store.snippetGroup.snippets.count + store.portForwardGroup.forwards.count
    }

    private var canExport: Bool {
        guard options.hasAnySelection else { return false }
        if encryptBackup {
            return exportPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
        }
        return true
    }

    var body: some View {
        Form {
            // MARK: Hero Header
            Section {
                VStack(spacing: 8) {
                    AppleFeatureBadge(systemImage: "arrow.up.arrow.down.circle.fill", tint: .blue, size: 58)
                        .padding(.bottom, 2)
                        .accessibilityHidden(true)

                    Text("Export & Import")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    Text("Transfer all servers, SSH credentials, AI providers, and custom skills across devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))

            // MARK: Compact 2×2 Inventory Grid
            Section {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    inventoryTile(
                        title: String(localized: "Servers"),
                        count: store.machineGroup.machines.count,
                        icon: "server.rack",
                        tint: .blue
                    )
                    inventoryTile(
                        title: String(localized: "SSH Keys"),
                        count: store.identityGroup.identities.count,
                        icon: "key.fill",
                        tint: .orange
                    )
                    inventoryTile(
                        title: String(localized: "AI Providers"),
                        count: providerStore.providers.count,
                        icon: "sparkles",
                        tint: .purple
                    )
                    inventoryTile(
                        title: String(localized: "Snippets & Skills"),
                        count: snippetsAndForwardsCount + customSkillCount,
                        icon: "wand.and.stars",
                        tint: .teal
                    )
                }
            } header: {
                Text("Current Device")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            // MARK: Export Content Selection
            Section {
                Toggle(isOn: $options.includeServersAndCredentials) {
                    optionLabel("Servers & SSH Credentials", icon: "server.rack", tint: .blue)
                }
                Toggle(isOn: $options.includeSnippetsAndForwards) {
                    optionLabel("Snippets & Port Forwards", icon: "arrow.left.arrow.right", tint: .indigo)
                }
                Toggle(isOn: $options.includeAIProvidersAndKeys) {
                    optionLabel("AI Providers & API Keys", icon: "sparkles", tint: .purple)
                }
                Toggle(isOn: $options.includeSkillsAndPreferences) {
                    optionLabel("Ops Skills & AI Preferences", icon: "wand.and.stars", tint: .teal)
                }
            } header: {
                Text("Export Configuration")
            }

            // MARK: Protection & Export Actions
            Section {
                Toggle(isOn: $encryptBackup) {
                    optionLabel("Encrypt with Passphrase", icon: "lock.shield.fill", tint: .green)
                }

                if encryptBackup {
                    HStack(spacing: 10) {
                        SecureField("Passphrase (min 4 characters)", text: $exportPassphrase)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        if exportPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } footer: {
                Text(encryptBackup
                    ? "Exports an AES-256-GCM encrypted backup file you can AirDrop or save to Files for importing on another device."
                    : "Unencrypted JSON contains plaintext SSH passwords, private keys, and AI API keys. Keep the file private and delete it after transfer.")
            }

            Section {
                VStack(spacing: 10) {
                    Button {
                        triggerExport(saveToFiles: false)
                    } label: {
                        Label("Export & Share Backup", systemImage: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                    .disabled(!canExport)

                    Button {
                        triggerExport(saveToFiles: true)
                    } label: {
                        Label("Save Backup to Files…", systemImage: "folder.badge.plus")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .appleGlassButton()
                    .controlSize(.large)
                    .disabled(!canExport)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))

            // MARK: Import Section
            Section {
                Button {
                    presentDocumentPicker()
                } label: {
                    HStack(spacing: 12) {
                        AppleFeatureBadge(systemImage: "square.and.arrow.down.fill", tint: .cyan, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Backup File…")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Restore from AirDrop or Files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Import Configuration")
            } footer: {
                Text("Choose a .tamiobackup.json file exported from another device. You can preview all items and choose Merge or Replace before applying.")
            }
        }
        .appleGroupedBackground()
        .navigationTitle("Export & Import")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            Color.clear
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
        )
        .sheet(item: $pendingImport) { item in
            BackupImportModalView(initialResult: item.result) {
                presentToast(String(localized: "Configuration Imported"))
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

    // MARK: - Helper Subviews

    private func inventoryTile(title: String, count: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            AppleFeatureBadge(systemImage: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func optionLabel(_ title: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            AppleFeatureBadge(systemImage: icon, tint: tint, size: 28)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
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

    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .data, .item],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        let delegate = BackupDocumentPickerDelegate { url in
            activePickerDelegate = nil
            guard let url else { return }
            handlePickedURL(url)
        }
        activePickerDelegate = delegate
        picker.delegate = delegate

        if let presenter = UIWindow.shutUpKeyWindow?.topMostViewController {
            presenter.present(picker, animated: true)
        }
    }

    private func handlePickedURL(_ url: URL) {
        do {
            let data = try TamioBackupManager.readBackupData(from: url)
            let inspected = try TamioBackupManager.inspect(data: data)
            Task { @MainActor in
                // Give UIDocumentPickerViewController a brief beat to finish dismissing.
                try? await Task.sleep(for: .milliseconds(250))
                pendingImport = PendingBackupImport(result: inspected)
            }
        } catch {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
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

private final class BackupDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let onComplete: (URL?) -> Void

    init(onComplete: @escaping (URL?) -> Void) {
        self.onComplete = onComplete
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onComplete(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onComplete(nil)
    }
}

// MARK: - Shared Single-Sheet Import Flow (Unlock -> Confirm Import)

struct PendingBackupImport: Identifiable {
    let id = UUID()
    let result: TamioBackupInspectResult
}

struct BackupImportModalView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage
    @State private var decryptPassphrase = ""
    @State private var decryptError: String?
    @State private var importMode: TamioBackupImportMode = .merge

    let onImported: () -> Void

    private enum Stage {
        case unlock(TamioBackupEnvelope)
        case preview(TamioBackupPreview)
    }

    init(initialResult: TamioBackupInspectResult, onImported: @escaping () -> Void = {}) {
        switch initialResult {
        case .needsPassphrase(let envelope):
            _stage = State(initialValue: .unlock(envelope))
        case .ready(let preview):
            _stage = State(initialValue: .preview(preview))
        }
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            switch stage {
            case .unlock(let envelope):
                unlockForm(envelope)
            case .preview(let preview):
                previewForm(preview)
            }
        }
    }

    private func unlockForm(_ envelope: TamioBackupEnvelope) -> some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AppleFeatureBadge(systemImage: "lock.fill", tint: .green, size: 48)
                    Text("Encrypted Backup")
                        .font(.headline)
                    Text("Enter the passphrase used when exporting this backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            Section {
                SecureField("Backup Passphrase", text: $decryptPassphrase)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { unlock(envelope) }
            } footer: {
                if let decryptError {
                    Text(decryptError)
                        .foregroundStyle(.red)
                }
            }
        }
        .appleGroupedBackground()
        .navigationTitle("Unlock Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Unlock") { unlock(envelope) }
                    .fontWeight(.semibold)
                    .disabled(decryptPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func unlock(_ envelope: TamioBackupEnvelope) {
        do {
            let preview = try TamioBackupManager.decrypt(
                envelope: envelope,
                passphrase: decryptPassphrase
            )
            decryptError = nil
            withAnimation(.snappy(duration: 0.25)) {
                stage = .preview(preview)
            }
        } catch {
            decryptError = error.localizedDescription
        }
    }

    private func previewForm(_ preview: TamioBackupPreview) -> some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    AppleFeatureBadge(
                        systemImage: preview.wasEncrypted ? "lock.shield.fill" : "doc.text.fill",
                        tint: preview.wasEncrypted ? .green : .blue,
                        size: 48
                    )
                    Text("Backup Contents")
                        .font(.headline)
                    Text(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            Section {
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
        .appleGroupedBackground()
        .navigationTitle("Confirm Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    TamioBackupManager.applyImport(preview.payload, mode: importMode)
                    dismiss()
                    onImported()
                }
                .fontWeight(.semibold)
            }
        }
    }
}

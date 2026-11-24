//
//  EditIdentityView.swift
//  TamioMobile
//
//  Pure credential editor aligned with the Mac app: SSH keys (generate Ed25519,
//  import, paste, sealed private key display), legacy password identities, and
//  read-only preservation for macOS SSH agent identities synced via iCloud.
//

import SwiftUI
import TamioDesign
import TamioModule
import UIKit

struct IdentityDraft: Equatable {
    enum Method: Hashable {
        case key
        case agent
        case password
    }

    var name = ""
    var group = ""
    var method: Method = .key
    var password = ""
    var privateKey = ""
    var publicKey = ""
    var comment = ""
    var automatic = false
    var agentSocket = ""

    init() {}

    init(_ identity: RDIdentity) {
        name = identity.name
        group = identity.group
        method = identity.usesAgent ? .agent : (identity.privateKey.isEmpty && !identity.password.isEmpty ? .password : .key)
        agentSocket = identity.agentSocket ?? ""
        password = identity.password
        privateKey = identity.privateKey
        publicKey = identity.publicKey
        comment = identity.comment
        automatic = identity.authenticAutomatically
    }

    var trimmedPrivateKey: String {
        privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var problem: String? {
        switch method {
        case .password:
            return password.isEmpty ? String(localized: "Type the password.") : nil
        case .agent:
            return nil
        case .key:
            if trimmedPrivateKey.isEmpty {
                return String(localized: "Paste, load, or generate a private key.")
            }
            if !trimmedPrivateKey.contains("PRIVATE KEY") {
                return trimmedPrivateKey.hasPrefix("ssh-") || trimmedPrivateKey.hasPrefix("ecdsa-")
                    ? String(localized: "That is a public key. The private key starts with -----BEGIN … PRIVATE KEY-----.")
                    : String(localized: "This does not look like a private key: it starts with -----BEGIN … PRIVATE KEY-----.")
            }
            return nil
        }
    }

    var isValid: Bool { problem == nil }

    func apply(to identity: RDIdentity) -> RDIdentity {
        var result = identity
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.group = group.trimmingCharacters(in: .whitespaces)
        result.agentSocket = method == .agent ? agentSocket.trimmingCharacters(in: .whitespaces) : nil
        switch method {
        case .password:
            result.password = password
            result.privateKey = ""
            result.publicKey = ""
        case .agent:
            result.password = ""
            result.privateKey = ""
            result.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .key:
            result.password = password
            result.privateKey = trimmedPrivateKey + "\n"
            result.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        result.comment = comment
        result.authenticAutomatically = automatic
        return result
    }

    func differs(from identity: RDIdentity) -> Bool {
        let edited = apply(to: identity)
        return edited.name != identity.name
            || edited.group != identity.group
            || edited.password != identity.password
            || edited.privateKey != identity.privateKey
            || edited.publicKey != identity.publicKey
            || edited.agentSocket != identity.agentSocket
            || edited.comment != identity.comment
            || edited.authenticAutomatically != identity.authenticAutomatically
    }
}

struct EditIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TamioStore.shared

    let inEditWith: UUID?
    let onSaved: ((RDIdentity.ID) -> Void)?
    let embedded: Bool

    init(requestIdentity: UUID? = nil, embedded: Bool = false, onSaved: ((RDIdentity.ID) -> Void)? = nil) {
        inEditWith = requestIdentity
        self.embedded = embedded
        self.onSaved = onSaved
    }

    @State private var initializedOnce = false
    @State private var draft = IdentityDraft()
    @State private var showsSecret = false
    @State private var savedPrivateKey = false
    @State private var allowsPassword = false
    @State private var allowsAgent = false

    private var isNew: Bool { inEditWith == nil }

    private var original: RDIdentity? {
        inEditWith.map { store.identityGroup[$0] }
    }

    private var existingGroups: [String] {
        Set(store.identityGroup.shared.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    private var usedBy: [String] {
        guard let inEditWith else { return [] }
        return store.machineGroup.machines
            .filter { $0.associatedIdentity == inEditWith.uuidString }
            .map(\.name)
    }

    private var algorithm: String? {
        RDIdentity.keyAlgorithm(publicKey: draft.publicKey, privateKey: draft.privateKey)
    }

    var body: some View {
        List {
            if !usedBy.isEmpty {
                Section {
                    let names = usedBy.prefix(4).joined(separator: ", ")
                    let more = usedBy.count > 4 ? " " + String(localized: "and \(usedBy.count - 4) more") : ""
                    HelpText(String(localized: "Used by \(names)\(more)"))
                }
            }

            Section {
                TextField(draft.method == .password ? "Office password" : "Deploy key", text: $draft.name)
                    .disableAutocorrection(true)
                HStack(spacing: RX.Space.s2) {
                    TextField("Group (optional)", text: $draft.group)
                        .textInputAutocapitalization(.never)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { item in
                                Button(item) { draft.group = item }
                            }
                        } label: {
                            Image(rx: "chevron.down")
                                .foregroundStyle(.rxInkSecondary)
                        }
                    }
                }
                TextField("Comment (optional)", text: $draft.comment)
            } header: {
                RXSectionHeader("General")
            }

            if allowsPassword || allowsAgent {
                Section {
                    Picker("Authentication", selection: $draft.method) {
                        Text("SSH key").tag(IdentityDraft.Method.key)
                        if allowsAgent {
                            Text("SSH agent").tag(IdentityDraft.Method.agent)
                        }
                        if allowsPassword {
                            Text("Password").tag(IdentityDraft.Method.password)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    RXSectionHeader("Authentication")
                }
            }

            switch draft.method {
            case .agent:
                agentSection
            case .password:
                passwordSection
            case .key:
                keySections
            }

            if let problem = draft.problem, !(draft.method == .key && draft.trimmedPrivateKey.isEmpty) {
                Section {
                    HelpText(problem, isError: true)
                }
            }

            if let id = inEditWith {
                Section {
                    Button(role: .destructive) {
                        IdentityActions.delete(id)
                        if !embedded { dismiss() }
                    } label: {
                        Label("Delete Identity", rx: "trash")
                            .foregroundStyle(.rxDanger)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isNew ? String(localized: "New SSH Key") : (draft.name.isEmpty ? String(localized: "Edit Identity") : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add Key" : "Save") {
                    save()
                }
                .bold()
                .disabled(!draft.isValid || (!isNew && original.map { !draft.differs(from: $0) } == true))
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: inEditWith) { _, _ in
            initializedOnce = false
            loadIfNeeded()
        }
    }

    // MARK: - Sections

    @ViewBuilder private var agentSection: some View {
        Section {
            HelpText("This identity uses an SSH agent on macOS. iOS cannot connect to external SSH agents; its configuration is kept intact so Mac sync continues working.")
            if !draft.agentSocket.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    CapsLabel("Socket")
                    Text(draft.agentSocket)
                        .font(.rxCode)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            if !draft.publicKey.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    CapsLabel("Public Key")
                    Text(draft.publicKey)
                        .font(.rxCode)
                        .foregroundStyle(.rxInkSecondary)
                }
                Button {
                    UIBridge.sendPasteboard(str: draft.publicKey)
                } label: {
                    Label("Copy Public Key", rx: "doc.on.clipboard")
                }
            }
        } header: {
            RXSectionHeader("SSH Agent")
        }
    }

    @ViewBuilder private var passwordSection: some View {
        Section {
            secretFieldRow(placeholder: "Password", text: $draft.password, protectWithBiometrics: !isNew)
        } header: {
            RXSectionHeader("Password")
        }
    }

    @ViewBuilder private var keySections: some View {
        Section {
            if !draft.privateKey.isEmpty, savedPrivateKey {
                // Once stored, a private key is never displayed again: only replaced.
                HStack(spacing: RX.Space.s2) {
                    Image(rx: "lock.fill")
                        .foregroundStyle(.rxInkSecondary)
                    Text("••••••")
                        .font(.rxCode)
                        .foregroundStyle(.rxInkSecondary)
                    Text(algorithm.map(Self.algorithmTitle) ?? String(localized: "Private key"))
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                    Spacer()
                    Button("Replace…") { replacePrivateKey() }
                        .buttonStyle(.rx(size: .small))
                }
            } else {
                TextEditor(text: $draft.privateKey)
                    .font(.rxCode)
                    .frame(minHeight: 110)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                Button {
                    generateEd25519()
                } label: {
                    Label("Generate Ed25519 Key", rx: "key")
                }
                FilePicker(types: [.item], allowMultiple: false) { urls in
                    guard let url = urls.first else { return }
                    loadPrivateKey(url: url)
                } label: {
                    Label("Import from File…", rx: "square.and.arrow.down")
                }
                Button {
                    loadPrivateKey(str: UIPasteboard.general.string)
                } label: {
                    Label("Paste from Clipboard", rx: "doc.on.clipboard")
                }
                if !draft.privateKey.isEmpty {
                    Button(role: .destructive) {
                        draft.privateKey = ""
                    } label: {
                        Label("Clear Private Key", rx: "trash")
                    }
                }
            }
        } header: {
            RXSectionHeader("Private Key")
        } footer: {
            if draft.privateKey.isEmpty {
                Text("Ed25519, RSA and ECDSA keys work, in OpenSSH or PEM format.")
            } else if savedPrivateKey {
                Text("Private keys are sealed once saved and cannot be viewed again.")
            }
        }

        Section {
            TextEditor(text: $draft.publicKey)
                .font(.rxCode)
                .frame(minHeight: 68)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
            if !draft.publicKey.isEmpty {
                Button {
                    UIBridge.sendPasteboard(str: draft.publicKey)
                } label: {
                    Label("Copy Public Key", rx: "doc.on.clipboard")
                }
            }
            FilePicker(types: [.item], allowMultiple: false) { urls in
                guard let url = urls.first else { return }
                loadPublicKey(url: url)
            } label: {
                Label("Import from File…", rx: "square.and.arrow.down")
            }
            Button {
                loadPublicKey(str: UIPasteboard.general.string)
            } label: {
                Label("Paste from Clipboard", rx: "doc.on.clipboard")
            }
        } header: {
            RXSectionHeader("Public Key")
        } footer: {
            Text("Goes in the server's ~/.ssh/authorized_keys. Optional for signing in.")
        }

        Section {
            secretFieldRow(placeholder: "Passphrase (optional)", text: $draft.password, protectWithBiometrics: !isNew && !draft.password.isEmpty)
        } header: {
            RXSectionHeader("Passphrase")
        }
    }

    @ViewBuilder
    private func secretFieldRow(placeholder: LocalizedStringKey, text: Binding<String>, protectWithBiometrics: Bool) -> some View {
        HStack(spacing: RX.Space.s2) {
            Group {
                if showsSecret {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            Button {
                if showsSecret {
                    showsSecret = false
                } else if protectWithBiometrics {
                    TamioUtil.deviceOwnershipAuthenticate { success in
                        if success { showsSecret = true }
                    }
                } else {
                    showsSecret = true
                }
            } label: {
                Image(rx: showsSecret ? "eye.slash" : "eye")
                    .foregroundStyle(.rxInkSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !initializedOnce else { return }
        initializedOnce = true
        if let original {
            draft = IdentityDraft(original)
            savedPrivateKey = !original.privateKey.isEmpty
            allowsPassword = draft.method == .password
            allowsAgent = draft.method == .agent
        } else {
            draft = IdentityDraft()
            savedPrivateKey = false
            allowsPassword = false
            allowsAgent = false
        }
        showsSecret = false
    }

    private func generateEd25519() {
        let comment = draft.name.isEmpty ? "tamio" : draft.name.replacingOccurrences(of: " ", with: "-")
        let pair = SSHKeyGenerator.ed25519(comment: comment)
        draft.privateKey = pair.privateKey
        draft.publicKey = pair.publicKey
        draft.password = ""
        savedPrivateKey = true
        if draft.name.isEmpty { draft.name = "Ed25519 key" }
    }

    private func replacePrivateKey() {
        UIBridge.requiresConfirmation(
            message: String(localized: "Replace this private key?"),
            informative: String(localized: "The saved key is discarded when you save. Servers that trust it will not accept a new key until its public key is added."),
            confirmTitle: String(localized: "Replace"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            draft.privateKey = ""
            draft.publicKey = ""
            draft.password = ""
            savedPrivateKey = false
        }
    }

    private func loadPrivateKey(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
            UIBridge.presentError(with: String(localized: "The file could not be read as text."))
            return
        }
        loadPrivateKey(str: string)
    }

    private func loadPublicKey(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
            UIBridge.presentError(with: String(localized: "The file could not be read as text."))
            return
        }
        loadPublicKey(str: string)
    }

    private func loadPrivateKey(str: String?) {
        guard let raw = str?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            UIBridge.presentError(with: String(localized: "Nothing to paste."))
            return
        }
        if raw.contains("PRIVATE KEY") {
            draft.privateKey = raw
            savedPrivateKey = false
        } else {
            UIBridge.requiresConfirmation(
                message: String(localized: "This does not look like a private key. Load it anyway?"),
                confirmTitle: String(localized: "Load"),
                destructive: false
            ) { confirmed in
                if confirmed {
                    draft.privateKey = raw
                    savedPrivateKey = false
                }
            }
        }
    }

    private func loadPublicKey(str: String?) {
        guard let raw = str?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            UIBridge.presentError(with: String(localized: "Nothing to paste."))
            return
        }
        draft.publicKey = raw
    }

    private func save() {
        guard draft.isValid else {
            if let problem = draft.problem { UIBridge.presentError(with: problem) }
            return
        }
        let base = original ?? RDIdentity(lastRecentUsed: .init(timeIntervalSince1970: 0))
        let updated = draft.apply(to: base)
        store.identityGroup.insert(updated)
        savedPrivateKey = !updated.privateKey.isEmpty
        onSaved?(updated.id)
        if !embedded { dismiss() }
    }

    private static func algorithmTitle(_ algorithm: String) -> String {
        algorithm == "ed25519" ? "Ed25519" : algorithm.uppercased()
    }
}

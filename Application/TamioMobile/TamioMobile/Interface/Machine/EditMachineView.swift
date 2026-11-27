//
//  EditMachineView.swift
//  TamioMobile
//
//  New / Edit Server aligned with the Mac app's ServerEditorDialog:
//  Address; General (Label, Group, Tags); SSH (Username, Port); Credentials
//  (per-server private Password, shared SSH Key with inline New Key…, or None
//  for Tailscale SSH); Advanced (SFTP start folder, Startup snippet, Shell
//  integration, Comment, Last banner, and read-only preservation of macOS
//  ProxyCommand); plus Save & Connect with inline validation.
//

import NSRemoteShell
import SwiftUI
import TamioDesign
import TamioModule
import UIKit

struct MobileServerDraft: Equatable {
    enum Credential: Hashable {
        case password
        case key
        case none
    }

    var address = ""
    var label = ""
    var group = ""
    var tags = ""
    var port = "22"
    var username = ""
    var credential: Credential = .password
    var password = ""
    var key: RDIdentity.ID?
    var startFolder = ""
    var startupSnippet: RDSnippet.ID?
    var comment = ""
    var proxyCommand = ""
    var shellIntegration = false
    var renewalEnabled = false
    var renewalDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    var renewalCycle: RDMachine.RenewalCycle = .monthly
    var renewalPrice = ""
    var renewalRemindDays = 7
}

struct EditMachineView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?
    let onClose: (() -> Void)?

    init(requestMachine: UUID? = nil, onClose: (() -> Void)? = nil) {
        inEditWith = requestMachine
        self.onClose = onClose
    }

    private var store: TamioStore { TamioStore.shared }

    private struct CachedKeyOption: Identifiable, Equatable {
        let id: RDIdentity.ID
        let title: String
        let usesAgent: Bool
        let publicKey: String
    }

    @State private var initializedOnce = false
    @State private var draft = MobileServerDraft()
    @State private var loaded = MobileServerDraft()
    @State private var existingGroups: [String] = []
    @State private var keyOptions: [CachedKeyOption] = []
    @State private var snippetOptions: [(id: RDSnippet.ID, name: String)] = []
    @State private var banner = ""
    @State private var showsPassword = false
    @State private var showsAdvanced = false
    @State private var connecting = false
    @State private var isSaving = false
    @State private var addsKey = false
    @State private var addressError: String?
    @State private var credentialsError: String?

    private var isNew: Bool { inEditWith == nil }
    private var trimmedAddress: String { draft.address.trimmingCharacters(in: .whitespaces) }
    private var trimmedUsername: String {
        let typed = draft.username.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? RDMachine.defaultUsername : typed
    }
    private var portIsValid: Bool { UInt16(draft.port).map { $0 > 0 } ?? false }
    private var canSave: Bool { !trimmedAddress.isEmpty && portIsValid }
    private var isDirty: Bool { draft != loaded }

    private static func makeKeyTitle(_ identity: RDIdentity) -> String {
        let agent = identity.agentName.flatMap { identity.displayName.contains($0) ? nil : $0 }
        return [identity.displayName, agent, identity.keyAlgorithm?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    private func reloadSnapshots() {
        existingGroups = Set(store.machineGroup.machines.map(\.group)).filter { !$0.isEmpty }.sorted()
        keyOptions = store.identityGroup.shared
            .filter { !$0.privateKey.isEmpty || $0.usesAgent }
            .map {
                CachedKeyOption(
                    id: $0.id,
                    title: Self.makeKeyTitle($0),
                    usesAgent: $0.usesAgent,
                    publicKey: $0.publicKey
                )
            }
        snippetOptions = store.snippetGroup.snippets.map { ($0.id, $0.name) }
    }

    private func closeSheet() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var liveEndpointPreview: String {
        let host = trimmedAddress.isEmpty ? "host" : trimmedAddress
        let portTrimmed = draft.port.trimmingCharacters(in: .whitespaces)
        let portSuffix = (portTrimmed.isEmpty || portTrimmed == "22") ? "" : ":\(portTrimmed)"
        return "\(trimmedUsername)@\(host)\(portSuffix)"
    }

    private var credentialBadgeLabel: String {
        switch draft.credential {
        case .password: return String(localized: "Password")
        case .key: return String(localized: "SSH Key")
        case .none: return String(localized: "None")
        }
    }

    var body: some View {
        List {
            // MARK: Live Connection Preview Card
            Section {
                HStack(spacing: 12) {
                    AppleFeatureBadge(systemImage: "server.rack", tint: .blue, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.label.trimmingCharacters(in: .whitespaces).isEmpty
                            ? (trimmedAddress.isEmpty ? String(localized: "New Server") : trimmedAddress)
                            : draft.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(liveEndpointPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(credentialBadgeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .padding(.vertical, 2)
            }

            // MARK: Connection (Host, Port, Username)
            Section {
                HStack(spacing: 12) {
                    fieldLabel("Host", icon: "network", tint: .blue)
                    TextField("IP or hostname", text: $draft.address)
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onChange(of: draft.address) { _, newValue in
                            let normalized = newValue.replacingOccurrences(of: "。", with: ".")
                            if draft.address != normalized { draft.address = normalized }
                            if addressError != nil { addressError = nil }
                        }
                }

                HStack(spacing: 12) {
                    fieldLabel("Port", icon: "number", tint: .indigo)
                    TextField("22", text: $draft.port)
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                        .keyboardType(.numberPad)
                }

                HStack(spacing: 12) {
                    fieldLabel("Username", icon: "person.fill", tint: .teal)
                    TextField(RDMachine.defaultUsername, text: $draft.username)
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("SSH")
            } footer: {
                if let addressError {
                    Text(addressError)
                        .foregroundStyle(.red)
                } else if !portIsValid {
                    Text("Port must be between 1 and 65535.")
                        .foregroundStyle(.red)
                }
            }

            // MARK: Credentials
            Section {
                Picker("Sign in with", selection: $draft.credential) {
                    Text("Password").tag(MobileServerDraft.Credential.password)
                    Text("SSH key").tag(MobileServerDraft.Credential.key)
                    Text("None").tag(MobileServerDraft.Credential.none)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                .onChange(of: draft.credential) { _, _ in
                    credentialsError = nil
                }

                switch draft.credential {
                case .none:
                    EmptyView()

                case .password:
                    HStack(spacing: 12) {
                        AppleFeatureBadge(systemImage: "key.fill", tint: .orange, size: 28)
                        Group {
                            if showsPassword {
                                TextField("Password", text: $draft.password)
                            } else {
                                SecureField("Password", text: $draft.password)
                            }
                        }
                        .font(.callout.monospaced())
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)

                        Button {
                            if showsPassword {
                                showsPassword = false
                            } else if !isNew, !draft.password.isEmpty {
                                TamioUtil.deviceOwnershipAuthenticate { ok in
                                    if ok { showsPassword = true }
                                }
                            } else {
                                showsPassword = true
                            }
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                case .key:
                    Picker(selection: $draft.key) {
                        Text(keyOptions.isEmpty ? "No keys yet" : "Choose a key").tag(RDIdentity.ID?.none)
                        ForEach(keyOptions) { option in
                            Text(option.title).tag(RDIdentity.ID?.some(option.id))
                        }
                    } label: {
                        fieldLabel("SSH Key", icon: "key.horizontal.fill", tint: .orange)
                    }

                    Button {
                        addsKey = true
                    } label: {
                        HStack(spacing: 12) {
                            AppleFeatureBadge(systemImage: "plus", tint: .blue, size: 28)
                            Text("New Key…")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if let keyID = draft.key, let key = keyOptions.first(where: { $0.id == keyID }) {
                        if !key.usesAgent, !key.publicKey.isEmpty {
                            Button {
                                UIBridge.sendPasteboard(str: key.publicKey)
                            } label: {
                                HStack(spacing: 12) {
                                    AppleFeatureBadge(systemImage: "doc.on.clipboard", tint: .indigo, size: 28)
                                    Text("Copy Public Key")
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Credentials")
            } footer: {
                if let credentialsError {
                    Text(credentialsError)
                        .foregroundStyle(.red)
                } else if draft.credential == .none {
                    Text("Signs in as \(trimmedUsername) with no password or key, for a server that trusts the connection itself, such as Tailscale SSH.")
                } else if draft.credential == .password {
                    Text("Kept privately with this server only.")
                } else if let keyID = draft.key,
                          let key = keyOptions.first(where: { $0.id == keyID }),
                          key.usesAgent
                {
                    Text("This key is held by a macOS SSH agent and cannot be used directly on iOS. Choose a stored key to connect from this device.")
                        .foregroundStyle(.red)
                }
            }

            // MARK: Organization (Label, Group, Tags)
            Section("General") {
                HStack(spacing: 12) {
                    fieldLabel("Label", icon: "tag.fill", tint: .purple)
                    TextField(trimmedAddress.isEmpty ? "e.g. prod-web-01" : trimmedAddress, text: $draft.label)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 12) {
                    fieldLabel("Group", icon: "folder.fill", tint: .cyan)
                    TextField("Optional", text: $draft.group)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { item in
                                Button(item) { draft.group = item }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    fieldLabel("Tags", icon: "number.circle.fill", tint: .pink)
                    TextField("prod, tokyo", text: $draft.tags)
                        .multilineTextAlignment(.trailing)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
            }

            // MARK: Notes & VPS Renewal
            Section("Notes & VPS Renewal") {
                TextField("Notes / Comment (shown on card & detail)", text: $draft.comment, axis: .vertical)
                    .lineLimit(1 ... 4)

                Toggle(isOn: $draft.renewalEnabled) {
                    fieldLabel("VPS Renewal Reminder", icon: "calendar.badge.clock", tint: .orange)
                }

                if draft.renewalEnabled {
                    DatePicker(
                        "Renewal Date",
                        selection: $draft.renewalDate,
                        displayedComponents: .date
                    )

                    Picker("Billing Cycle", selection: $draft.renewalCycle) {
                        ForEach(RDMachine.RenewalCycle.allCases) { cycle in
                            Text(cycle.localizedTitle).tag(cycle)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Price")
                            .foregroundStyle(.secondary)
                        TextField("$5/mo", text: $draft.renewalPrice)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Remind Before", selection: $draft.renewalRemindDays) {
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                }
            }

            // MARK: Advanced
            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    HStack(spacing: 12) {
                        Text("SFTP Folder")
                            .foregroundStyle(.secondary)
                        TextField("Default: home", text: $draft.startFolder)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .disableAutocorrection(true)
                            .textInputAutocapitalization(.never)
                    }

                    Picker("Startup snippet", selection: $draft.startupSnippet) {
                        Text("None").tag(RDSnippet.ID?.none)
                        ForEach(snippetOptions, id: \.id) { snippet in
                            Text(snippet.name).tag(RDSnippet.ID?.some(snippet.id))
                        }
                    }

                    Toggle(isOn: $draft.shellIntegration) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shell integration")
                            Text("Files follows the terminal's current folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !draft.proxyCommand.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Proxy Command (macOS only)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(draft.proxyCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("iOS apps cannot spawn external proxy commands. Preserved for Mac sync.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }

                    if !isNew, !banner.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last Banner")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(banner)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    fieldLabel("Advanced", icon: "slider.horizontal.3", tint: .secondary)
                }
            }

            // MARK: Primary Action & Delete
            Section {
                Button {
                    connect()
                } label: {
                    HStack(spacing: 8) {
                        if connecting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting…")
                        } else {
                            Label("Save & Connect", systemImage: "terminal")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .appleProminentButton()
                .controlSize(.large)
                .disabled(!canSave || connecting)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))

            if let id = inEditWith {
                Section {
                    Button(role: .destructive) {
                        ServerActions.delete([id])
                        closeSheet()
                    } label: {
                        HStack(spacing: 12) {
                            AppleFeatureBadge(systemImage: "trash.fill", tint: .red, size: 28)
                            Text("Delete Server")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .appleGroupedBackground()
        .navigationTitle(isNew ? String(localized: "New Server") : String(localized: "Edit Server"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestClose() }
                    .disabled(connecting || isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveAndClose() }
                    .bold()
                    .disabled(!canSave || connecting || isSaving)
            }
        }
        .sheet(isPresented: $addsKey) {
            NavigationStack {
                EditIdentityView { created in
                    reloadSnapshots()
                    draft.key = created
                    draft.credential = .key
                    credentialsError = nil
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private func fieldLabel(_ title: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            AppleFeatureBadge(systemImage: icon, tint: tint, size: 28)
            Text(title)
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    // MARK: - Loading & Saving

    private func loadIfNeeded() {
        guard !initializedOnce else { return }
        initializedOnce = true
        reloadSnapshots()
        defer { loaded = draft }

        guard let machine = inEditWith else {
            if let first = keyOptions.first(where: { !$0.usesAgent }) {
                draft.credential = .key
                draft.key = first.id
            }
            return
        }

        let read = store.machineGroup[machine]
        draft.address = read.remoteAddress
        draft.label = read.name == read.remoteAddress ? "" : read.name
        draft.port = read.remotePort.isEmpty ? "22" : read.remotePort
        draft.group = read.group
        draft.tags = read.tags.joined(separator: ", ")
        draft.comment = read.comment
        draft.startFolder = read.startsInHomeFolder ? "" : read.fileTransferLoginPath
        draft.startupSnippet = read.startupSnippet
        draft.proxyCommand = read.proxyCommand
        draft.shellIntegration = read.shellIntegration
        draft.renewalEnabled = read.renewalEnabled
        if let date = read.renewalDate { draft.renewalDate = date }
        draft.renewalCycle = read.renewalCycle
        draft.renewalPrice = read.renewalPrice
        draft.renewalRemindDays = read.renewalRemindDays
        banner = read.lastBanner
        showsAdvanced = read.startupSnippet != nil
            || !read.startsInHomeFolder
            || !read.proxyCommand.isEmpty
            || read.shellIntegration

        let identity = read.associatedIdentity.flatMap(UUID.init(uuidString:)).map { store.identityGroup[$0] }
        let user = read.loginUsername(with: identity)
        draft.username = user == RDMachine.defaultUsername && read.username.isEmpty ? "" : user

        if read.signsInWithoutCredentials {
            draft.credential = .none
            return
        }
        guard let identity, identity.hasCredentials else { return }
        if identity.privateKey.isEmpty, !identity.usesAgent {
            draft.password = identity.password
            draft.credential = .password
        } else {
            draft.key = identity.id
            draft.credential = .key
        }
    }

    private var existingPrivateIdentity: RDIdentity? {
        guard let machine = inEditWith,
              let raw = store.machineGroup[machine].associatedIdentity,
              let id = UUID(uuidString: raw)
        else { return nil }
        let identity = store.identityGroup[id]
        return identity.isPrivate ? identity : nil
    }

    private func credentialsToUse() -> RDIdentity? {
        switch draft.credential {
        case .none:
            return nil
        case .key:
            return draft.key.map { store.identityGroup[$0] }
        case .password:
            guard !draft.password.isEmpty else { return nil }
            var identity = existingPrivateIdentity ?? RDIdentity(authenticAutomatically: false)
            identity.username = ""
            identity.password = draft.password
            identity.privateKey = ""
            identity.publicKey = ""
            identity.authenticAutomatically = false
            identity.isPrivate = true
            return identity
        }
    }

    private func credentialsProblem() -> String? {
        switch draft.credential {
        case .password where draft.password.isEmpty:
            return String(localized: "Type the password.")
        case .key where draft.key == nil:
            return keyOptions.isEmpty
                ? String(localized: "Add a key with New Key…")
                : String(localized: "Choose a key, or add one with New Key…")
        case .key:
            if let keyID = draft.key, store.identityGroup[keyID].usesAgent {
                return String(localized: "SSH agent keys are only available on macOS.")
            }
            return nil
        default:
            return nil
        }
    }

    private struct SavePayload {
        let machine: RDMachine
        let upsertPrivateIdentity: RDIdentity?
        let deletePrivateIdentityID: RDIdentity.ID?
    }

    private func buildSavePayload(banner capturedBanner: String? = nil) -> SavePayload {
        var target = inEditWith.map { store.machineGroup[$0] } ?? RDMachine(lastConnection: Date(timeIntervalSince1970: 0))
        target.remoteAddress = trimmedAddress
        target.remotePort = draft.port
        target.username = trimmedUsername
        target.name = draft.label.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedAddress : draft.label.trimmingCharacters(in: .whitespaces)
        target.group = draft.group.trimmingCharacters(in: .whitespaces)
        target.tags = draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        target.comment = draft.comment
        target.fileTransferLoginPath = draft.startFolder.trimmingCharacters(in: .whitespaces)
        target.startupSnippet = draft.startupSnippet
        target.proxyCommand = draft.proxyCommand
        target.shellIntegration = draft.shellIntegration
        target.renewalEnabled = draft.renewalEnabled
        target.renewalDate = draft.renewalEnabled ? draft.renewalDate : nil
        target.renewalCycle = draft.renewalCycle
        target.renewalPrice = draft.renewalPrice
        target.renewalRemindDays = draft.renewalRemindDays

        let previousPrivate = existingPrivateIdentity
        let identity = credentialsToUse()
        target.associatedIdentity = identity?.id.uuidString
        target.signsInWithoutCredentials = draft.credential == .none

        if let capturedBanner {
            target.lastBanner = capturedBanner
            target.lastConnection = Date()
        }

        return SavePayload(
            machine: target,
            upsertPrivateIdentity: (identity?.isPrivate == true) ? identity : nil,
            deletePrivateIdentityID: (previousPrivate != nil && previousPrivate?.id != identity?.id) ? previousPrivate?.id : nil
        )
    }

    private static func commit(_ payload: SavePayload) {
        let store = TamioStore.shared
        if payload.upsertPrivateIdentity != nil || payload.deletePrivateIdentityID != nil {
            var identities = store.identityGroup
            if let identity = payload.upsertPrivateIdentity {
                identities.insert(identity)
            }
            if let removed = payload.deletePrivateIdentityID {
                identities.delete(removed)
            }
            store.identityGroup = identities
        }
        store.machineGroup.insert(payload.machine)
    }

    private func saveAndClose() {
        guard canSave, !isSaving else { return }
        isSaving = true
        let payload = buildSavePayload()
        loaded = draft
        // Close the modal and resign the keyboard immediately before mutating
        // TamioStore so SwiftUI/UIKit sheet teardown never stalls behind
        // Home/Servers redraws or LiveStatusCenter session setup.
        closeSheet()
        DispatchQueue.main.async {
            Self.commit(payload)
        }
    }

    private func requestClose() {
        guard isDirty else {
            closeSheet()
            return
        }
        UIBridge.requiresConfirmation(
            message: isNew ? String(localized: "Discard this new server?") : String(localized: "Discard your changes?"),
            confirmTitle: String(localized: "Discard"),
            destructive: true
        ) { confirmed in
            if confirmed { closeSheet() }
        }
    }

    private func connect() {
        guard canSave, !connecting else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        addressError = nil
        credentialsError = credentialsProblem()
        guard credentialsError == nil else { return }

        if !draft.proxyCommand.isEmpty {
            addressError = String(localized: "Proxy commands are only supported on macOS.")
            return
        }

        connecting = true
        let host = trimmedAddress
        let port = draft.port
        let username = trimmedUsername
        let chosen = credentialsToUse()
        let timeout = store.timeoutNumber

        DispatchQueue.global().async {
            let shell = NSRemoteShell.configured(host: host, port: port, timeout: timeout)
            shell.requestConnectAndWait()
            guard shell.isConnected else {
                let refusal = shell.hostKeyRefusal
                let failure = shell.getLastError()
                shell.destroyPermanently()
                onMainThread {
                    connecting = false
                    addressError = refusal ?? failure ?? String(localized: "Could not reach \(host) on port \(port).")
                }
                return
            }
            if let chosen {
                chosen.callAuthenticationWith(remote: shell, username: username)
            } else {
                shell.authenticateWithoutCredentials(username)
            }
            let authenticated = shell.isAuthenticated
            let wanted = authenticated ? nil : shell.getLastError()
            let remoteBanner = shell.remoteBanner ?? ""
            // Tear down the probe socket asynchronously so Save & Connect
            // never waits on a slow remote disconnect handshake.
            shell.destroyPermanently()

            onMainThread {
                connecting = false
                if authenticated {
                    let payload = buildSavePayload(banner: remoteBanner)
                    loaded = draft
                    closeSheet()
                    DispatchQueue.main.async {
                        Self.commit(payload)
                        onMainThread(delay: 0.25) {
                            TerminalManager.shared.begin(for: payload.machine.id)
                        }
                    }
                } else if let chosen {
                    let refused = String(localized: "\(host) did not accept this key for \(username). Add its public key to ~/.ssh/authorized_keys there.")
                    credentialsError = chosen.privateKey.isEmpty
                        ? String(localized: "\(username) could not sign in to \(host) with this password.")
                        : refused
                } else {
                    credentialsError = [String(localized: "\(host) did not let \(username) in without a password or key."), wanted]
                        .compactMap { $0 }
                        .joined(separator: " ")
                }
            }
        }
    }
}

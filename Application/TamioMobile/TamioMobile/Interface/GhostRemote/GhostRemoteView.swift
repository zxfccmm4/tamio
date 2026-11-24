//
//  GhostRemoteView.swift
//  TamioMobile
//
//  Native Apple HIG Ghost Remote view for discovering nearby iGhostVT hosts
//  on LAN (`_ighostvt._tcp`), pairing with a 6-digit code, importing `.vtrpsc`
//  Relay configurations, and opening non-jailbreak remote terminals.
//

import SwiftUI
import TamioDesign
import TamioModule
import TamioTerminal
import UniformTypeIdentifiers

struct GhostRemoteView: View {
    @ObservedObject private var browser = GhostRemoteBrowser.shared
    @ObservedObject private var remoteStore = GhostRemoteStore.shared
    @ObservedObject private var sessionManager = GhostRemoteSessionManager.shared

    @State private var pairingTarget: GhostDiscoveredHost?
    @State private var showingManualPair = false
    @State private var activeSession: GhostRemoteSession?

    var body: some View {
        List {
            // MARK: Paired Devices
            Section("Paired Devices") {
                if remoteStore.pairedHosts.isEmpty {
                    Text("No paired devices yet. Enable Remote Access on your Mac or iGhostVT device and pair with its 6-digit code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteStore.pairedHosts) { host in
                        Button {
                            activeSession = sessionManager.openSession(for: host)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(host.address):\(host.port)" + (host.usesRelay ? " · " + String(localized: "Relay") : ""))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "terminal")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Unpair", role: .destructive) {
                                remoteStore.removePairedHost(host.id)
                            }
                        }
                    }
                }
            }

            // MARK: Nearby LAN Devices
            Section("Nearby on Local Network") {
                if browser.hosts.isEmpty {
                    HStack(spacing: 10) {
                        if browser.isScanning {
                            ProgressView()
                        }
                        Text(browser.lastError ?? String(localized: "Scanning local network for _ighostvt._tcp hosts…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(browser.hosts) { discovered in
                        HStack(spacing: 12) {
                            Image(systemName: "wifi")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovered.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(discovered.address):\(discovered.port)" + (discovered.appVersion.isEmpty ? "" : " · v\(discovered.appVersion)"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Pair") {
                                pairingTarget = discovered
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button {
                                pairingTarget = discovered
                            } label: {
                                Label("Pair with 6-Digit Code", systemImage: "key")
                            }
                            Button {
                                addAsSSHServer(discovered)
                            } label: {
                                Label("Add as SSH Server", systemImage: "server.rack")
                            }
                        }
                    }
                }
            }

            // MARK: Relay Configuration (.vtrpsc)
            Section("Relay Server") {
                if let relay = remoteStore.relay {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(relay.name)
                                    .font(.body.weight(.medium))
                                Text(relay.endpointDescription)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Active")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        Text(relay.fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)

                    Button(role: .destructive) {
                        remoteStore.removeRelay()
                    } label: {
                        Label("Remove Relay Configuration", systemImage: "trash")
                    }
                } else {
                    Text("Import a .vtrpsc file from your self-hosted iGhostVT Relay server to reach paired devices outside your local network.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                FilePicker(types: [.item], allowMultiple: false) { urls in
                    guard let url = urls.first else { return }
                    importRelay(from: url)
                } label: {
                    Label("Import .vtrpsc Relay File…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ghost Remote")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingManualPair = true
                } label: {
                    Label("Pair Manually", systemImage: "plus")
                }
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .sheet(item: $pairingTarget) { host in
            NavigationStack {
                GhostRemotePairSheet(
                    initialName: host.name,
                    initialAddress: host.address,
                    initialPort: host.port,
                    hostID: host.id,
                    appVersion: host.appVersion
                )
            }
        }
        .sheet(isPresented: $showingManualPair) {
            NavigationStack {
                GhostRemotePairSheet()
            }
        }
        .fullScreenCover(item: $activeSession) { session in
            NavigationStack {
                GhostRemoteTerminalView(session: session)
            }
        }
    }

    private func importRelay(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try remoteStore.importRelay(data: data)
        } catch {
            UIBridge.presentError(with: error.localizedDescription)
        }
    }

    private func addAsSSHServer(_ discovered: GhostDiscoveredHost) {
        var machine = RDMachine(
            remoteAddress: discovered.address,
            remotePort: "22",
            name: discovered.name
        )
        machine.group = String(localized: "Local Network")
        TamioStore.shared.machineGroup.insert(machine)
    }
}

private struct GhostRemotePairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var remoteStore = GhostRemoteStore.shared

    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var code = ""
    @State private var usesRelay: Bool

    private let hostID: String
    private let appVersion: String

    init(
        initialName: String = "",
        initialAddress: String = "",
        initialPort: UInt16 = GhostRemoteConstants.defaultPort,
        hostID: String = UUID().uuidString.lowercased(),
        appVersion: String = ""
    ) {
        _name = State(initialValue: initialName)
        _address = State(initialValue: initialAddress)
        _port = State(initialValue: "\(initialPort)")
        _usesRelay = State(initialValue: GhostRemoteStore.shared.relay != nil && initialAddress.isEmpty)
        self.hostID = hostID
        self.appVersion = appVersion
    }

    private var cleanCode: String { code.filter(\.isNumber) }

    private var canPair: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
            && cleanCode.count == 6
    }

    var body: some View {
        Form {
            Section("Remote Device") {
                TextField("Device name", text: $name)
                TextField("Address (IP or hostname)", text: $address)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                TextField("Port", text: $port)
                    .font(.body.monospaced())
                    .keyboardType(.numberPad)
                if remoteStore.relay != nil {
                    Toggle("Connect through Relay", isOn: $usesRelay)
                }
            }

            Section {
                TextField("000000", text: $code)
                    .font(.title2.weight(.semibold).monospaced())
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .onChange(of: code) { _, next in
                        let digits = String(next.filter(\.isNumber).prefix(6))
                        if code != digits { code = digits }
                    }
            } header: {
                Text("Pairing Code")
            } footer: {
                Text("Enter the 6-digit code shown under Remote Access on the other device.")
            }
        }
        .navigationTitle("Pair Ghost Remote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair") { completePairing() }
                    .bold()
                    .disabled(!canPair)
            }
        }
    }

    private func completePairing() {
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let parsedPort = UInt16(port) ?? GhostRemoteConstants.defaultPort
        let psk = GhostRemoteTLS.derivePairingKey(
            from: cleanCode,
            hostID: hostID,
            deviceID: remoteStore.deviceID
        )
        let host = GhostPairedHost(
            id: hostID,
            name: trimmedName.isEmpty ? trimmedAddress : trimmedName,
            address: trimmedAddress,
            port: parsedPort,
            pairedAt: Date(),
            usesRelay: usesRelay,
            lastVersion: appVersion
        )
        remoteStore.savePairedHost(host, preSharedKey: psk)
        dismiss()
    }
}

struct GhostRemoteTerminalView: View {
    @ObservedObject var session: GhostRemoteSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var findState = TerminalFindState()
    @State private var isLocked = false

    var body: some View {
        VStack(spacing: 0) {
            if case let .failed(reason) = session.state {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Reconnect") { session.connect() }
                        .appleProminentButton()
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }

            ZStack(alignment: .bottom) {
                session.termInterface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if findState.isPresented {
                    TerminalFindBar(state: findState, terminal: session.termInterface)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(session.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if findState.isPresented {
                        findState.dismiss(on: session.termInterface)
                    } else {
                        findState.present(on: session.termInterface)
                    }
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                Button {
                    isLocked.toggle()
                    session.termInterface.setInteractionLocked(isLocked)
                } label: {
                    Label(isLocked ? String(localized: "Unlock") : String(localized: "Lock"), systemImage: isLocked ? "lock.fill" : "lock.open")
                }
                Button(role: .destructive) {
                    GhostRemoteSessionManager.shared.closeSession(session.id)
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
            }
        }
        .onAppear {
            KeepAwakeController.setTerminalVisible(true)
            session.termInterface.setActive(true)
        }
        .onDisappear {
            KeepAwakeController.setTerminalVisible(false)
            session.termInterface.setActive(false)
        }
    }
}

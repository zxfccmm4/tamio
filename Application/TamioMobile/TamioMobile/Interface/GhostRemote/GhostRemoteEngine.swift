//
//  GhostRemoteEngine.swift
//  TamioMobile
//
//  Non-jailbreak Ghost Remote networking engine using public Apple APIs only:
//  - NWBrowser for `_ighostvt._tcp` LAN host discovery
//  - NWProtocolTLS 1.2 PSK client handshake + HKDF/HMAC device proof
//  - Ghostty terminal session bridge with Live Activities & Background Grace
//

import CryptoKit
import Foundation
import Network
import Security
import TamioTerminal

@MainActor
final class GhostRemoteBrowser: ObservableObject {
    static let shared = GhostRemoteBrowser()

    @Published private(set) var hosts: [GhostDiscoveredHost] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "sb.moe.tamio.ghostRemote.bonjour")

    private init() {}

    func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: GhostRemoteConstants.bonjourServiceType,
            domain: nil
        )
        let params = NWParameters()
        params.includePeerToPeer = true
        let next = NWBrowser(for: descriptor, using: params)
        next.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isScanning = true
                    self.lastError = nil
                case let .failed(error):
                    self.isScanning = false
                    self.lastError = error.localizedDescription
                case .cancelled:
                    self.isScanning = false
                default:
                    break
                }
            }
        }
        next.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed = results.compactMap(Self.parseResult)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.hosts = parsed
            }
        }
        browser = next
        next.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    nonisolated private static func parseResult(_ result: NWBrowser.Result) -> GhostDiscoveredHost? {
        guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            for key in ["id", "name", "v", "ip", "av"] {
                if let value = record[key] { txt[key] = value }
            }
        }
        let hostID = txt["id"] ?? serviceName
        let name = txt["name"] ?? serviceName
        let address = txt["ip"] ?? serviceName
        let protoVersion = txt["v"] ?? "1"
        let appVersion = txt["av"] ?? ""
        return GhostDiscoveredHost(
            id: hostID,
            name: name,
            address: address,
            port: GhostRemoteConstants.defaultPort,
            protocolVersion: protoVersion,
            appVersion: appVersion,
            endpoint: result.endpoint
        )
    }
}

enum GhostRemoteTLS {
    static func makeParameters(psk: Data, identity: String, sni: String? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0x00A8)!) // TLS_PSK_WITH_AES_128_GCM_SHA256
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0x00A9)!) // TLS_PSK_WITH_AES_256_GCM_SHA384

        if let sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(sec, sni)
        }

        let pskDispatch = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDispatch = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, pskDispatch as __DispatchData, idDispatch as __DispatchData)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 10
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func derivePairingKey(from sixDigitCode: String, hostID: String, deviceID: String) -> Data {
        let ikm = SymmetricKey(data: Data("\(sixDigitCode):\(hostID):\(deviceID)".utf8))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: GhostRemoteConstants.pairingPSK,
            info: Data("tamio-ghostremote-psk-v1".utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

@MainActor
final class GhostRemoteSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    let id = UUID()
    let host: GhostPairedHost
    let termInterface = TamioTerminalView()
    @Published private(set) var state: State = .connecting

    var hostName: String { host.name }

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sb.moe.tamio.ghostRemote.session")

    init(host: GhostPairedHost) {
        self.host = host
        termInterface.setInputAccessoryItems(KeyboardBarStore.shared.items)
        termInterface.setupBufferChain { [weak self] input in
            self?.send(Data(input.utf8))
        }
    }

    func connect() {
        state = .connecting
        termInterface.write("\r\n[Ghost Remote] Connecting to \(host.name) (\(host.address):\(host.port))…\r\n")

        guard let psk = GhostRemoteStore.shared.preSharedKey(for: host.id) else {
            state = .failed(String(localized: "Missing pairing key for \(host.name). Pair again to reconnect."))
            return
        }

        let endpoint: NWEndpoint
        let sni: String?
        if host.usesRelay, let relay = GhostRemoteStore.shared.relay {
            endpoint = .hostPort(host: NWEndpoint.Host(relay.host), port: NWEndpoint.Port(rawValue: relay.port) ?? .any)
            sni = host.id
        } else {
            endpoint = .hostPort(host: NWEndpoint.Host(host.address), port: NWEndpoint.Port(rawValue: host.port) ?? .any)
            sni = nil
        }

        let params = GhostRemoteTLS.makeParameters(psk: psk, identity: GhostRemoteStore.shared.deviceID, sni: sni)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] connState in
            Task { @MainActor in
                guard let self else { return }
                switch connState {
                case .ready:
                    self.state = .connected
                    self.termInterface.write(String(localized: "[Ghost Remote] TLS-PSK tunnel established.") + "\r\n")
                    GhostRemoteSessionManager.shared.notifyStateChange()
                    self.receiveLoop(conn)
                case let .waiting(error):
                    self.state = .failed(error.localizedDescription)
                    self.termInterface.write("\r\n" + String(localized: "[Ghost Remote] Waiting: \(error.localizedDescription)") + "\r\n")
                    GhostRemoteSessionManager.shared.notifyStateChange()
                case let .failed(error):
                    self.state = .failed(error.localizedDescription)
                    self.termInterface.write("\r\n" + String(localized: "[Ghost Remote] Connection failed: \(error.localizedDescription)") + "\r\n")
                    GhostRemoteSessionManager.shared.notifyStateChange()
                case .cancelled:
                    self.state = .closed
                    GhostRemoteSessionManager.shared.notifyStateChange()
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .closed
        GhostRemoteSessionManager.shared.notifyStateChange()
    }

    nonisolated private func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.connection?.send(content: data, completion: .idempotent)
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let chunk = String(decoding: data, as: UTF8.self)
                    self.termInterface.write(chunk)
                }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    self.termInterface.write("\r\n" + String(localized: "[Ghost Remote] Closed: \(error.localizedDescription)") + "\r\n")
                    GhostRemoteSessionManager.shared.notifyStateChange()
                } else if isComplete {
                    self.state = .closed
                    self.termInterface.write("\r\n" + String(localized: "[Ghost Remote] Session ended by remote host.") + "\r\n")
                    GhostRemoteSessionManager.shared.notifyStateChange()
                } else {
                    self.receiveLoop(conn)
                }
            }
        }
    }
}

@MainActor
final class GhostRemoteSessionManager: ObservableObject {
    static let shared = GhostRemoteSessionManager()

    @Published private(set) var sessions: [GhostRemoteSession] = []

    private init() {}

    @discardableResult
    func openSession(for host: GhostPairedHost) -> GhostRemoteSession {
        let session = GhostRemoteSession(host: host)
        sessions.append(session)
        session.connect()
        notifyStateChange()
        return session
    }

    func closeSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: idx)
        session.disconnect()
        notifyStateChange()
    }

    func notifyStateChange() {
        BackgroundGraceController.noteSessionsChanged()
        SessionActivityController.shared.sync()
    }
}

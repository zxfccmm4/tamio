//
//  GhostRemoteModels.swift
//  TamioMobile
//
//  App Store-safe data models for iGhostVT Ghost Remote interoperability:
//  - Bonjour `_ighostvt._tcp` TXT discovery records
//  - `.vtrpsc` self-hosted Relay configuration parser/validator (format v1, P-256)
//  - Paired Ghost Remote host storage
//

import CryptoKit
import Foundation
import Keychain
import Network

enum GhostRemoteConstants {
    static let defaultPort: UInt16 = 46404
    static let defaultRelayPort: UInt16 = 46405
    static let bonjourServiceType = "_ighostvt._tcp"
    static let relayFormat = "ighostvt-relay"
    static let relayFormatVersion = 1
    static let exporterLabel = "EXPORTER-ighostvt-v1"
    static let exporterByteCount = 32
    static let pairingPSK = Data("ighostvt-pairing-psk-v1".utf8)
}

struct GhostRelayConfiguration: Codable, Equatable, Sendable {
    enum ParseError: LocalizedError {
        case notConfiguration
        case unsupportedVersion
        case invalid

        var errorDescription: String? {
            switch self {
            case .notConfiguration:
                return String(localized: "This file is not a valid iGhostVT relay configuration (.vtrpsc).")
            case .unsupportedVersion:
                return String(localized: "This relay configuration uses an unsupported version.")
            case .invalid:
                return String(localized: "This relay configuration file is damaged or missing required fields.")
            }
        }
    }

    var name: String
    var host: String
    var port: UInt16
    var relayID: String
    var key: Data

    init(name: String, host: String, port: UInt16, relayID: String, key: Data) {
        self.name = name
        self.host = host
        self.port = port
        self.relayID = relayID
        self.key = key
    }

    init(vtrpscData data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == GhostRemoteConstants.relayFormat
        else { throw ParseError.notConfiguration }

        guard (object["version"] as? Int) == GhostRemoteConstants.relayFormatVersion else {
            throw ParseError.unsupportedVersion
        }

        guard let endpoint = object["endpoint"] as? String,
              let (parsedHost, parsedPort) = Self.splitEndpoint(endpoint),
              let relayID = object["relayID"] as? String, !relayID.isEmpty,
              let encodedKey = object["key"] as? String,
              let rawKey = Data(base64Encoded: encodedKey),
              (try? P256.Signing.PrivateKey(rawRepresentation: rawKey)) != nil
        else { throw ParseError.invalid }

        let displayName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (displayName?.isEmpty == false ? displayName! : relayID)
        self.host = parsedHost
        self.port = parsedPort
        self.relayID = relayID
        self.key = rawKey
    }

    var endpointDescription: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    var fingerprint: String {
        guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: key) else { return relayID }
        let digest = SHA256.hash(data: privateKey.publicKey.derRepresentation)
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(relayID)/\(prefix)@\(endpointDescription)"
    }

    private static func splitEndpoint(_ endpoint: String) -> (String, UInt16)? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
            let remainder = trimmed[trimmed.index(after: close)...]
            if remainder.isEmpty { return (host, GhostRemoteConstants.defaultRelayPort) }
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        if let colon = trimmed.lastIndex(of: ":"), trimmed.firstIndex(of: ":") == colon {
            let host = String(trimmed[..<colon])
            guard !host.isEmpty, let port = UInt16(trimmed[trimmed.index(after: colon)...]), port > 0 else { return nil }
            return (host, port)
        }
        return (trimmed, GhostRemoteConstants.defaultRelayPort)
    }
}

struct GhostDiscoveredHost: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let address: String
    let port: UInt16
    let protocolVersion: String
    let appVersion: String
    let endpoint: NWEndpoint

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.address == rhs.address && lhs.port == rhs.port
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct GhostPairedHost: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var address: String
    var port: UInt16
    var pairedAt: Date
    var usesRelay: Bool
    var lastVersion: String
}

@MainActor
final class GhostRemoteStore: ObservableObject {
    static let shared = GhostRemoteStore()

    private static let hostsKey = "sb.moe.tamio.ghostRemote.pairedHosts"
    private static let relayKeychainService = "sb.moe.tamio.ghostRemote"
    private static let relayKeychainAccount = "relay-config"
    private static let deviceIDKey = "sb.moe.tamio.ghostRemote.deviceID"

    @Published private(set) var pairedHosts: [GhostPairedHost] = []
    @Published private(set) var relay: GhostRelayConfiguration?

    let deviceID: String
    private let keychain = Keychain(service: GhostRemoteStore.relayKeychainService)

    private init() {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDKey), !existing.isEmpty {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString.lowercased()
            UserDefaults.standard.set(fresh, forKey: Self.deviceIDKey)
            deviceID = fresh
        }
        load()
    }

    func savePairedHost(_ host: GhostPairedHost, preSharedKey: Data) {
        try? keychain.set(preSharedKey.base64EncodedString(), key: "psk.\(host.id)")
        var updated = pairedHosts.filter { $0.id != host.id }
        updated.append(host)
        updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        pairedHosts = updated
        persistHosts()
    }

    func preSharedKey(for hostID: String) -> Data? {
        guard let encoded = try? keychain.getString("psk.\(hostID)") else { return nil }
        return Data(base64Encoded: encoded)
    }

    func removePairedHost(_ hostID: String) {
        try? keychain.remove("psk.\(hostID)")
        pairedHosts.removeAll { $0.id == hostID }
        persistHosts()
    }

    func importRelay(data: Data) throws -> GhostRelayConfiguration {
        let config = try GhostRelayConfiguration(vtrpscData: data)
        if let encoded = try? JSONEncoder().encode(config) {
            try? keychain.set(encoded.base64EncodedString(), key: Self.relayKeychainAccount)
        }
        relay = config
        return config
    }

    func removeRelay() {
        try? keychain.remove(Self.relayKeychainAccount)
        relay = nil
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.hostsKey),
           let decoded = try? JSONDecoder().decode([GhostPairedHost].self, from: data)
        {
            pairedHosts = decoded
        }
        if let encoded = try? keychain.getString(Self.relayKeychainAccount),
           let data = Data(base64Encoded: encoded),
           let decoded = try? JSONDecoder().decode(GhostRelayConfiguration.self, from: data)
        {
            relay = decoded
        }
    }

    private func persistHosts() {
        if let data = try? JSONEncoder().encode(pairedHosts) {
            UserDefaults.standard.set(data, forKey: Self.hostsKey)
        }
    }
}

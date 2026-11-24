//
//  TamioShortcuts.swift
//  TamioMobile
//
//  Apple Shortcuts & Siri AppIntents integration inspired by iGhostVT:
//  - Open a Ghostty terminal tab on any saved server
//  - Run a one-shot SSH command and return its output to Shortcuts
//  - Read live screen / transcript text from an active terminal tab
//  - Send text / keystrokes to an active terminal tab
//

import AppIntents
import Foundation
import MachineStatus
import NSRemoteShell
import TamioModule

// MARK: - App Entities

struct ServerAppEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerEntityQuery()

    let id: UUID
    let name: String
    let address: String
    let group: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: group.isEmpty ? "\(address)" : "\(group) · \(address)",
            image: .init(systemName: "server.rack")
        )
    }
}

struct ServerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerAppEntity] {
        await MainActor.run {
            let store = TamioStore.shared
            return identifiers.compactMap { id in
                let m = store.machineGroup[id]
                guard m.isNotPlaceholder() else { return nil }
                return ServerAppEntity(id: m.id, name: m.name, address: m.remoteAddress, group: m.group)
            }
        }
    }

    func entities(matching string: String) async throws -> [ServerAppEntity] {
        await MainActor.run {
            let machines = TamioStore.shared.machineGroup.machines
            let matched = string.isEmpty ? machines : machines.filter { $0.isQualifiedForSearch(text: string) }
            return matched.map { ServerAppEntity(id: $0.id, name: $0.name, address: $0.remoteAddress, group: $0.group) }
        }
    }

    func suggestedEntities() async throws -> [ServerAppEntity] {
        await MainActor.run {
            TamioStore.shared.machineGroup.machines
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { ServerAppEntity(id: $0.id, name: $0.name, address: $0.remoteAddress, group: $0.group) }
        }
    }
}

struct TerminalSessionAppEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal Session")
    static let defaultQuery = TerminalSessionEntityQuery()

    let id: UUID
    let title: String
    let isClosed: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: isClosed ? "Closed" : "Active",
            image: .init(systemName: "terminal")
        )
    }
}

struct TerminalSessionEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [TerminalSessionAppEntity] {
        await MainActor.run {
            TerminalManager.shared.terminals
                .filter { identifiers.contains($0.id) }
                .map { term in
                    TerminalSessionAppEntity(
                        id: term.id,
                        title: term.machine.isNotPlaceholder() ? term.machine.name : term.navigationTitle,
                        isClosed: term.closed
                    )
                }
        }
    }

    func suggestedEntities() async throws -> [TerminalSessionAppEntity] {
        await MainActor.run {
            TerminalManager.shared.terminals.map { term in
                TerminalSessionAppEntity(
                    id: term.id,
                    title: term.machine.isNotPlaceholder() ? term.machine.name : term.navigationTitle,
                    isClosed: term.closed
                )
            }
        }
    }
}

// MARK: - Shortcut Errors

enum TamioShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case serverNotFound
    case sessionNotFound
    case connectionFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .serverNotFound:
            return "The selected server could not be found."
        case .sessionNotFound:
            return "The selected terminal session is no longer open."
        case let .connectionFailed(reason):
            return "Could not connect to the server: \(reason)"
        }
    }
}

// MARK: - Intents

struct OpenServerTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Server Terminal"
    static let description = IntentDescription("Opens a Ghostty SSH terminal tab for the chosen server in Tamio.")
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerAppEntity

    @Parameter(title: "Startup Command", default: "")
    var command: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let machine = TamioStore.shared.machineGroup[server.id]
        guard machine.isNotPlaceholder() else { throw TamioShortcutError.serverNotFound }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            TerminalManager.shared.begin(for: server.id, force: true)
        } else {
            TerminalManager.shared.begin(for: server.id, running: trimmed)
        }
        return .result()
    }
}

struct RunSSHCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run SSH Command"
    static let description = IntentDescription("Runs a shell command on a saved server over SSH and returns its output.")
    static let openAppWhenRun = false

    @Parameter(title: "Server")
    var server: ServerAppEntity

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Timeout (seconds)", default: 20)
    var timeoutSeconds: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = TamioStore.shared
        let machine = store.workerMachine(for: server.id)
        guard machine.isNotPlaceholder() else { throw TamioShortcutError.serverNotFound }

        let identity = store.workerAssociatedIdentity(for: machine)
        let autoIdentities = store.workerIdentitiesForAutoAuth
        let connectTimeout = store.workerTimeoutNumber
        let execTimeout = Double(max(5, min(120, timeoutSeconds)))
        let cmd = command

        let output: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let shell = NSRemoteShell.configured(for: machine, timeout: connectTimeout)
                defer { shell.destroyPermanently() }

                let result = shell.connectAndAuthenticate(
                    identity: identity,
                    autoIdentities: autoIdentities,
                    for: machine
                )
                guard result == .success else {
                    let message = shell.hostKeyRefusal ?? shell.getLastError() ?? "Authentication failed."
                    continuation.resume(throwing: TamioShortcutError.connectionFailed(message))
                    return
                }
                let text = ServerStatus.downloadResultFrom(shell: shell, command: cmd, timeout: execTimeout)
                continuation.resume(returning: text)
            }
        }
        return .result(value: output)
    }
}

struct ReadTerminalOutputIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Terminal Output"
    static let description = IntentDescription("Captures visible screen text or scrollback transcript from an open Tamio terminal.")
    static let openAppWhenRun = false

    @Parameter(title: "Terminal Session")
    var session: TerminalSessionAppEntity

    @Parameter(title: "Include Full Scrollback", default: false)
    var fullTranscript: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let term = TerminalManager.shared.terminals.first(where: { $0.id == session.id }) else {
            throw TamioShortcutError.sessionNotFound
        }
        let text: String = if fullTranscript {
            term.termInterface.readTranscript()
        } else {
            term.termInterface.readViewportText() ?? term.termInterface.readTranscript()
        }
        return .result(value: text)
    }
}

struct SendTerminalInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Input to Terminal"
    static let description = IntentDescription("Sends text to an active Tamio terminal session.")
    static let openAppWhenRun = false

    @Parameter(title: "Terminal Session")
    var session: TerminalSessionAppEntity

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Press Return", default: true)
    var pressReturn: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let term = TerminalManager.shared.terminals.first(where: { $0.id == session.id }) else {
            throw TamioShortcutError.sessionNotFound
        }
        let payload = pressReturn ? text + "\n" : text
        term.termInterface.sendInputText(payload)
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct TamioAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenServerTerminalIntent(),
            phrases: [
                "Open terminal in \(.applicationName)",
                "Connect to \(\.$server) in \(.applicationName)",
            ],
            shortTitle: "Open Terminal",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: RunSSHCommandIntent(),
            phrases: [
                "Run SSH command in \(.applicationName)",
                "Run command on \(\.$server) in \(.applicationName)",
            ],
            shortTitle: "Run SSH Command",
            systemImageName: "chevron.left.forwardslash.chevron.right"
        )
        AppShortcut(
            intent: ReadTerminalOutputIntent(),
            phrases: [
                "Read terminal output in \(.applicationName)",
            ],
            shortTitle: "Read Terminal Output",
            systemImageName: "doc.text.magnifyingglass"
        )
    }
}

//
//  TerminalManager.swift
//  TamioMobile
//
//  Manages active SSH terminal sessions, network-recovery auto-reconnect,
//  custom keyboard bar updates, background grace, and Live Activities sync.
//

import Combine
import SwiftUI
import TamioModule

@MainActor
class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    @Published var terminals: [TerminalContext] = [] {
        didSet {
            BackgroundGraceController.noteSessionsChanged()
            SessionActivityController.shared.sync()
        }
    }

    @Published var activeTerminalID: UUID?

    private var observers: [NSObjectProtocol] = []

    private init() {
        TerminalInterface.uiHandler = IOSTerminalUIHandler()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: KeyboardBarStore.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for term in TerminalManager.shared.terminals {
                        term.applyKeyboardBar()
                    }
                }
            },
            center.addObserver(forName: NetworkPathWatcher.pathDidChange, object: nil, queue: .main) { note in
                let satisfied = (note.userInfo?[NetworkPathWatcher.isSatisfiedKey] as? Bool) ?? true
                MainActor.assumeIsolated {
                    guard satisfied, MobileTerminalPreferences.autoReconnect else { return }
                    TerminalManager.shared.reconnectDroppedSessions()
                }
            },
        ]
    }

    func begin(for machineId: RDMachine.ID, force: Bool = false) {
        assert(Thread.isMainThread, "accessing to property terminals requires main thread")
        if !force {
            for terminal in terminals where terminal.machine.id == machineId {
                UIBridge.requiresConfirmation(
                    message: String(localized: "Another terminal for this machine is already running")
                ) { confirmed in
                    guard confirmed else { return }
                    self.begin(for: machineId, force: true)
                }
                return
            }
        }
        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: String(localized: "Unknown Bad Data"))
            return
        }
        let object = TerminalContext(machine: machine)
        TamioStore.shared.storeRecentIfNeeded(from: machineId)
        terminals.append(object)
        activeTerminalID = object.id
    }

    func begin(for machineId: RDMachine.ID, running command: String) {
        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: String(localized: "Unknown Bad Data"))
            return
        }
        let object = TerminalContext(machine: machine)
        object.initialCommand = command
        TamioStore.shared.storeRecentIfNeeded(from: machineId)
        terminals.append(object)
        activeTerminalID = object.id
    }

    func begin(for command: SSHCommandReader, force: Bool = false) {
        assert(Thread.isMainThread, "accessing to property terminals requires main thread")
        if !force {
            for terminal in terminals where terminal.command == command {
                UIBridge.requiresConfirmation(
                    message: String(localized: "Another terminal for this command is already running")
                ) { confirmed in
                    guard confirmed else { return }
                    self.begin(for: command, force: true)
                }
                return
            }
        }
        let object = TerminalContext(command: command)
        terminals.append(object)
        activeTerminalID = object.id
    }

    func end(for contextId: UUID) {
        onMainThread { [self] in
            guard let index = terminals.firstIndex(where: { $0.id == contextId }) else { return }
            let term = terminals.remove(at: index)
            term.processShutdown()
            term.destroyedSession = true
            if activeTerminalID == contextId {
                activeTerminalID = terminals.last?.id
            }
        }
    }

    func reconnectDroppedSessions() {
        for terminal in terminals where terminal.closed && !terminal.destroyedSession {
            terminal.reconnect()
        }
    }

    func neighbor(of id: UUID, delta: Int) -> TerminalContext? {
        guard terminals.count > 1, let idx = terminals.firstIndex(where: { $0.id == id }) else { return nil }
        let next = (idx + delta + terminals.count) % terminals.count
        return terminals[next]
    }
}

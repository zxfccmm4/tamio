//
//  MobileTerminalLifecycle.swift
//  TamioMobile
//
//  Mobile reliability primitives inspired by iGhostVT (MIT):
//  - NetworkPathWatcher: detects Wi-Fi / cellular handovers with settle delay
//    so dropped SSH/Ghost Remote sessions recover promptly.
//  - BackgroundGraceController: requests a standard UIKit background task
//    while sessions are active so brief app switches keep TCP sockets alive.
//  - KeepAwakeController: prevents auto-lock while an active terminal is visible.
//

import Foundation
import Network
import UIKit

enum MobileTerminalPreferences {
    static let keepScreenAwakeKey = "sb.moe.tamio.mobile.keepScreenAwake"
    static let autoReconnectKey = "sb.moe.tamio.mobile.autoReconnect"

    static var keepScreenAwake: Bool {
        UserDefaults.standard.object(forKey: keepScreenAwakeKey) as? Bool ?? true
    }

    static var autoReconnect: Bool {
        UserDefaults.standard.object(forKey: autoReconnectKey) as? Bool ?? true
    }
}

final class NetworkPathWatcher: @unchecked Sendable {
    static let shared = NetworkPathWatcher()

    static let pathDidChange = Notification.Name("sb.moe.tamio.network-path-changed")
    static let isSatisfiedKey = "isSatisfied"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sb.moe.tamio.network-path")
    private let lock = NSLock()
    private var satisfied = true
    private var signature: String?
    private var settleGeneration = 0
    private static let settleDelay: TimeInterval = 0.4

    var isSatisfied: Bool {
        lock.withLock { satisfied }
    }

    private init() {}

    func start() {
        lock.withLock {
            guard monitor.pathUpdateHandler == nil else { return }
            monitor.pathUpdateHandler = { [weak self] path in
                self?.pathChanged(path)
            }
            monitor.start(queue: queue)
        }
    }

    private func pathChanged(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        let signature = isSatisfied
            ? path.availableInterfaces.map(\.name).joined(separator: ",")
            : "unsatisfied"
        let previous = lock.withLock { () -> String? in
            defer {
                self.signature = signature
                satisfied = isSatisfied
            }
            return self.signature
        }
        guard let previous, previous != signature else { return }
        settleGeneration += 1
        let generation = settleGeneration
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, settleGeneration == generation else { return }
            let settled = self.isSatisfied
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.pathDidChange,
                    object: nil,
                    userInfo: [Self.isSatisfiedKey: settled]
                )
            }
        }
    }
}

@MainActor
enum BackgroundGraceController {
    private static var taskID: UIBackgroundTaskIdentifier = .invalid
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { beginIfNeeded() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            },
        ]
    }

    static func noteSessionsChanged() {
        guard taskID != .invalid, !hasLiveSessions else { return }
        end()
    }

    private static var hasLiveSessions: Bool {
        TerminalManager.shared.terminals.contains(where: { !$0.closed })
            || GhostRemoteSessionManager.shared.sessions.contains(where: { $0.state == .connected })
            || !ServerAssistant.shared.executingConversationIDs.isEmpty
    }

    private static func beginIfNeeded() {
        guard taskID == .invalid, hasLiveSessions else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Active SSH sessions") {
            MainActor.assumeIsolated { end() }
        }
    }

    private static func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

@MainActor
enum KeepAwakeController {
    private static var activeTerminalCount = 0

    static func setTerminalVisible(_ visible: Bool) {
        activeTerminalCount = max(0, activeTerminalCount + (visible ? 1 : -1))
        refresh()
    }

    static func refresh() {
        let shouldKeepAwake = activeTerminalCount > 0 && MobileTerminalPreferences.keepScreenAwake
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }
}

//
//  SessionActivityController.swift
//  TamioMobile
//
//  Maintains a single Live Activity reflecting open SSH and Ghost Remote
//  terminal sessions, ending automatically once all sessions close.
//

import ActivityKit
import Foundation

@MainActor
final class SessionActivityController {
    static let shared = SessionActivityController()

    private var activity: Activity<TamioSessionAttributes>?

    private init() {
        activity = Activity<TamioSessionAttributes>.activities.first
    }

    func sync() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let sshSessions = TerminalManager.shared.terminals.filter { !$0.closed }
        let remoteSessions = GhostRemoteSessionManager.shared.sessions.filter { $0.state == .connected }
        let total = sshSessions.count + remoteSessions.count

        guard total > 0 else {
            endAll()
            return
        }

        let state: TamioSessionAttributes.ContentState
        if let activeID = TerminalManager.shared.activeTerminalID,
           let active = sshSessions.first(where: { $0.id == activeID })
        {
            state = .init(
                activeCount: total,
                primaryHost: active.machine.isNotPlaceholder() ? active.machine.name : active.navigationTitle,
                detail: total == 1 ? String(localized: "SSH connected") : String(localized: "\(total) active terminals"),
                primarySessionID: active.id.uuidString,
                isGhostRemote: false
            )
        } else if let firstSSH = sshSessions.first {
            state = .init(
                activeCount: total,
                primaryHost: firstSSH.machine.isNotPlaceholder() ? firstSSH.machine.name : firstSSH.navigationTitle,
                detail: total == 1 ? String(localized: "SSH connected") : String(localized: "\(total) active terminals"),
                primarySessionID: firstSSH.id.uuidString,
                isGhostRemote: false
            )
        } else if let firstRemote = remoteSessions.first {
            state = .init(
                activeCount: total,
                primaryHost: firstRemote.hostName,
                detail: String(localized: "Ghost Remote"),
                primarySessionID: firstRemote.id.uuidString,
                isGhostRemote: true
            )
        } else {
            endAll()
            return
        }

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        if let current = activity ?? Activity<TamioSessionAttributes>.activities.first {
            activity = current
            nonisolated(unsafe) let target = current
            Task { await target.update(content) }
        } else {
            let attributes = TamioSessionAttributes(startedAt: Date())
            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                debugPrint("Live Activity request failed:", error.localizedDescription)
            }
        }
    }

    func endAll() {
        let targets = Activity<TamioSessionAttributes>.activities
        activity = nil
        for item in targets {
            nonisolated(unsafe) let target = item
            Task { await target.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

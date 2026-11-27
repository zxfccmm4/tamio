//
//  SessionActivityController.swift
//  TamioMobile
//
//  Maintains a single Live Activity reflecting open SSH and Ghost Remote
//  terminal sessions (with live CPU/Memory telemetry when available),
//  ending automatically once all sessions close.
//

import ActivityKit
import Foundation
import MachineStatusView
import TamioModule

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
            state = makeSSHState(for: active, total: total)
        } else if let firstSSH = sshSessions.first {
            state = makeSSHState(for: firstSSH, total: total)
        } else if let firstRemote = remoteSessions.first {
            state = .init(
                activeCount: total,
                primaryHost: firstRemote.hostName,
                countryFlag: "",
                endpoint: "\(firstRemote.host.address):\(firstRemote.host.port)",
                detail: total == 1
                    ? String(localized: "Ghost Remote")
                    : String(localized: "\(total) active sessions"),
                primarySessionID: firstRemote.id.uuidString,
                isGhostRemote: true,
                cpuPercent: nil,
                memPercent: nil
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

    private func makeSSHState(for context: TerminalContext, total: Int) -> TamioSessionAttributes.ContentState {
        let machine = context.machine
        let isSaved = machine.isNotPlaceholder()
        let hostName = isSaved ? machine.name : context.navigationTitle
        let flag = isSaved ? (machine.countryFlag ?? "") : ""

        let endpoint: String
        if isSaved {
            let store = TamioStore.shared
            let identity = machine.associatedIdentity.flatMap(UUID.init(uuidString:)).map { store.identityGroup[$0] }
            let user = machine.loginUsername(with: identity)
            let portSuffix = (machine.remotePort.isEmpty || machine.remotePort == "22") ? "" : ":\(machine.remotePort)"
            endpoint = store.machineRedacted != .none ? "••••••" : "\(user)@\(machine.remoteAddress)\(portSuffix)"
        } else {
            endpoint = context.navigationSubtitle
        }

        var cpu: Int?
        var mem: Int?
        if isSaved,
           let live = LiveStatusCenter.shared.session(for: machine.id),
           live.phase == .connected,
           live.status.hasData
        {
            cpu = Int(Double(live.status.processor.summary.sumUsed).rounded())
            mem = Int(live.status.memoryUsedPercent.rounded())
        }

        return .init(
            activeCount: total,
            primaryHost: TamioStore.shared.machineRedacted == .all ? "••••••" : hostName,
            countryFlag: flag,
            endpoint: endpoint,
            detail: total == 1
                ? String(localized: "SSH connected")
                : String(localized: "\(total) active terminals"),
            primarySessionID: context.id.uuidString,
            isGhostRemote: false,
            cpuPercent: cpu,
            memPercent: mem
        )
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

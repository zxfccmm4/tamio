//
//  SessionActivityController.swift
//  TamioMobile
//
//  Maintains a single Live Activity reflecting open SSH and Ghost Remote
//  terminal sessions (with live CPU/Memory telemetry when available),
//  ending automatically once all sessions close.
//

import ActivityKit
import Combine
import Foundation
import MachineStatusView
import TamioModule
import UIKit

@MainActor
final class SessionActivityController {
    static let shared = SessionActivityController()

    private var activity: Activity<TamioSessionAttributes>?
    private var lastState: TamioSessionAttributes.ContentState?
    private var lastUpdateAt: Date = .distantPast
    private var lastTelemetryMachineID: RDMachine.ID?
    private var telemetryCancellables = Set<AnyCancellable>()

    private init() {
        activity = Activity<TamioSessionAttributes>.activities.first(where: { $0.activityState == .active })
    }

    func sync() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endAll()
            return
        }

        let sshSessions = TerminalManager.shared.terminals.filter { !$0.closed }
        let remoteSessions = GhostRemoteSessionManager.shared.sessions.filter { $0.state == .connected }
        let total = sshSessions.count + remoteSessions.count

        guard total > 0 else {
            endAll()
            return
        }

        let state: TamioSessionAttributes.ContentState
        let telemetryMachineID: RDMachine.ID?
        if let activeID = TerminalManager.shared.activeTerminalID,
           let active = sshSessions.first(where: { $0.id == activeID })
        {
            state = makeSSHState(for: active, total: total)
            telemetryMachineID = active.machine.isNotPlaceholder() ? active.machine.id : nil
        } else if let firstSSH = sshSessions.first {
            state = makeSSHState(for: firstSSH, total: total)
            telemetryMachineID = firstSSH.machine.isNotPlaceholder() ? firstSSH.machine.id : nil
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
            telemetryMachineID = nil
        } else {
            endAll()
            return
        }

        observeTelemetry(for: telemetryMachineID)

        if let current = activeActivity() {
            guard lastState != state else { return }
            let majorChange = lastState?.primarySessionID != state.primarySessionID
                || lastState?.activeCount != state.activeCount
                || lastState?.isGhostRemote != state.isGhostRemote
            let now = Date()
            if !majorChange, now.timeIntervalSince(lastUpdateAt) < 3 {
                return
            }
            lastState = state
            lastUpdateAt = now
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
            nonisolated(unsafe) let target = current
            Task { await target.update(content) }
        } else {
            // ActivityKit rejects starting a new Live Activity while in the background.
            guard UIApplication.shared.applicationState != .background else { return }
            let attributes = TamioSessionAttributes(startedAt: Date())
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                lastState = state
                lastUpdateAt = Date()
            } catch {
                debugPrint("Live Activity request failed:", error.localizedDescription)
            }
        }
    }

    private func activeActivity() -> Activity<TamioSessionAttributes>? {
        if let activity, activity.activityState == .active {
            return activity
        }
        let existing = Activity<TamioSessionAttributes>.activities.first(where: { $0.activityState == .active })
        activity = existing
        return existing
    }

    private func observeTelemetry(for machineID: RDMachine.ID?) {
        guard lastTelemetryMachineID != machineID else { return }
        lastTelemetryMachineID = machineID
        telemetryCancellables.removeAll()

        guard let machineID else { return }

        if let session = LiveStatusCenter.shared.session(for: machineID) {
            subscribe(to: session)
        }
        LiveStatusCenter.shared.$sessions
            .map { $0[machineID] }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] session in
                guard let self, let session, self.lastTelemetryMachineID == machineID else { return }
                self.subscribe(to: session)
                self.sync()
            }
            .store(in: &telemetryCancellables)
    }

    private func subscribe(to session: MonitorSession) {
        session.$lastUpdate
            .throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.sync()
            }
            .store(in: &telemetryCancellables)
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
        telemetryCancellables.removeAll()
        lastTelemetryMachineID = nil
        lastState = nil
        activity = nil

        let targets = Activity<TamioSessionAttributes>.activities.filter { $0.activityState == .active }
        for item in targets {
            nonisolated(unsafe) let target = item
            Task { await target.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

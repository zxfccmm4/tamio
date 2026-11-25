//
//  MonitorPage.swift
//  Tamio (macOS)
//
//  A server's monitor (a session in the sidebar): the Terminal · Files · Monitor
//  switcher, Show in Menu Bar, Close; the page header, then the card grid.
//

import MachineStatusView
import TamioDesign
import TamioModule
import SwiftUI

struct MonitorPage: View {
    @ObservedObject var session: MonitorSession
    @EnvironmentObject var store: TamioStore
    @State private var mode: Mode = .overview

    private enum Mode: String, CaseIterable {
        case overview
        case charts
        case processes
        case containers
    }

    var body: some View {
        PageScaffold {
        } trailing: {
            RXSegmented(selection: $mode, options: [
                .init(.overview, "Overview"),
                .init(.charts, "Charts"),
                .init(.processes, "Processes"),
                .init(.containers, "Containers"),
            ], caps: false)
            ToolbarAction("Show in Menu Bar", systemImage: "menubar.rectangle") {
                AppRouter.shared.showInMenuBar(machine: session.machine.id)
            }
            ToolbarAction("Close Monitor", systemImage: "xmark") {
                MonitorCenter.shared.end(session.id)
            }
        } header: {
            VStack(alignment: .leading, spacing: RX.Space.s5) {
                PageTitle(store.machineRedacted == .all ? String(localized: "Server") : session.machine.name)
                MonitorFacts(session: session, redactAddress: store.machineRedacted != .none)
            }
        } content: {
            if session.phase == .connected, session.status.hasData {
                Group {
                    switch mode {
                    case .overview:
                        MonitorDashboard(session: session)
                    case .charts:
                        MacChartsDashboard(session: session)
                    case .processes:
                        MacProcessesTab(session: session)
                    case .containers:
                        MacContainersTab(session: session)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                MonitorPlaceholder(session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: session.phase == .connected && session.status.hasData)
        .animation(.easeOut(duration: 0.2), value: mode)
        .serverToolSwitcher(machine: session.machine.id, current: .monitor)
    }
}

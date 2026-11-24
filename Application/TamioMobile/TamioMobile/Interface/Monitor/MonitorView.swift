//
//  MonitorView.swift
//  TamioMobile
//
//  Native Apple HIG live server monitor page.
//

import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct MonitorView: View {
    @ObservedObject var session: MonitorSession
    @EnvironmentObject var store: TamioStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                factsCard
                if session.phase == .connected, session.status.hasData {
                    MonitorDashboard(session: session)
                } else {
                    MonitorPlaceholder(session: session)
                }
            }
            .padding(16)
        }
        .appleGroupedBackground()
        .navigationTitle(store.machineRedacted == .all ? String(localized: "Monitor") : session.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    TerminalManager.shared.begin(for: session.machine.id)
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Menu {
                    Button {
                        FileTransferManager.shared.begin(for: session.machine.id)
                    } label: {
                        Label("Open Files", systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        MonitorCenter.shared.end(session.id)
                        dismiss()
                    } label: {
                        Label("Close Monitor", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var factsCard: some View {
        let system = session.status.system
        return LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
            spacing: 14
        ) {
            fact("Hostname", system.hostname.isEmpty ? "—" : system.hostname)
            fact("System", system.releaseName.isEmpty ? "—" : system.releaseName)
            fact("Uptime", RXFormat.duration(system.uptimeSec))
            fact("Address", session.machine.remoteAddress, mono: true, redacted: store.machineRedacted != .none)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func fact(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, redacted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            RedactableText(value, redacted: redacted)
                .font(mono ? .subheadline.weight(.medium).monospaced() : .subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

//
//  PortForwardView.swift
//  TamioMobile
//
//  Native Apple HIG `.insetGrouped` port forwards list with inline toggle
//  switches, swipe-to-edit/delete, and clear Local/Remote direction badges.
//

import SwiftUI
import TamioDesign
import TamioModule

struct PortForwardView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var backend = PortForwardBackend.shared

    @State private var searchText = ""
    @State private var editor: EditorTarget?

    struct EditorTarget: Identifiable {
        let id = UUID()
        let forward: RDPortForward.ID?
    }

    private var filtered: [RDPortForward] {
        let all = store.portForwardGroup.forwards
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.targetHost.lowercased().contains(key)
                || String($0.targetPort).contains(key)
                || String($0.bindPort).contains(key)
                || ($0.getMachineName() ?? "").lowercased().contains(key)
        }
    }

    var body: some View {
        Group {
            if store.portForwardGroup.forwards.isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Create an SSH tunnel to securely forward local or remote ports through your saved servers.")
                } actions: {
                    Button {
                        editor = EditorTarget(forward: nil)
                    } label: {
                        Label("New Port Forward", systemImage: "plus")
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                }
                .appleGroupedBackground()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .appleGroupedBackground()
            } else {
                List {
                    Section {
                        ForEach(filtered) { forward in
                            PortForwardListRow(
                                forward: forward,
                                isRunning: backend.sessionExists(withPortForwardID: forward.id),
                                onToggle: { isOn in
                                    if isOn {
                                        backend.createSession(withPortForwardID: forward.id)
                                    } else {
                                        backend.endSession(withPortForwardID: forward.id)
                                    }
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    PortForwardActions.delete(forward.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    editor = EditorTarget(forward: forward.id)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.orange)
                                .disabled(backend.sessionExists(withPortForwardID: forward.id))
                            }
                            .contextMenu {
                                let running = backend.sessionExists(withPortForwardID: forward.id)
                                Button("Edit…") { editor = EditorTarget(forward: forward.id) }.disabled(running)
                                Button("Duplicate") { PortForwardActions.duplicate(forward.id) }
                                Button("Copy SSH Command") { UIBridge.sendPasteboard(str: forward.getCommand() ?? "") }
                                    .disabled(forward.getCommand() == nil)
                                Divider()
                                Button("Delete…", role: .destructive) { PortForwardActions.delete(forward.id) }
                            }
                        }
                    } header: {
                        Text("Tunnels")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Port Forward")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search forwards"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !backend.container.isEmpty {
                    Button {
                        for context in backend.container {
                            backend.endSession(withPortForwardID: context.info.id)
                        }
                    } label: {
                        Label("Stop All", systemImage: "stop.circle")
                    }
                }
                Button { editor = EditorTarget(forward: nil) } label: {
                    Label("New Port Forward", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            NavigationStack { EditPortForwardView(requestPortForward: target.forward) }
        }
    }
}

private struct PortForwardListRow: View {
    let forward: RDPortForward
    let isRunning: Bool
    let onToggle: (Bool) -> Void

    private var directionIcon: String {
        switch forward.forwardOrientation {
        case .listenLocal: "arrow.right"
        case .listenRemote: "arrow.left"
        case .dynamicSocks5: "network"
        }
    }

    private var directionTitle: String {
        switch forward.forwardOrientation {
        case .listenLocal: String(localized: "Local")
        case .listenRemote: String(localized: "Remote")
        case .dynamicSocks5: String(localized: "SOCKS5")
        }
    }

    private var endpointLabel: String {
        if forward.forwardOrientation == .dynamicSocks5 {
            return "localhost:\(forward.bindPort) (SOCKS5)"
        }
        return ":\(forward.bindPort) → \(forward.targetHost):\(forward.targetPort)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: directionIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isRunning ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(endpointLabel)
                    .font(.subheadline.weight(.medium).monospaced())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(directionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(forward.getMachineName() ?? String(localized: "No server selected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(get: { isRunning }, set: onToggle))
                .labelsHidden()
                .disabled(forward.usingMachine == nil)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
enum PortForwardActions {
    static func duplicate(_ id: RDPortForward.ID) {
        var copy = TamioStore.shared.portForwardGroup[id]
        copy.id = UUID()
        TamioStore.shared.portForwardGroup.insert(copy)
    }

    static func delete(_ id: RDPortForward.ID) {
        let forward = TamioStore.shared.portForwardGroup[id]
        UIBridge.requiresConfirmation(
            message: String(localized: "Delete the forward on port \(forward.bindPort)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            PortForwardBackend.shared.endSession(withPortForwardID: id)
            TamioStore.shared.portForwardGroup.delete(id)
        }
    }
}

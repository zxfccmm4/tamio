//
//  ServersView.swift
//  TamioMobile
//
//  Native Apple HIG `.insetGrouped` servers list:
//  - Grouped cleanly by server group, with large title & native search
//  - Leading swipe actions: Terminal & Files; trailing swipe actions: Edit & Delete
//  - Live inline CPU/Mem status badge per row via ServerLiveReader
//  - Native ContentUnavailableView empty states
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct ServersView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    @State private var searchText = ""

    private var filtered: [RDMachine] {
        let machines = store.machineGroup.machines
        guard !searchText.isEmpty else { return machines }
        return machines.filter { $0.isQualifiedForSearch(text: searchText) }
    }

    private var grouped: [(group: String, machines: [RDMachine])] {
        let names = Set(filtered.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            let items = filtered
                .filter { $0.group == name }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (name, items)
        }
    }

    var body: some View {
        Group {
            if store.machineGroup.machines.isEmpty {
                ContentUnavailableView {
                    Label("No Servers Yet", systemImage: "server.rack")
                } description: {
                    Text("Save an SSH host to connect with one tap or browse remote files.")
                } actions: {
                    Button {
                        actions.newServer()
                    } label: {
                        Label("New Server", systemImage: "plus")
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
                    if store.machineRedacted != .none {
                        Section {
                            HStack(spacing: 10) {
                                Image(systemName: "eye.slash.fill")
                                    .foregroundStyle(.orange)
                                Text("Sensitive server details are hidden")
                                    .font(.subheadline)
                                Spacer()
                                Button("Show") {
                                    store.machineRedacted = .none
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    ForEach(grouped, id: \.group) { section in
                        Section(section.group.isEmpty ? String(localized: "Ungrouped") : section.group) {
                            ForEach(section.machines) { machine in
                                ServerListRow(machine: machine)
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            actions.openTerminal(machine.id)
                                        } label: {
                                            Label("Terminal", systemImage: "terminal")
                                        }
                                        .tint(.indigo)

                                        Button {
                                            actions.openFiles(machine.id)
                                        } label: {
                                            Label("Files", systemImage: "folder")
                                        }
                                        .tint(.blue)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            ServerActions.delete([machine.id])
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }

                                        Button {
                                            actions.edit(machine.id)
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.orange)
                                    }
                                    .contextMenu {
                                        ServerMenuItems(machine: machine.id)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search servers"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Hide Details", selection: $store.machineRedacted) {
                        Text("Show All").tag(RDMachine.RedactedLevel.none)
                        Text("Hide Addresses").tag(RDMachine.RedactedLevel.sensitive)
                        Text("Hide Names & Addresses").tag(RDMachine.RedactedLevel.all)
                    }
                    Divider()
                    Button {
                        ServerActions.openTerminals()
                    } label: {
                        Label("Open Multiple Terminals…", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(store.machineGroup.machines.isEmpty)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }

                Button {
                    actions.newServer()
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
    }
}

private struct ServerListRow: View {
    let machine: RDMachine
    @EnvironmentObject private var store: TamioStore
    @Environment(\.serverActions) private var actions

    private var endpointText: String {
        let identity = machine.associatedIdentity.flatMap(UUID.init(uuidString:)).map { store.identityGroup[$0] }
        let user = machine.loginUsername(with: identity)
        let prefix = user.isEmpty ? "" : "\(user)@"
        let portSuffix = machine.remotePort == "22" ? "" : ":\(machine.remotePort)"
        return "\(prefix)\(machine.remoteAddress)\(portSuffix)"
    }

    var body: some View {
        Button {
            actions.openTerminal(machine.id)
        } label: {
            HStack(spacing: 12) {
                if let flag = machine.countryFlag {
                    Text(flag)
                        .font(.title3)
                        .frame(width: 26)
                } else {
                    Image(systemName: "server.rack")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                }

                VStack(alignment: .leading, spacing: 2) {
                    RedactableText(machine.name, redacted: store.machineRedacted == .all)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    RedactableText(endpointText, redacted: store.machineRedacted != .none)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ServerLiveReader(machine: machine.id) { state in
                    if let cpu = state.cpu, let mem = state.memory {
                        HStack(spacing: 10) {
                            Text("\(Int(cpu.rounded()))%")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(cpu >= 85 ? .red : .green)
                            Text("\(Int(mem.rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// Terminal, Files, Monitor, New Terminal; Edit, Duplicate, Copy Address,
/// Copy SSH Command, Forget Host Key; Delete.
struct ServerMenuItems: View {
    let machine: RDMachine.ID
    var includesTools = true
    @Environment(\.serverActions) private var actions

    var body: some View {
        Group {
            if includesTools {
                Button { actions.openTerminal(machine) } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Button { actions.openFiles(machine) } label: {
                    Label("Open Files", systemImage: "folder")
                }
                Button { actions.openMonitor(machine) } label: {
                    Label("Open Monitor", systemImage: "waveform.path.ecg")
                }
            }
            Button { TerminalManager.shared.begin(for: machine, force: true) } label: {
                Label("New Terminal", systemImage: "plus.rectangle")
            }
            Divider()
            Button { actions.edit(machine) } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button { ServerActions.duplicate(machine) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button { ServerActions.copyAddress(machine) } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button { ServerActions.copyCommand(machine) } label: {
                Label("Copy SSH Command", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button { ServerActions.forgetHostKey(machine) } label: {
                Label("Forget Host Key…", systemImage: "key.slash")
            }
            Divider()
            Button(role: .destructive) { ServerActions.delete([machine]) } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }
}

@MainActor
enum ServerActions {
    static func edit(_ machine: RDMachine.ID?) {
        TamioUtil.presentModalSheet { dismissModal in
            NavigationStack {
                EditMachineView(requestMachine: machine, onClose: dismissModal)
            }
            .environmentObject(TamioStore.shared)
        }
    }

    static func openMonitor(_ machine: RDMachine.ID) {
        do {
            let existing = MonitorCenter.shared.session(for: machine)
            let session = try MonitorCenter.shared.begin(for: machine)
            guard existing != nil || TamioStore.shared.openInterfaceAutomatically else { return }
            let host = UIHostingController(rootView: DefaultModalPresenter {
                MonitorView(session: session)
            }.environmentObject(TamioStore.shared))
            host.modalTransitionStyle = .coverVertical
            host.modalPresentationStyle = .formSheet
            host.preferredContentSize = preferredPopOverSize
            PresentationQueue.present(next: host)
        } catch {
            UIBridge.presentError(with: String(localized: "Cannot open monitor"))
        }
    }

    static func duplicate(_ machine: RDMachine.ID) {
        let store = TamioStore.shared
        let original = store.machineGroup[machine]
        guard original.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(
            message: String(localized: "Duplicate \(original.name)?"),
            confirmTitle: String(localized: "Duplicate"),
            destructive: false
        ) { confirmed in
            guard confirmed else { return }
            var copy = original
            copy.id = UUID()
            copy.name = original.name + " " + String(localized: "copy")
            if let raw = original.associatedIdentity, let id = UUID(uuidString: raw),
               store.identityGroup[id].isPrivate
            {
                var identity = store.identityGroup[id]
                identity.id = UUID()
                store.identityGroup.insert(identity)
                copy.associatedIdentity = identity.id.uuidString
            }
            store.machineGroup.insert(copy)
        }
    }

    static func delete(_ machines: [RDMachine.ID]) {
        let store = TamioStore.shared
        guard !machines.isEmpty else { return }
        let message = machines.count == 1
            ? String(localized: "Delete \(store.machineGroup[machines[0]].name)?")
            : String(localized: "Delete \(machines.count) servers?")
        UIBridge.requiresConfirmation(
            message: message,
            informative: String(localized: "Port forwards through it stop working."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            for machine in machines {
                if let session = MonitorCenter.shared.session(for: machine) {
                    MonitorCenter.shared.end(session.id)
                }
                if let raw = store.machineGroup[machine].associatedIdentity, let id = UUID(uuidString: raw),
                   store.identityGroup[id].isPrivate
                {
                    store.identityGroup.delete(id)
                }
                store.machineGroup.delete(machine)
            }
            store.cleanRecentIfNeeded()
        }
    }

    static func forgetHostKey(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(
            message: String(localized: "Forget the host key of \(read.name)?"),
            informative: String(localized: "The key the server presents on the next connection is saved as its key. Do this only when you know its keys were replaced."),
            confirmTitle: String(localized: "Forget"),
            destructive: false
        ) { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    static func copyAddress(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        UIBridge.sendPasteboard(str: read.remoteAddress)
    }

    static func copyCommand(_ machine: RDMachine.ID) {
        UIBridge.sendPasteboard(str: TamioStore.shared.machineGroup[machine].getCommand())
    }

    static func openTerminals() {
        Task {
            let machines = await TamioUtil.selectMachine()
            await MainActor.run {
                for machine in machines {
                    TerminalManager.shared.begin(for: machine, force: true)
                }
            }
        }
    }
}

extension ServerActionHandlers {
    @MainActor static var ios: ServerActionHandlers {
        ServerActionHandlers(
            openTerminal: { TerminalManager.shared.begin(for: $0) },
            openTerminalRunning: { TerminalManager.shared.begin(for: $0, running: $1) },
            openFiles: { FileTransferManager.shared.begin(for: $0) },
            openMonitor: { ServerActions.openMonitor($0) },
            edit: { ServerActions.edit($0) },
            newServer: { ServerActions.edit(nil) },
            copy: { UIBridge.sendPasteboard(str: $0) },
            confirm: { message, informative, confirmTitle, destructive, completion in
                UIBridge.requiresConfirmation(message: message, informative: informative, confirmTitle: confirmTitle, destructive: destructive, confirmation: completion)
            }
        )
    }
}

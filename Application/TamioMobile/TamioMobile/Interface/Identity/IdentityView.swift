//
//  IdentityView.swift
//  TamioMobile
//
//  Native Apple HIG `.insetGrouped` identities manager:
//  - Grouped by identity group, showing algorithm/type badges and server usage count
//  - Swipe to delete or copy public key; side-by-side detail on wide iPads
//

import SwiftUI
import TamioDesign
import TamioModule

struct IdentityView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var searchText = ""
    @State private var selection: RDIdentity.ID?
    @State private var creating = false
    @State private var pageWidth: CGFloat = 0

    private var sideBySide: Bool { sizeClass == .regular && pageWidth >= 720 }

    private var filtered: [RDIdentity] {
        let all = store.identityGroup.shared
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
        }
    }

    private var groups: [(name: String, identities: [RDIdentity])] {
        let names = Set(filtered.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            let items = filtered
                .filter { $0.group == name }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return (name, items)
        }
    }

    var body: some View {
        Group {
            if store.identityGroup.shared.isEmpty {
                ContentUnavailableView {
                    Label("No Identities Yet", systemImage: "key.fill")
                } description: {
                    Text("Store reusable SSH keys you can assign to any server with any username.")
                } actions: {
                    Button {
                        creating = true
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                }
                .appleGroupedBackground()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .appleGroupedBackground()
            } else if sideBySide {
                HStack(spacing: 0) {
                    identityList
                        .frame(width: 340)
                    Divider()
                    if let selection, store.identityGroup.shared.contains(where: { $0.id == selection }) {
                        EditIdentityView(requestIdentity: selection, embedded: true)
                            .id(selection)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select an Identity", systemImage: "key")
                            .appleGroupedBackground()
                    }
                }
            } else {
                identityList
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .navigationTitle("Identities")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search identities"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: {
                    Label("New Key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                EditIdentityView { created in
                    selection = created
                }
            }
        }
        .navigationDestination(item: Binding(
            get: { sideBySide ? nil : selection.map(Selected.init) },
            set: { selection = $0?.id }
        )) { selected in
            EditIdentityView(requestIdentity: selected.id)
                .appleGroupedBackground()
        }
        .onAppear {
            if sideBySide, selection == nil {
                selection = groups.first?.identities.first?.id
            }
        }
    }

    private var identityList: some View {
        List {
            ForEach(groups, id: \.name) { section in
                Section(section.name.isEmpty ? String(localized: "General") : section.name) {
                    ForEach(section.identities) { identity in
                        Button {
                            selection = identity.id
                        } label: {
                            identityRow(identity)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            sideBySide && selection == identity.id
                                ? Color.accentColor.opacity(0.12)
                                : Color(uiColor: .secondarySystemGroupedBackground)
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                IdentityActions.delete(identity.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !identity.publicKey.isEmpty {
                                Button {
                                    UIBridge.sendPasteboard(str: identity.publicKey)
                                } label: {
                                    Label("Copy Public Key", systemImage: "doc.on.clipboard")
                                }
                                .tint(.blue)
                            }
                        }
                        .contextMenu {
                            Button("Duplicate") { IdentityActions.duplicate(identity.id) }
                            Button("Copy Public Key") { UIBridge.sendPasteboard(str: identity.publicKey) }
                                .disabled(identity.publicKey.isEmpty)
                            Divider()
                            Button("Delete…", role: .destructive) { IdentityActions.delete(identity.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func identityRow(_ identity: RDIdentity) -> some View {
        let usageCount = store.machineGroup.machines.filter { $0.associatedIdentity == identity.id.uuidString }.count
        return HStack(spacing: 12) {
            Image(systemName: identity.usesAgent ? "person.badge.key" : (identity.privateKey.isEmpty ? "lock" : "key"))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(badgeText(for: identity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if usageCount > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "\(usageCount) server(s)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if !sideBySide {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func badgeText(for identity: RDIdentity) -> String {
        if identity.usesAgent {
            return identity.agentName ?? String(localized: "SSH Agent (macOS)")
        }
        if let algo = identity.keyAlgorithm {
            return algo == "ed25519" ? "Ed25519" : algo.uppercased()
        }
        return identity.privateKey.isEmpty ? String(localized: "Password") : String(localized: "SSH Key")
    }

    private struct Selected: Identifiable, Hashable { let id: RDIdentity.ID }
}

@MainActor
enum IdentityActions {
    static func duplicate(_ id: RDIdentity.ID) {
        var copy = TamioStore.shared.identityGroup[id]
        guard copy.hasCredentials else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " " + String(localized: "copy")
        TamioStore.shared.identityGroup.insert(copy)
    }

    static func delete(_ id: RDIdentity.ID) {
        let store = TamioStore.shared
        let identity = store.identityGroup[id]
        let users = store.machineGroup.machines.filter { $0.associatedIdentity == id.uuidString }.count
        UIBridge.requiresConfirmation(
            message: String(localized: "Delete identity \(identity.displayName)?"),
            informative: users > 0
                ? (users == 1 ? String(localized: "1 server uses it and will try automatic identities instead.") : String(localized: "\(users) servers use it and will try automatic identities instead."))
                : String(localized: "Its password and keys are removed from Tamio."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            store.identityGroup.delete(id)
        }
    }
}

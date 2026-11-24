//
//  PickIdentityView.swift
//  TamioMobile
//
//  Native Apple HIG identity picker sheet.
//

import SwiftUI
import TamioModule

struct PickIdentityView: View {
    @ObservedObject var store = TamioStore.shared

    @Binding var selection: RDIdentity.ID?
    @State var rawSelection: RDIdentity.ID? = nil
    @State private var creatingNew = false

    init(selection: Binding<RDIdentity.ID?>) {
        _selection = selection
    }

    private var completion: ((RDIdentity.ID?) -> Void)?

    init(completion: @escaping ((RDIdentity.ID?) -> Void)) {
        self.completion = completion
        _selection = Binding<RDIdentity.ID?> { nil } set: { _ in }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    creatingNew = true
                } label: {
                    Label("New SSH Key…", systemImage: "plus.circle.fill")
                }
            }

            Section("Available Identities") {
                if store.identityGroup.shared.isEmpty {
                    Text("No saved identities yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.identityGroup.shared) { identity in
                        let isSelected = rawSelection == identity.id
                        Button {
                            rawSelection = identity.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(identity.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if !identity.group.isEmpty {
                                        Text(identity.group)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if rawSelection != nil {
                Section {
                    Button(role: .destructive) {
                        rawSelection = nil
                    } label: {
                        Label("Clear Selection", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Identity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    completion?(nil)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                    completion?(rawSelection)
                }
                .bold()
            }
        }
        .sheet(isPresented: $creatingNew) {
            NavigationStack {
                EditIdentityView { created in
                    rawSelection = created
                }
            }
        }
        .onChange(of: rawSelection) { _, newValue in
            selection = newValue
        }
    }
}

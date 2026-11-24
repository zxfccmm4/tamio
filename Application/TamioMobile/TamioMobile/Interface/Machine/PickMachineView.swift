//
//  PickMachineView.swift
//  TamioMobile
//
//  Native Apple HIG server picker sheet.
//

import SwiftUI
import TamioModule

struct PickMachineView: View {
    @ObservedObject var store = TamioStore.shared

    let canSelectMany: Bool

    @Binding var selection: [RDMachine.ID]
    @State var rawSelection: [RDMachine.ID] = []

    init(selection: Binding<[RDMachine.ID]>, canSelectMany: Bool = true) {
        _selection = selection
        self.canSelectMany = canSelectMany
    }

    private var completion: (([RDMachine.ID]) -> Void)?

    init(completion: @escaping (([RDMachine.ID]) -> Void), canSelectMany: Bool = true) {
        self.completion = completion
        self.canSelectMany = canSelectMany
        _selection = Binding<[RDMachine.ID]> { [] } set: { _ in }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.machineGroup.machines.isEmpty {
                ContentUnavailableView {
                    Label("No Servers Yet", systemImage: "server.rack")
                } description: {
                    Text("Add a server first before selecting targets.")
                }
                .appleGroupedBackground()
            } else {
                List {
                    Section {
                        ForEach(store.machineGroup.machines) { machine in
                            let isSelected = rawSelection.contains(machine.id)
                            Button {
                                toggleSelection(for: machine.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(machine.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(machine.remoteAddress):\(machine.remotePort)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Servers")
                    } footer: {
                        if rawSelection.isEmpty {
                            Text("Select one or more servers.")
                        } else {
                            Text(String(localized: "\(rawSelection.count) selected"))
                        }
                    }

                    if !rawSelection.isEmpty {
                        Section {
                            Button(role: .destructive) {
                                rawSelection = []
                            } label: {
                                Label("Clear Selection", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Choose Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    completion?([])
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
        .onChange(of: rawSelection) { _, newValue in
            selection = newValue
        }
    }

    private func toggleSelection(for mid: RDMachine.ID) {
        if canSelectMany {
            if let index = rawSelection.firstIndex(of: mid) {
                rawSelection.remove(at: index)
            } else {
                rawSelection.append(mid)
            }
        } else {
            rawSelection = [mid]
        }
    }
}

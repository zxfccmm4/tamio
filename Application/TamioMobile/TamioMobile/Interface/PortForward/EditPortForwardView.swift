//
//  EditPortForwardView.swift
//  TamioMobile
//
//  Native Apple HIG Form for creating and editing SSH port forwards.
//

import SwiftUI
import TamioModule

struct EditPortForwardView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TamioStore.shared

    let inEditWith: UUID?

    init(requestPortForward: UUID? = nil) {
        inEditWith = requestPortForward
    }

    @State private var initializedOnce = false
    @State private var forwardOrientation: RDPortForward.ForwardOrientation = .listenLocal
    @State private var bindPort = "3000"
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = "3000"
    @State private var usingMachine: RDMachine.ID?

    private var parsedBindPort: Int? {
        guard let value = Int(bindPort), (1 ... 65535).contains(value) else { return nil }
        return value
    }

    private var parsedTargetPort: Int? {
        guard let value = Int(targetPort), (1 ... 65535).contains(value) else { return nil }
        return value
    }

    private var portsValid: Bool {
        parsedBindPort != nil && parsedTargetPort != nil && !targetHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var previewObject: RDPortForward {
        RDPortForward(
            forwardOrientation: forwardOrientation,
            bindPort: parsedBindPort ?? 0,
            targetHost: targetHost.trimmingCharacters(in: .whitespaces),
            targetPort: parsedTargetPort ?? 0,
            usingMachine: usingMachine
        )
    }

    var body: some View {
        Form {
            Section("Direction") {
                Picker("Direction", selection: $forwardOrientation) {
                    Text("Local Forward (-L)").tag(RDPortForward.ForwardOrientation.listenLocal)
                    Text("Remote Forward (-R)").tag(RDPortForward.ForwardOrientation.listenRemote)
                }
                .pickerStyle(.segmented)
            }

            Section("Bind Port") {
                LabeledContent("Port") {
                    TextField("3000", text: $bindPort)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .keyboardType(.numberPad)
                }
            }

            Section("Destination") {
                LabeledContent("Host") {
                    TextField("127.0.0.1", text: $targetHost)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Port") {
                    TextField("3000", text: $targetPort)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .keyboardType(.numberPad)
                }
            }

            Section("Through Server") {
                Picker("Server", selection: $usingMachine) {
                    Text("None").tag(RDMachine.ID?.none)
                    ForEach(store.machineGroup.machines) { machine in
                        Text(machine.name).tag(RDMachine.ID?.some(machine.id))
                    }
                }
            }

            Section {} footer: {
                if portsValid {
                    Text(previewObject.shortDescription())
                } else {
                    Text("Ports must be numbers between 1 and 65535.")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(inEditWith == nil ? String(localized: "New Port Forward") : String(localized: "Edit Port Forward"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { completeSheet() }
                    .bold()
                    .disabled(!portsValid)
            }
        }
        .onAppear {
            guard !initializedOnce else { return }
            initializedOnce = true
            if let edit = inEditWith {
                let read = store.portForwardGroup[edit]
                forwardOrientation = read.forwardOrientation
                bindPort = String(read.bindPort)
                targetHost = read.targetHost
                targetPort = String(read.targetPort)
                usingMachine = read.usingMachine
            }
        }
    }

    private func completeSheet() {
        guard portsValid else {
            UIBridge.presentError(with: String(localized: "Invalid port or destination address."))
            return
        }
        var object = previewObject
        if let edit = inEditWith { object.id = edit }
        store.portForwardGroup.insert(object)
        dismiss()
    }
}

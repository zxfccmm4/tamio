//
//  EditSnippetView.swift
//  TamioMobile
//
//  Native Apple HIG Form for creating and editing shell snippets.
//

import CodeEditorUI
import SwiftUI
import SymbolPicker
import TamioModule

struct EditSnippetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TamioStore.shared

    let inEditWith: UUID?

    init(requestSnippet: UUID? = nil) {
        inEditWith = requestSnippet
    }

    @State private var editor = SCodeEditor()
    @State private var initializedOnce = false
    @State private var name = ""
    @State private var group = ""
    @State private var code = ""
    @State private var comment = ""
    @State private var avatar = ""
    @State private var openSymbolPicker = false

    private var existingGroups: [String] {
        Set(store.snippetGroup.snippets.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)

                Button {
                    openSymbolPicker = true
                } label: {
                    HStack {
                        Text("Icon")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: avatar.isEmpty ? "chevron.left.forwardslash.chevron.right" : avatar)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack {
                    TextField("Group (optional)", text: $group)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { item in
                                Button(item) { group = item }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                TextField("Comment (optional)", text: $comment)
            }

            Section("Shell Command") {
                editor
                    .onContentChange { code = $0 }
                    .frame(height: 240)
            }

            if let snippetID = inEditWith {
                Section {
                    Button(role: .destructive) {
                        UIBridge.requiresConfirmation(
                            message: String(localized: "Delete this snippet?"),
                            confirmTitle: String(localized: "Delete"),
                            destructive: true
                        ) { confirmed in
                            if confirmed {
                                store.snippetGroup.delete(snippetID)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Delete Snippet", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(inEditWith == nil ? String(localized: "New Snippet") : String(localized: "Edit Snippet"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { completeSheet() }
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheet(isPresented: $openSymbolPicker) {
            SymbolPicker(symbol: $avatar)
        }
        .onAppear {
            guard !initializedOnce else { return }
            initializedOnce = true
            DispatchQueue.main.async {
                if let edit = inEditWith {
                    let read = store.snippetGroup[edit]
                    name = read.name
                    group = read.group
                    code = read.code
                    comment = read.comment
                    avatar = read.getSFAvatar()
                }
                editor.setDocumentData(code.isEmpty ? "#!/bin/bash\n\n" : code)
            }
        }
    }

    private func completeSheet() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            UIBridge.presentError(with: String(localized: "Snippet name cannot be empty."))
            return
        }
        var newSnippet = RDSnippet(
            id: inEditWith ?? UUID(),
            name: trimmedName,
            group: group.trimmingCharacters(in: .whitespaces),
            code: code,
            comment: comment,
            attachment: [:]
        )
        if avatar.isEmpty {
            newSnippet.clearSFAvatar()
        } else {
            newSnippet.setSFAvatar(sfSymbol: avatar)
        }
        store.snippetGroup.insert(newSnippet)
        dismiss()
    }
}

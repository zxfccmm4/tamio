//
//  TerminalSnippetSheet.swift
//  TamioMobile
//
//  Quick snippet drawer for mobile terminals: filter saved snippets and tap to
//  paste or execute immediately on the active shell.
//

import SwiftUI
import TamioDesign
import TamioModule

struct TerminalSnippetSheet: View {
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TamioStore.shared
    @State private var searchText = ""
    @State private var runImmediately = true

    private var filtered: [RDSnippet] {
        let all = store.snippetGroup.snippets
        let matched = searchText.isEmpty ? all : all.filter { $0.isQualifiedForSearch(text: searchText) }
        return matched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.snippetGroup.snippets.isEmpty {
                    ContentUnavailableView {
                        Label("No Snippets Yet", systemImage: "chevron.left.forwardslash.chevron.right")
                    } description: {
                        Text("Create snippets in the Snippets tab to run them in one tap from any terminal.")
                    }
                    .appleGroupedBackground()
                } else {
                    List {
                        Section {
                            Toggle("Press Return automatically", isOn: $runImmediately)
                        }

                        Section("Snippets") {
                            ForEach(filtered) { snippet in
                                Button {
                                    let payload = runImmediately ? snippet.code + "\n" : snippet.code
                                    onSend(payload)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Image(systemName: snippet.getSFAvatar())
                                                .foregroundStyle(Color.accentColor)
                                            Text(snippet.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if !snippet.group.isEmpty {
                                                Text(snippet.group)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(snippet.code)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.rxTerminalForeground)
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(Color.rxTerminalBackground)
                                            )
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Run Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search snippets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

//
//  SnippetView.swift
//  TamioMobile
//
//  Native Apple HIG snippets gallery with horizontal group filter pills,
//  touch-friendly command cards, and one-tap Run across servers.
//

import SwiftUI
import TamioDesign
import TamioModule

struct SnippetView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var searchText = ""
    @State private var groupFilter: String?
    @State private var creating = false
    @State private var editing: RDSnippet.ID?
    @Namespace private var zoomNamespace

    private var groupNames: [String] {
        Set(store.snippetGroup.snippets.map(\.group))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filtered: [RDSnippet] {
        var result = store.snippetGroup.snippets
        if let groupFilter {
            result = result.filter { $0.group == groupFilter }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.isQualifiedForSearch(text: searchText) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var columns: [GridItem] {
        if sizeClass == .compact {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16, alignment: .top)]
    }

    var body: some View {
        Group {
            if store.snippetGroup.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets Yet", systemImage: "chevron.left.forwardslash.chevron.right")
                } description: {
                    Text("Save reusable shell commands and run them across one or many servers in a single tap.")
                } actions: {
                    Button {
                        creating = true
                    } label: {
                        Label("New Snippet", systemImage: "plus")
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                }
                .appleGroupedBackground()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .appleGroupedBackground()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MobileGroupFilterBar(groups: groupNames, selection: $groupFilter)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered) { snippet in
                                MobileSnippetCard(
                                    snippet: snippet,
                                    onRun: { SnippetActions.run(snippet.id) },
                                    onEdit: { editing = snippet.id }
                                )
                                .appleZoomSource(id: snippet.id, in: zoomNamespace, cornerRadius: 16)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .appleGroupedBackground()
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search snippets"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: {
                    Label("New Snippet", systemImage: "plus")
                }
            }
        }
        .onChange(of: groupNames) { _, names in
            if let groupFilter, !names.contains(groupFilter) { self.groupFilter = nil }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { EditSnippetView() }
        }
        .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
            NavigationStack { EditSnippetView(requestSnippet: item.id) }
                .appleGroupedBackground()
                .appleZoomDestination(sourceID: item.id, in: zoomNamespace)
        }
    }

    private struct EditingID: Identifiable { let id: RDSnippet.ID }
}

private struct MobileSnippetCard: View {
    let snippet: RDSnippet
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: snippet.getSFAvatar())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !snippet.comment.isEmpty {
                        Text(snippet.comment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Run…")
            }

            Text(snippet.code.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Run…", action: onRun)
            Button("Edit…", action: onEdit)
            Button("Duplicate") { SnippetActions.duplicate(snippet.id) }
            Button("Copy Command") { UIBridge.sendPasteboard(str: snippet.code) }
            Divider()
            Button("Delete…", role: .destructive) { SnippetActions.delete(snippet.id) }
        }
    }
}

@MainActor
enum SnippetActions {
    static func run(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        guard !snippet.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UIBridge.presentError(with: String(localized: "This snippet has no command to run."))
            return
        }
        TamioUtil.createExecuteFor(snippet: snippet)
    }

    static func duplicate(_ id: RDSnippet.ID) {
        var copy = TamioStore.shared.snippetGroup[id]
        copy.id = UUID()
        copy.name += " " + String(localized: "copy")
        TamioStore.shared.snippetGroup.insert(copy)
    }

    static func delete(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        UIBridge.requiresConfirmation(
            message: snippet.name.isEmpty ? String(localized: "Delete this snippet?") : String(localized: "Delete \(snippet.name)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            if confirmed { TamioStore.shared.snippetGroup.delete(id) }
        }
    }
}

//
//  MacTerminalFindBar.swift
//  Tamio (macOS)
//
//  Terminal Find bar inspired by iGhostVT's TerminalSearch + FindDock (MIT):
//  drives Ghostty's native `start_search`, `search:`, `navigate_search:next`,
//  `navigate_search:previous`, and `end_search` binding actions while showing
//  live match counts and recent search history pills.
//

import SwiftUI
import TamioDesign
import TamioTerminal

@MainActor
final class TerminalFindState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var matchCount = 0
    @Published private(set) var recentQueries: [String] = []

    private static let historyKey = "sb.moe.tamio.terminal.findHistory"
    private static let maxHistory = 8

    init() {
        recentQueries = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    func present(on terminal: TamioTerminalView) {
        isPresented = true
        _ = terminal.performBindingAction("start_search")
        if !query.isEmpty {
            applyQuery(on: terminal)
        }
    }

    func dismiss(on terminal: TamioTerminalView) {
        isPresented = false
        _ = terminal.performBindingAction("end_search")
    }

    func applyQuery(on terminal: TamioTerminalView) {
        let trimmed = query.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty {
            matchCount = 0
            _ = terminal.performBindingAction("search:")
            return
        }
        _ = terminal.performBindingAction("search:\(trimmed)")
        recountMatches(needle: trimmed, in: terminal.readTranscript())
        recordHistory(trimmed)
    }

    func next(on terminal: TamioTerminalView) {
        guard !query.isEmpty else { return }
        _ = terminal.performBindingAction("navigate_search:next")
    }

    func previous(on terminal: TamioTerminalView) {
        guard !query.isEmpty else { return }
        _ = terminal.performBindingAction("navigate_search:previous")
    }

    private func recountMatches(needle: String, in haystack: String) {
        let lowerNeedle = needle.lowercased()
        let lowerHaystack = haystack.lowercased()
        var count = 0
        var searchRange = lowerHaystack.startIndex ..< lowerHaystack.endIndex
        while let found = lowerHaystack.range(of: lowerNeedle, range: searchRange) {
            count += 1
            searchRange = found.upperBound ..< lowerHaystack.endIndex
            if count >= 999 { break }
        }
        matchCount = count
    }

    private func recordHistory(_ term: String) {
        var next = recentQueries.filter { $0 != term }
        next.insert(term, at: 0)
        if next.count > Self.maxHistory { next = Array(next.prefix(Self.maxHistory)) }
        recentQueries = next
        UserDefaults.standard.set(next, forKey: Self.historyKey)
    }
}

struct MacTerminalFindBar: View {
    @ObservedObject var state: TerminalFindState
    let terminal: TamioTerminalView
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.rxInkSecondary)

                TextField("Find in terminal", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .frame(width: 210)
                    .focused($fieldFocused)
                    .onSubmit { state.next(on: terminal) }
                    .onChange(of: state.query) { _, _ in
                        state.applyQuery(on: terminal)
                    }

                if !state.query.isEmpty {
                    Text(state.matchCount >= 999 ? "999+" : "\(state.matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(state.matchCount == 0 ? Color.orange : Color.secondary)
                        .padding(.horizontal, 4)

                    Button {
                        state.query = ""
                        state.applyQuery(on: terminal)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 14)

                Button { state.previous(on: terminal) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(state.query.isEmpty)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous Match (⇧⌘G)")

                Button { state.next(on: terminal) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(state.query.isEmpty)
                .keyboardShortcut("g", modifiers: .command)
                .help("Next Match (⌘G)")

                Button {
                    state.dismiss(on: terminal)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close Find (Esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            if state.query.isEmpty, !state.recentQueries.isEmpty {
                HStack(spacing: 4) {
                    ForEach(state.recentQueries.prefix(5), id: \.self) { recent in
                        Button {
                            state.query = recent
                            state.applyQuery(on: terminal)
                        } label: {
                            Text(recent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            fieldFocused = true
        }
    }
}

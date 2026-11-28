//
//  TerminalFindBar.swift
//  TamioMobile
//
//  Terminal Find dock inspired by iGhostVT's TerminalSearch + FindDock (MIT):
//  drives Ghostty's native `search:` / `navigate_search:next` /
//  `navigate_search:previous` / `end_search` binding actions while displaying
//  live match counts and recent search history in a floating glass bar.
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

    func toggle(on terminal: TamioTerminalView) {
        if isPresented {
            dismiss(on: terminal)
        } else {
            present(on: terminal)
        }
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

struct TerminalFindBar: View {
    @ObservedObject var state: TerminalFindState
    let terminal: TamioTerminalView
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if state.query.isEmpty, !state.recentQueries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.recentQueries, id: \.self) { recent in
                            Button {
                                state.query = recent
                                state.applyQuery(on: terminal)
                            } label: {
                                Text(recent)
                                    .font(.rxCaption)
                                    .foregroundStyle(.rxInkSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .barGlass(in: Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, RX.Space.s3)
                }
            }

            GlassBarContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: RX.Space.s2) {
                        Image(rx: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(.rxInkSecondary)

                        TextField("Find in terminal", text: $state.query)
                            .font(.rxBody)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .submitLabel(.search)
                            .focused($fieldFocused)
                            .onSubmit {
                                state.next(on: terminal)
                            }
                            .onChange(of: state.query) { _, _ in
                                state.applyQuery(on: terminal)
                            }

                        if !state.query.isEmpty {
                            Text(state.matchCount >= 999 ? "999+" : "\(state.matchCount)")
                                .font(.rxCaption.monospacedDigit())
                                .foregroundStyle(state.matchCount == 0 ? Color.rxWarning : Color.rxInkSecondary)
                                .padding(.horizontal, 6)

                            Button {
                                state.query = ""
                                state.applyQuery(on: terminal)
                            } label: {
                                Image(rx: "xmark.circle.fill")
                                    .foregroundStyle(.rxInkTertiary)
                                    .frame(width: 28, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Clear Search"))
                        }

                        Divider().frame(height: 18)

                        Button { state.previous(on: terminal) } label: {
                            Image(rx: "chevron.up")
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(state.query.isEmpty)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .accessibilityLabel(String(localized: "Previous Match"))

                        Button { state.next(on: terminal) } label: {
                            Image(rx: "chevron.down")
                                .frame(width: 32, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(state.query.isEmpty)
                        .keyboardShortcut("g", modifiers: .command)
                        .accessibilityLabel(String(localized: "Next Match"))
                    }
                    .padding(.horizontal, RX.Space.s3)
                    .frame(height: 44)
                    .barGlass(in: Capsule(), interactive: false)

                    Button {
                        closeFindBar()
                    } label: {
                        Image(rx: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.rxInk)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .barGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(String(localized: "Close Find"))
                }
                .padding(.horizontal, RX.Space.s3)
            }
        }
        .padding(.bottom, RX.Space.s2)
        .onAppear {
            fieldFocused = true
        }
    }

    private func closeFindBar() {
        fieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.snappy(duration: 0.2)) {
            state.dismiss(on: terminal)
        }
    }
}

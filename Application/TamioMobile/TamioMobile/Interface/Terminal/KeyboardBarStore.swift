//
//  KeyboardBarStore.swift
//  TamioMobile
//
//  Customizable iOS software keyboard accessory bar for Ghostty terminals,
//  persisted in UserDefaults and applied live to every open terminal.
//

import GhosttyTerminal
import SwiftUI
import TamioDesign

@MainActor
final class KeyboardBarStore: ObservableObject {
    static let shared = KeyboardBarStore()
    static let didChange = Notification.Name("sb.moe.tamio.keyboardBarDidChange")

    private static let storageKey = "sb.moe.tamio.keyboardBar.codes"

    enum Preset: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case developer = "Developer"
        case vim = "Vim / Tmux"
        case compact = "Compact"

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .standard: return String(localized: "Standard")
            case .developer: return String(localized: "Developer")
            case .vim: return String(localized: "Vim / Tmux")
            case .compact: return String(localized: "Compact")
            }
        }

        var codes: [String] {
            switch self {
            case .standard:
                return ["esc", "tab", "ctrl", "alt", "command", "divider", "left", "up", "down", "right", "divider", "|", "/", "~", "-", "_", "`", "'", "\"", "paste"]
            case .developer:
                return ["esc", "tab", "ctrl", "alt", "divider", "left", "up", "down", "right", "divider", "|", "/", "~", "-", "_", "$", "{", "}", "[", "]", ":", ";", "paste"]
            case .vim:
                return ["esc", "ctrl", "tab", "divider", ":", "/", "?", "$", "^", "%", "|", "~", "-", "divider", "left", "down", "up", "right", "paste"]
            case .compact:
                return ["esc", "tab", "ctrl", "alt", "left", "up", "down", "right", "|", "/", "-", "paste"]
            }
        }
    }

    @Published private(set) var codes: [String] {
        didSet {
            UserDefaults.standard.set(codes, forKey: Self.storageKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.storageKey), !saved.isEmpty {
            codes = saved
        } else {
            codes = Preset.standard.codes
        }
    }

    var items: [TerminalInputAccessoryItem] {
        codes.compactMap(Self.item(for:))
    }

    func applyPreset(_ preset: Preset) {
        codes = preset.codes
    }

    func addSymbol(_ symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !codes.contains(trimmed) else { return }
        codes.append(trimmed)
    }

    func move(from source: IndexSet, to destination: Int) {
        codes.move(fromOffsets: source, toOffset: destination)
    }

    func remove(at offsets: IndexSet) {
        codes.remove(atOffsets: offsets)
        if codes.isEmpty { codes = Preset.compact.codes }
    }

    static func item(for code: String) -> TerminalInputAccessoryItem? {
        switch code {
        case "esc": return .esc
        case "tab": return .tab
        case "ctrl": return .ctrl
        case "alt": return .alt
        case "command": return .command
        case "left": return .arrowLeft
        case "up": return .arrowUp
        case "down": return .arrowDown
        case "right": return .arrowRight
        case "paste": return .paste
        case "divider": return .divider
        default: return code.isEmpty ? nil : .symbol(code)
        }
    }

    static func label(for code: String) -> String {
        switch code {
        case "esc": return String(localized: "Esc")
        case "tab": return String(localized: "Tab")
        case "ctrl": return String(localized: "Ctrl")
        case "alt": return String(localized: "Option")
        case "command": return String(localized: "Cmd")
        case "left": return String(localized: "Left Arrow")
        case "up": return String(localized: "Up Arrow")
        case "down": return String(localized: "Down Arrow")
        case "right": return String(localized: "Right Arrow")
        case "paste": return String(localized: "Paste")
        case "divider": return String(localized: "Divider")
        default: return code
        }
    }
}

struct KeyboardBarEditorSheet: View {
    @ObservedObject private var store = KeyboardBarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newSymbol = ""

    var body: some View {
        List {
            Section("Presets") {
                ForEach(KeyboardBarStore.Preset.allCases) { preset in
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.localizedTitle)
                                .foregroundStyle(.primary)
                            Spacer()
                            if store.codes == preset.codes {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Add Symbol Key") {
                HStack(spacing: 10) {
                    TextField("Symbol (e.g. $, &, ->)", text: $newSymbol)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button("Add") {
                        store.addSymbol(newSymbol)
                        newSymbol = ""
                    }
                    .appleProminentButton()
                    .controlSize(.small)
                    .disabled(newSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Active Keys (Drag to Reorder)") {
                ForEach(Array(store.codes.enumerated()), id: \.offset) { _, code in
                    HStack {
                        Text(KeyboardBarStore.label(for: code))
                            .font(code.count <= 2 ? .body.monospaced() : .body)
                        Spacer()
                    }
                }
                .onMove(perform: store.move)
                .onDelete(perform: store.remove)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Keyboard Bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .bold()
            }
        }
    }
}

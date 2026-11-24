//
//  TerminalTabSwitcher.swift
//  TamioMobile
//
//  iGhostVT-inspired mobile terminal navigation chrome:
//  - Safari-style floating bottom bar with swipe-to-switch capsule, lock
//    indicator, Find, Snippets, and Tab Switcher buttons.
//  - Live-thumbnail Tab Switcher grid across all active SSH sessions.
//  - Copy Text, Copy as Image, and Export Text share sheet helpers.
//

import SPIndicator
import SwiftUI
import TamioDesign
import TamioModule
import UIKit

struct TerminalFloatingBar: View {
    let title: String
    let subtitle: String
    let tabCount: Int
    let isLocked: Bool
    let isKeyboardLocked: Bool
    let onSwipePrevious: () -> Void
    let onSwipeNext: () -> Void
    let onToggleFind: () -> Void
    let onOpenSnippets: () -> Void
    let onOpenSwitcher: () -> Void
    var onOpenThemes: (() -> Void)? = nil
    var onToggleLock: (() -> Void)? = nil
    var onOpenKeyboardEditor: (() -> Void)? = nil

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GlassBarContainer(spacing: 8) {
            HStack(spacing: 8) {
                // Swipeable title capsule (iGhostVT Safari-style bar; long-press for settings)
                Button(action: onOpenSwitcher) {
                    HStack(spacing: 6) {
                        if isLocked {
                            Image(rx: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.rxWarning)
                        } else if isKeyboardLocked {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 11))
                                .foregroundStyle(.rxAccent)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.rxInk)
                                .lineLimit(1)
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.rxInkSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if tabCount > 1 {
                            Text("\(tabCount)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.rxInkSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .barGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let onOpenThemes {
                        Button(action: onOpenThemes) {
                            Label("Themes & Engine…", systemImage: "paintpalette")
                        }
                    }
                    if let onOpenKeyboardEditor {
                        Button(action: onOpenKeyboardEditor) {
                            Label("Customize Keyboard Bar…", systemImage: "slider.horizontal.3")
                        }
                    }
                    if let onToggleLock {
                        Button(action: onToggleLock) {
                            Label(isLocked ? "Unlock Tab" : "Lock Tab", systemImage: isLocked ? "lock.open" : "lock.fill")
                        }
                    }
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Divider()
                        Button {
                            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
                        } label: {
                            Label("New Window", systemImage: "macwindow.badge.plus")
                        }
                    }
                }
                .offset(x: dragOffset * 0.25)
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            dragOffset = max(-80, min(80, value.translation.width))
                        }
                        .onEnded { value in
                            defer { withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { dragOffset = 0 } }
                            if value.translation.width < -44 {
                                onSwipeNext()
                            } else if value.translation.width > 44 {
                                onSwipePrevious()
                            }
                        }
                )

                Button(action: onToggleFind) {
                    Image(rx: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.rxInk)
                        .frame(width: 44, height: 44)
                        .barGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find in Terminal")

                Button(action: onOpenSnippets) {
                    Image(rx: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 15))
                        .foregroundStyle(.rxInk)
                        .frame(width: 44, height: 44)
                        .barGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Snippets")
            }
            .padding(.horizontal, RX.Space.s3)
            .padding(.bottom, RX.Space.s2)
        }
    }
}

struct TerminalTabSwitcherSheet: View {
    @ObservedObject private var manager = TerminalManager.shared
    let activeID: UUID
    let onSelect: (TerminalContext) -> Void
    let onNewSession: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var thumbnails: [UUID: UIImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 260), spacing: RX.Space.s3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: RX.Space.s3) {
                    ForEach(manager.terminals) { context in
                        tabCard(context)
                    }
                }
                .padding(RX.Space.s4)
            }
            .appleGroupedBackground()
            .navigationTitle(String(localized: "Terminal Tabs (\(manager.terminals.count))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Button {
                            dismiss()
                            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
                        } label: {
                            Label("New Window", systemImage: "macwindow.badge.plus")
                        }
                    }
                    Button {
                        dismiss()
                        onNewSession()
                    } label: {
                        Label("New Terminal", rx: "plus")
                    }
                }
            }
        }
        .onAppear { captureThumbnails() }
    }

    @ViewBuilder
    private func tabCard(_ context: TerminalContext) -> some View {
        let isSelected = context.id == activeID
        Button {
            onSelect(context)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(context.closed ? Color.rxWarning : Color.rxSuccess)
                        .frame(width: 7, height: 7)
                    Text(context.machine.isNotPlaceholder() ? context.machine.name : context.navigationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        TerminalManager.shared.end(for: context.id)
                    } label: {
                        Image(rx: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.rxInkSecondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.rxSurface)

                Group {
                    if let image = thumbnails[context.id] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.rxTerminalBackground
                            Image(rx: "terminal")
                                .font(.system(size: 24))
                                .foregroundStyle(.rxTerminalMuted)
                        }
                    }
                }
                .frame(height: 128)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Color.rxAccent : Color.rxHairline, lineWidth: isSelected ? 2 : 0.75)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func captureThumbnails() {
        for context in manager.terminals {
            if let image = context.termInterface.snapshotImage() {
                thumbnails[context.id] = image
            }
        }
    }
}

@MainActor
enum TerminalExportHelper {
    static func copyText(from context: TerminalContext) {
        let text = context.termInterface.readViewportText() ?? context.termInterface.readTranscript()
        guard !text.isEmpty else {
            UIBridge.presentError(with: String(localized: "There is no terminal text to copy yet."))
            return
        }
        UIBridge.sendPasteboard(str: text)
    }

    static func copyImage(from context: TerminalContext) {
        guard let image = context.termInterface.snapshotImage() else {
            UIBridge.presentError(with: String(localized: "Could not capture terminal snapshot."))
            return
        }
        UIPasteboard.general.image = image
        let indicator = SPIndicatorView(title: String(localized: "Copied Image"), preset: .done)
        indicator.presentWindow = UIWindow.shutUpKeyWindow
        indicator.present(haptic: .success, completion: nil)
    }

    static func exportTranscript(from context: TerminalContext) {
        let text = context.termInterface.readTranscript()
        guard !text.isEmpty else {
            UIBridge.presentError(with: String(localized: "There is no terminal output to export yet."))
            return
        }
        let safeName = (context.machine.isNotPlaceholder() ? context.machine.name : "terminal")
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-transcript.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let presenter = UIWindow.shutUpKeyWindow?.topMostViewController {
                activity.popoverPresentationController?.sourceView = presenter.view
                activity.popoverPresentationController?.sourceRect = CGRect(
                    x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1
                )
                presenter.present(activity, animated: true)
            }
        } catch {
            UIBridge.presentError(with: error.localizedDescription)
        }
    }
}

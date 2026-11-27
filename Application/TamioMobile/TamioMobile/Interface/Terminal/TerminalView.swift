//
//  TerminalView.swift
//  TamioMobile
//
//  Non-jailbreak iGhostVT-architecture Ghostty terminal over SSH:
//  - Persistent ZStack mounting all open terminal surfaces simultaneously
//    (hidden tabs pause rendering via `setActive(false)` without teardown,
//    eliminating flicker and grid renegotiation on tab switch)
//  - Regular-width Top Tab Strip (iPad / landscape) & compact Safari-style
//    floating bottom bar that auto-hides while the software keyboard is visible
//  - Liquid Glass SessionStatusOverlay ("Connecting…", "Starting shell…",
//    and centered Reconnect card when disconnected)
//  - Find bar (⌘F / ⌘G / ⇧⌘G), Interaction & Software Keyboard Lock,
//    Snippets drawer (⌥⌘S), Ghostty Theme/Engine picker, Copy Text / Image /
//    Export Transcript, Live Monitor metrics strip, and iPad Multi-Window
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule
import TamioTerminal
import UIKit

struct TerminalView: View {
    @ObservedObject private var manager = TerminalManager.shared
    @ObservedObject private var store = TamioStore.shared

    @State private var currentContext: TerminalContext
    @State private var findStates: [UUID: TerminalFindState] = [:]
    @State private var showsSnippets = false
    @State private var showsTabSwitcher = false
    @State private var showsKeyboardEditor = false
    @State private var showsThemeSettings = false
    @State private var showsAICopilot = false
    @State private var keyboardVisible = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(context: TerminalContext) {
        _currentContext = State(initialValue: context)
    }

    private var activeContext: TerminalContext {
        if let existing = manager.terminals.first(where: { $0.id == currentContext.id }) {
            return existing
        }
        return currentContext
    }

    private var mountedTerminals: [TerminalContext] {
        if manager.terminals.contains(where: { $0.id == activeContext.id }) {
            return manager.terminals
        }
        return [activeContext] + manager.terminals
    }

    private var activeFindState: TerminalFindState {
        if let existing = findStates[activeContext.id] { return existing }
        return TerminalFindState()
    }

    var body: some View {
        TerminalSessionHost(
            activeContext: activeContext,
            mountedTerminals: mountedTerminals,
            findState: activeFindState,
            sizeClass: sizeClass,
            keyboardVisible: keyboardVisible,
            showsSnippets: $showsSnippets,
            showsTabSwitcher: $showsTabSwitcher,
            showsKeyboardEditor: $showsKeyboardEditor,
            showsThemeSettings: $showsThemeSettings,
            showsAICopilot: $showsAICopilot,
            onSwitchTab: switchTo(_:),
            onSwipePrevious: {
                if let prev = manager.neighbor(of: activeContext.id, delta: -1) { switchTo(prev) }
            },
            onSwipeNext: {
                if let next = manager.neighbor(of: activeContext.id, delta: 1) { switchTo(next) }
            },
            onNewSession: {
                if activeContext.remoteType == .machine, activeContext.machine.isNotPlaceholder() {
                    TerminalManager.shared.begin(for: activeContext.machine.id, force: true)
                }
            },
            onCloseTab: closeSession(_:)
        )
        .sheet(isPresented: $showsSnippets) {
            TerminalSnippetSheet { payload in
                activeContext.termInterface.sendInputText(payload)
            }
        }
        .sheet(isPresented: $showsTabSwitcher) {
            TerminalTabSwitcherSheet(
                activeID: activeContext.id,
                onSelect: { switchTo($0) },
                onNewSession: {
                    if activeContext.remoteType == .machine, activeContext.machine.isNotPlaceholder() {
                        TerminalManager.shared.begin(for: activeContext.machine.id, force: true)
                    }
                }
            )
        }
        .sheet(isPresented: $showsKeyboardEditor) {
            NavigationStack {
                KeyboardBarEditorSheet()
            }
        }
        .sheet(isPresented: $showsThemeSettings) {
            NavigationStack {
                GhosttyConfigurationView(
                    hostSections: [],
                    onApplied: { size in
                        if let size { store.terminalFontSize = Int(size.rounded()) }
                    }
                )
                .navigationTitle("Themes & Engine")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsThemeSettings = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showsAICopilot) {
            TerminalAICopilotSheet(
                machine: activeContext.remoteType == .machine && activeContext.machine.isNotPlaceholder() ? activeContext.machine : nil,
                terminalTitle: activeContext.remoteType == .machine ? activeContext.machine.name : activeContext.navigationTitle,
                terminal: activeContext.termInterface
            ) { command, run in
                activeContext.termInterface.sendInputText(run ? command + "\n" : command)
            }
        }
        .onAppear {
            ensureFindState(for: activeContext.id)
            manager.activeTerminalID = activeContext.id
            KeepAwakeController.setTerminalVisible(true)
            syncSurfaceActivation(activeID: activeContext.id)
        }
        .onDisappear {
            KeepAwakeController.setTerminalVisible(false)
            for term in mountedTerminals {
                term.termInterface.setActive(false)
            }
        }
        .onChange(of: manager.activeTerminalID) { _, nextID in
            guard let nextID, nextID != activeContext.id,
                  let target = manager.terminals.first(where: { $0.id == nextID })
            else { return }
            switchTo(target)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = false }
        }
    }

    private func ensureFindState(for id: UUID) {
        if findStates[id] == nil {
            findStates[id] = TerminalFindState()
        }
    }

    private func syncSurfaceActivation(activeID: UUID) {
        for term in mountedTerminals {
            term.termInterface.setActive(term.id == activeID)
        }
    }

    private func switchTo(_ next: TerminalContext) {
        guard next.id != activeContext.id else { return }
        if let currentFind = findStates[activeContext.id], currentFind.isPresented {
            currentFind.dismiss(on: activeContext.termInterface)
        }
        ensureFindState(for: next.id)
        currentContext = next
        manager.activeTerminalID = next.id
        syncSurfaceActivation(activeID: next.id)
    }

    private func closeSession(_ target: TerminalContext) {
        let performClose = {
            findStates[target.id] = nil
            target.processShutdown()
            TerminalManager.shared.end(for: target.id)
            if target.id == activeContext.id {
                if let fallback = manager.terminals.first(where: { $0.id != target.id }) {
                    switchTo(fallback)
                } else {
                    dismiss()
                }
            }
        }

        if target.closed {
            performClose()
        } else {
            UIBridge.requiresConfirmation(
                message: String(localized: "Close this session?"),
                informative: String(localized: "Anything running in it is stopped."),
                confirmTitle: String(localized: "Close Session"),
                destructive: true
            ) { yes in
                guard yes else { return }
                performClose()
            }
        }
    }
}

// MARK: - Main Session Host

private struct TerminalSessionHost: View {
    @ObservedObject var activeContext: TerminalContext
    let mountedTerminals: [TerminalContext]
    @ObservedObject var findState: TerminalFindState
    let sizeClass: UserInterfaceSizeClass?
    let keyboardVisible: Bool
    @Binding var showsSnippets: Bool
    @Binding var showsTabSwitcher: Bool
    @Binding var showsKeyboardEditor: Bool
    @Binding var showsThemeSettings: Bool
    @Binding var showsAICopilot: Bool
    let onSwitchTab: (TerminalContext) -> Void
    let onSwipePrevious: () -> Void
    let onSwipeNext: () -> Void
    let onNewSession: () -> Void
    let onCloseTab: (TerminalContext) -> Void

    @ObservedObject private var store = TamioStore.shared
    @ObservedObject private var monitors = MonitorCenter.shared

    private var showsTopTabStrip: Bool {
        sizeClass == .regular && mountedTerminals.count > 1
    }

    private var showsFloatingBottomBar: Bool {
        !findState.isPresented && !keyboardVisible && sizeClass != .regular
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTopTabStrip {
                TerminalTopTabStrip(
                    terminals: mountedTerminals,
                    activeID: activeContext.id,
                    onSelect: onSwitchTab,
                    onClose: onCloseTab,
                    onNew: onNewSession
                )
            }

            if activeContext.isInteractionLocked {
                lockedBanner
            }

            ZStack(alignment: .bottom) {
                // Keep every open terminal surface mounted in one persistent ZStack
                // so switching tabs never tears down Ghostty Metal views or flickers.
                ZStack {
                    ForEach(mountedTerminals) { term in
                        let isActive = term.id == activeContext.id
                        TerminalPaneSurface(
                            context: term,
                            isActive: isActive,
                            bottomReserve: showsFloatingBottomBar ? 54 : 4,
                            fontSize: store.terminalFontSize
                        )
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // iGhostVT-style status pill ("Connecting…", "Starting shell…")
                // and centered Reconnect card when disconnected.
                SessionStatusOverlay(
                    context: activeContext,
                    onClose: { onCloseTab(activeContext) }
                )

                if findState.isPresented {
                    TerminalFindBar(state: findState, terminal: activeContext.termInterface)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showsFloatingBottomBar {
                    TerminalFloatingBar(
                        title: title,
                        subtitle: subtitle,
                        tabCount: mountedTerminals.count,
                        isLocked: activeContext.isInteractionLocked,
                        isKeyboardLocked: activeContext.isSoftwareKeyboardLocked,
                        onSwipePrevious: onSwipePrevious,
                        onSwipeNext: onSwipeNext,
                        onToggleFind: { findState.present(on: activeContext.termInterface) },
                        onOpenSnippets: { showsSnippets = true },
                        onOpenSwitcher: { showsTabSwitcher = true },
                        onOpenThemes: { showsThemeSettings = true },
                        onToggleLock: { activeContext.isInteractionLocked.toggle() },
                        onOpenKeyboardEditor: { showsKeyboardEditor = true }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if let session = monitors.session(for: activeContext.machine.id), session.status.hasData {
                TerminalLiveMetricsStrip(session: session)
            }
        }
        .background(RXBackdrop().ignoresSafeArea())
        .onChange(of: activeContext.closed) { _, _ in
            activeContext.syncBannerState()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if activeContext.closed {
                    Button {
                        activeContext.reconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Reconnect")
                }

                Button {
                    showsAICopilot = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("SSH AI Copilot")

                Menu {
                    Text(String(localized: "Font Size: \(store.terminalFontSize) pt"))
                    Divider()
                    Button {
                        store.terminalFontSize = max(6, store.terminalFontSize - 1)
                    } label: {
                        Label("Smaller Text", systemImage: "textformat.size.smaller")
                    }
                    .disabled(store.terminalFontSize <= 6)

                    Button {
                        store.terminalFontSize = min(30, store.terminalFontSize + 1)
                    } label: {
                        Label("Larger Text", systemImage: "textformat.size.larger")
                    }
                    .disabled(store.terminalFontSize >= 30)

                    Divider()
                    Button {
                        store.terminalFontSize = 12
                    } label: {
                        Label("Reset to 12 pt", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 14, weight: .medium))
                }
                .accessibilityLabel("Text Size")

                if activeContext.remoteType == .machine, activeContext.machine.isNotPlaceholder() {
                    Button {
                        FileTransferManager.shared.begin(for: activeContext.machine.id)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .accessibilityLabel("Files")
                }

                Menu {
                    Section {
                        Button {
                            findState.present(on: activeContext.termInterface)
                        } label: {
                            Label("Find in Terminal…", rx: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)

                        Button {
                            showsSnippets = true
                        } label: {
                            Label("Run Snippet…", rx: "chevron.left.forwardslash.chevron.right")
                        }
                        .keyboardShortcut("s", modifiers: [.command, .option])

                        Button {
                            showsTabSwitcher = true
                        } label: {
                            Label("All Terminal Tabs (\(mountedTerminals.count))", rx: "macwindow")
                        }
                    }

                    Section {
                        Toggle(isOn: $activeContext.isInteractionLocked) {
                            Label("Lock Tab (Prevent Input)", rx: "lock.fill")
                        }
                        Toggle(isOn: $activeContext.isSoftwareKeyboardLocked) {
                            Label("Lock Software Keyboard", rx: "keyboard")
                        }
                        Button {
                            showsKeyboardEditor = true
                        } label: {
                            Label("Customize Keyboard Bar…", rx: "slider.horizontal.3")
                        }
                        Button {
                            showsThemeSettings = true
                        } label: {
                            Label("Themes & Engine…", systemImage: "paintpalette")
                        }
                    }

                    Section {
                        Button {
                            store.terminalFontSize = min(30, store.terminalFontSize + 1)
                        } label: {
                            Label("Larger Text", rx: "textformat.size.larger")
                        }
                        .keyboardShortcut("+", modifiers: .command)

                        Button {
                            store.terminalFontSize = max(6, store.terminalFontSize - 1)
                        } label: {
                            Label("Smaller Text", rx: "textformat.size.smaller")
                        }
                        .keyboardShortcut("-", modifiers: .command)
                    }

                    Section {
                        Button {
                            TerminalExportHelper.copyText(from: activeContext)
                        } label: {
                            Label("Copy Screen Text", rx: "doc.on.clipboard")
                        }
                        Button {
                            TerminalExportHelper.copyImage(from: activeContext)
                        } label: {
                            Label("Copy as Image", rx: "photo")
                        }
                        Button {
                            TerminalExportHelper.exportTranscript(from: activeContext)
                        } label: {
                            Label("Export Transcript…", rx: "arrow.up.right.square")
                        }
                    }

                    if activeContext.remoteType == .machine, activeContext.machine.isNotPlaceholder() {
                        Section {
                            Button {
                                ServerActions.openMonitor(activeContext.machine.id)
                            } label: {
                                Label("Open Monitor", rx: "waveform.path.ecg")
                            }
                            Button {
                                onNewSession()
                            } label: {
                                Label("New Terminal on \(activeContext.machine.name)", rx: "plus.rectangle")
                            }
                            if UIDevice.current.userInterfaceIdiom == .pad {
                                Button {
                                    UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
                                } label: {
                                    Label("New Window", systemImage: "macwindow.badge.plus")
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            onCloseTab(activeContext)
                        } label: {
                            Label("Close Session", rx: "xmark.circle")
                        }
                        .keyboardShortcut("w", modifiers: .command)
                    }
                } label: {
                    Label("More", rx: "ellipsis.circle")
                }
            }
        }
    }

    private var lockedBanner: some View {
        HStack(spacing: RX.Space.s2) {
            Image(rx: "lock.fill")
                .foregroundStyle(.rxWarning)
            Text("Tab locked against accidental input")
                .font(.rxCaption)
                .foregroundStyle(.rxInkSecondary)
            Spacer()
            Button("Unlock") {
                activeContext.isInteractionLocked = false
            }
            .buttonStyle(.rx(size: .small))
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.vertical, 6)
        .background(Color.rxSurfaceSunken)
    }

    private var title: String {
        switch activeContext.remoteType {
        case .machine: return activeContext.machine.name
        default: return activeContext.navigationTitle
        }
    }

    private var subtitle: String {
        guard activeContext.remoteType == .machine else { return "" }
        let machine = activeContext.machine
        let identity = machine.associatedIdentity.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.identityGroup[$0] }
        let user = machine.loginUsername(with: identity)
        var text = user.isEmpty ? machine.remoteAddress : "\(user)@\(machine.remoteAddress)"
        if machine.remotePort != "22" { text += ":\(machine.remotePort)" }
        return text
    }
}

// MARK: - Persistent Terminal Surface Pane

private struct TerminalPaneSurface: View {
    @ObservedObject var context: TerminalContext
    let isActive: Bool
    let bottomReserve: CGFloat
    let fontSize: Int

    @State private var terminalSize: CGSize = TerminalContext.defaultTerminalSize

    var body: some View {
        GeometryReader { r in
            context.termInterface
                .onChange(of: r.size) { _, _ in
                    guard isActive else { return }
                    updateTerminalSize()
                }
                .onAppear {
                    context.termInterface.setTerminalFontSize(with: fontSize, preferConfigured: false)
                    context.termInterface.setActive(isActive)
                }
                .onChange(of: fontSize) { _, newValue in
                    context.termInterface.setTerminalFontSize(with: newValue)
                }
                .padding(.horizontal, r.size.width > 600 ? 8 : 2)
                .padding(.top, 2)
                .padding(.bottom, bottomReserve)
        }
    }

    private func updateTerminalSize() {
        let core = context.termInterface
        let origSize = terminalSize
        DispatchQueue.global().async {
            let newSize = core.requestTerminalSize()
            guard newSize.width > 5, newSize.height > 5 else { return }
            if newSize != origSize {
                onMainThread {
                    terminalSize = newSize
                    context.shell.explicitRequestStatusPickup()
                }
            }
        }
    }
}

// MARK: - iPad / Regular-Width Top Tab Strip

private struct TerminalTopTabStrip: View {
    let terminals: [TerminalContext]
    let activeID: UUID
    let onSelect: (TerminalContext) -> Void
    let onClose: (TerminalContext) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(terminals) { term in
                        TopTabPill(
                            context: term,
                            isSelected: term.id == activeID,
                            onSelect: { onSelect(term) },
                            onClose: { onClose(term) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .accessibilityLabel("New Terminal")
        }
        .frame(height: 38)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.85))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private struct TopTabPill: View {
        @ObservedObject var context: TerminalContext
        let isSelected: Bool
        let onSelect: () -> Void
        let onClose: () -> Void

        var body: some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(context.closed ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(context.machine.isNotPlaceholder() ? context.machine.name : context.navigationTitle)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(3)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color(uiColor: .tertiarySystemBackground) : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.6)
            )
            .contentShape(Capsule())
            .onTapGesture(perform: onSelect)
        }
    }
}

// MARK: - iGhostVT-Style Session Status Overlay

private struct SessionStatusOverlay: View {
    @ObservedObject var context: TerminalContext
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if context.closed {
                VStack(spacing: 14) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.orange)
                    VStack(spacing: 4) {
                        Text("Connection Closed")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("The remote shell ended or the network dropped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 10) {
                        Button("Close") {
                            onClose()
                        }
                        .appleGlassButton()

                        Button("Reconnect") {
                            context.reconnect()
                        }
                        .appleProminentButton()
                    }
                }
                .padding(20)
                .frame(maxWidth: 290)
                .barGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else if context.bannerState == .connecting || context.bannerState == .awaitingShell {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            context.bannerState == .awaitingShell
                                ? String(localized: "Starting shell…")
                                : String(localized: "Connecting…")
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .barGlass(in: Capsule())
                    .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.25), value: context.bannerState)
        .animation(.snappy(duration: 0.25), value: context.closed)
    }
}

private struct TerminalLiveMetricsStrip: View {
    @ObservedObject var session: MonitorSession

    var body: some View {
        HStack(spacing: RX.Space.s4) {
            Text("CPU \(RXFormat.percent(Double(session.status.processor.summary.sumUsed)))%")
            Text("Mem \(RXFormat.percent(session.status.memoryUsedPercent))%")
            Spacer()
            Text("↓ \(RXFormat.rateString(Double(session.status.totalReceivePerSecond))) ↑ \(RXFormat.rateString(Double(session.status.totalTransmitPerSecond)))")
        }
        .font(.system(size: 11, design: .monospaced).monospacedDigit())
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 24)
        .background(Color.rxSurface)
    }
}

//
//  TerminalContext.swift
//  TamioMobile
//
//  Bridges TamioModule's shared SSH terminal core to Ghostty's lockable iOS
//  surface, customizable keyboard bar, and modal presentation.
//

import SwiftUI
import TamioModule
import TamioTerminal
import UIKit

final class TerminalSurfaceBridge: TerminalSessionSurface {
    let termInterface = TamioTerminalView()
    var onOutput: ((String) -> Void)?

    func write(_ string: String) {
        termInterface.write(string)
        onOutput?(string)
    }

    func setupBellChain(_ callback: @escaping () -> Void) {
        termInterface.setupBellChain(callback: callback)
    }

    func setupBufferChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupBufferChain(callback: callback)
    }

    func setupTitleChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupTitleChain(callback: callback)
    }

    func setupSizeChain(_ callback: @escaping (CGSize) -> Void) {
        termInterface.setupSizeChain(callback: callback)
    }
}

final class TerminalContext: TamioModule.TerminalContext {
    enum ConnectionBannerState: Equatable {
        case connecting
        case awaitingShell
        case ready
        case disconnected
    }

    private let surfaceBridge = TerminalSurfaceBridge()
    var termInterface: TamioTerminalView { surfaceBridge.termInterface }

    /// Mirrors iGhostVT's `SessionStatusOverlay` states so slow connections or
    /// shells show a clear Liquid Glass pill instead of a blank black screen.
    @Published private(set) var bannerState: ConnectionBannerState = .connecting
    private var outputWatchdog: Task<Void, Never>?
    private var receivedShellByte = false

    @Published var isInteractionLocked = false {
        didSet {
            let locked = isInteractionLocked
            nonisolated(unsafe) let term = termInterface
            Task { @MainActor in
                term.setInteractionLocked(locked)
            }
        }
    }

    @Published var isSoftwareKeyboardLocked = false {
        didSet {
            let locked = isSoftwareKeyboardLocked
            nonisolated(unsafe) let term = termInterface
            Task { @MainActor in
                term.setSoftwareKeyboardLocked(locked)
            }
        }
    }

    init(machine: RDMachine) {
        super.init(machine: machine, surface: surfaceBridge)
        configureSurface()
    }

    init(command: SSHCommandReader) {
        super.init(command: command, surface: surfaceBridge)
        configureSurface()
    }

    private func configureSurface() {
        termInterface.setTerminalFontSize(with: TamioStore.shared.terminalFontSize)
        nonisolated(unsafe) weak var weakSelf = self
        surfaceBridge.onOutput = { chunk in
            // Ignore our own bracketed bootstrap status lines (`[i] ...`) when
            // deciding whether the remote shell has produced its first byte.
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("[i]"), !trimmed.hasPrefix("[E]") else { return }
            Task { @MainActor in
                guard let self = weakSelf, !self.receivedShellByte else { return }
                self.receivedShellByte = true
                self.outputWatchdog?.cancel()
                if !self.closed {
                    self.bannerState = .ready
                }
            }
        }
        nonisolated(unsafe) let term = termInterface
        Task { @MainActor in
            term.setInputAccessoryItems(KeyboardBarStore.shared.items)
            weakSelf?.startStartupWatchdog()
        }
    }

    @MainActor
    private func startStartupWatchdog() {
        outputWatchdog?.cancel()
        receivedShellByte = false
        bannerState = .connecting
        nonisolated(unsafe) weak var weakSelf = self
        outputWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self = weakSelf, !Task.isCancelled else { return }
            if self.closed {
                self.bannerState = .disconnected
            } else if !self.receivedShellByte {
                self.bannerState = self.shell.isAuthenticated ? .awaitingShell : .connecting
            }
            // Keep checking briefly until authenticated or first byte arrives.
            for _ in 0 ..< 15 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self = weakSelf, !Task.isCancelled else { return }
                if self.closed {
                    self.bannerState = .disconnected
                    return
                }
                if self.receivedShellByte {
                    self.bannerState = .ready
                    return
                }
                if self.shell.isAuthenticated, self.bannerState != .awaitingShell {
                    self.bannerState = .awaitingShell
                }
            }
        }
    }

    @MainActor
    func syncBannerState() {
        if closed {
            outputWatchdog?.cancel()
            if bannerState != .disconnected { bannerState = .disconnected }
        } else if receivedShellByte {
            if bannerState != .ready { bannerState = .ready }
        }
    }

    @MainActor
    func applyKeyboardBar() {
        termInterface.setInputAccessoryItems(KeyboardBarStore.shared.items)
    }

    @MainActor
    func reconnect() {
        guard closed else { return }
        startStartupWatchdog()
        nonisolated(unsafe) let target = self
        DispatchQueue.global().async {
            target.putInformation(String(localized: "[i] Reconnecting with the details from when this session started."))
            target.putInformation(String(localized: "    If the server was edited, open a new terminal instead."))
            target.processBootstrap()
        }
    }
}

extension TerminalContext {
    struct DefaultPresent: View {
        let context: TerminalContext
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                TerminalView(context: context)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                HapticsPreference.impact()
                                dismiss()
                            } label: {
                                Label("Done", systemImage: "chevron.down")
                            }
                        }
                    }
            }
            .tint(.rxAccent)
        }
    }
}

/// Bridges TamioModule's shared terminal core to UIKit UI.
final class IOSTerminalUIHandler: TerminalUIHandler {
    func autoOpenInterface(_ context: TamioModule.TerminalContext) {
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated { present(context) }
    }

    @MainActor private func present(_ context: TamioModule.TerminalContext) {
        guard let context = context as? TerminalContext else { return }
        TerminalManager.shared.activeTerminalID = context.id
        let host = UIHostingController(
            rootView: TerminalContext.DefaultPresent(context: context)
        )
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = preferredPopOverSize
        PresentationQueue.present(next: host)
    }
}

//
//  TamioMobileApp.swift
//  TamioMobile
//
//  Created by Lakr Aream on 2022/3/2.
//

import CodeEditorUI
import MachineStatusView
import SwiftUI
import TamioModule
import TamioTerminal

@main
struct TamioMobileApp: App {
    // Non-observing reference so TamioStore edits do not re-evaluate the entire
    // WindowGroup root; individual views subscribe via @EnvironmentObject.
    private let store = TamioStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            NSLog("\nCommand Arguments:\n" + CommandLine.arguments.joined(separator: "\n"))
        #endif

        FileTransferInterface.uiHandler = IOSFileTransferUIHandler()

        _ = LogRedirect.shared
        _ = TamioStore.shared
        CloudSync.shared.preferences = SyncedSettings.all
        CloudSync.shared.start()
        LiveStatusCenter.shared.start()
        MobileAgentBridge.shared.install()
        PortForwardBackend.shared.reportProblem = { UIBridge.presentError(with: $0) }
        NetworkPathWatcher.shared.start()
        BackgroundGraceController.install()

        #if DEBUG
            Self.addPreviewServer()
        #endif
        NSLog("static main completed")
    }

    #if DEBUG
        private static func addPreviewServer() {
            let environment = ProcessInfo.processInfo.environment
            guard let server = environment["TAMIO_PREVIEW_SERVER"], let keyPath = environment["TAMIO_PREVIEW_KEY"],
                  let command = SSHCommandReader(command: "ssh \(server)")
            else { return }
            let store = TamioStore.shared
            guard !store.machineGroup.machines.contains(where: { $0.remoteAddress == command.remoteAddress && $0.remotePort == command.remotePort }),
                  let privateKey = try? String(contentsOfFile: keyPath, encoding: .utf8)
            else { return }
            let publicKey = (try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8)) ?? ""
            var identity = RDIdentity(privateKey: privateKey, publicKey: publicKey, authenticAutomatically: true)
            identity.name = "Preview key"
            var machine = RDMachine(remoteAddress: command.remoteAddress, remotePort: command.remotePort, name: "Preview server")
            machine.username = command.username
            machine.associatedIdentity = identity.id.uuidString
            store.identityGroup.insert(identity)
            store.machineGroup.insert(machine)
            if store.snippetGroup.snippets.isEmpty {
                var snippet = RDSnippet()
                snippet.name = "Disk usage"
                snippet.group = "Checks"
                snippet.comment = "Every mounted file system"
                snippet.code = "df -h"
                store.snippetGroup.insert(snippet)
            }
            if store.portForwardGroup.forwards.isEmpty {
                var forward = RDPortForward()
                forward.forwardOrientation = .listenLocal
                forward.bindPort = 8080
                forward.usingMachine = machine.id
                forward.targetHost = "127.0.0.1"
                forward.targetPort = 80
                store.portForwardGroup.insert(forward)
            }
            if environment["TAMIO_PREVIEW_OPEN"] == "terminal" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    TerminalManager.shared.begin(for: machine.id)
                }
            }
        }
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(store)
                    .environment(\.serverActions, .ios)
                AppLockOverlay()
            }
            #if DEBUG
            .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.environment["TAMIO_PREVIEW_EDITOR"] != nil)) {
                EditorPreviewScreen()
            }
            #endif
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onAppear {
                AppearancePreference.applyStored()
                checkAgreement()
            }
            .onReceive(store.$licenseAgreed.removeDuplicates()) { _ in
                checkAgreement()
            }
            .onChange(of: scenePhase) { _, phase in
                LiveStatusCenter.shared.setWindowVisible(phase == .active)
                AppLockManager.shared.handleScenePhase(phase)
                if phase == .active, MobileTerminalPreferences.autoReconnect {
                    TerminalManager.shared.reconnectDroppedSessions()
                }
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "tamio",
           let rawID = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: rawID)
        {
            if url.host == "session",
               let existing = TerminalManager.shared.terminals.first(where: { $0.id == uuid })
            {
                TerminalManager.shared.activeTerminalID = existing.id
                let host = UIHostingController(rootView: TerminalContext.DefaultPresent(context: existing))
                host.modalTransitionStyle = .coverVertical
                host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
                host.preferredContentSize = preferredPopOverSize
                PresentationQueue.present(next: host)
                return
            }
            if url.host == "server", store.machineGroup[uuid].isNotPlaceholder() {
                TerminalManager.shared.begin(for: uuid, force: true)
                return
            }
        }
        if url.pathExtension.lowercased() == "vtrpsc" {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try GhostRemoteStore.shared.importRelay(data: data)
            } catch {
                UIBridge.presentError(with: error.localizedDescription)
            }
        }
    }

    func checkAgreement() {
        guard !store.licenseAgreed else { return }
        let host = UIHostingController(rootView: AgreementView())
        host.preferredContentSize = preferredPopOverSize
        host.isModalInPresentation = true
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = .formSheet
        PresentationQueue.present(next: host)
    }
}

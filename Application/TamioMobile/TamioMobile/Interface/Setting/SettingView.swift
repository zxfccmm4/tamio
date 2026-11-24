//
//  SettingView.swift
//  TamioMobile
//
//  Clean, lightweight Apple native Settings list: plain semantic labels,
//  system Picker / Toggle / Stepper controls, zero visual clutter.
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule
import TamioTerminal

struct SettingView: View {
    @ObservedObject private var store = TamioStore.shared
    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var sync = CloudSync.shared

    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(MobileTerminalPreferences.keepScreenAwakeKey) private var keepAwake = true
    @AppStorage(MobileTerminalPreferences.autoReconnectKey) private var autoReconnect = true
    @AppStorage(AppLockManager.enabledKey) private var appLockEnabled = false
    @AppStorage(AppLockManager.timeoutKey) private var lockTimeout = 60
    @AppStorage(FilesPreference.showsHiddenKey) private var showsHidden = false
    @AppStorage(RemoteClipboardPreference.allowsWriteKey) private var allowsRemoteClipboard = false

    @State private var hostKeyCount = KnownHosts.shared.count
    @State private var showsKeyboardEditor = false

    private let refreshIntervals = [3, 5, 10, 15, 30, 60]

    var body: some View {
        List {
            Section("Appearance & Terminal") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(AppearancePreference.system.rawValue)
                    Text("Light").tag(AppearancePreference.light.rawValue)
                    Text("Dark").tag(AppearancePreference.dark.rawValue)
                }
                .onChange(of: appearance) { _, raw in
                    (AppearancePreference(rawValue: raw) ?? .system).apply()
                }

                NavigationLink("Terminal Engine & Themes") {
                    GhosttySettingsDestination()
                }

                Button("Keyboard Bar") {
                    showsKeyboardEditor = true
                }
                .foregroundStyle(.primary)

                Toggle("Allow Programs to Copy (OSC 52)", isOn: $allowsRemoteClipboard)
            }

            Section {
                Toggle("Open Terminal Automatically", isOn: $store.openInterfaceAutomatically)
                Toggle("Confirm Before Closing", isOn: Binding(
                    get: { !store.disableConformation },
                    set: { store.disableConformation = !$0 }
                ))
                Toggle("Keep Screen Awake", isOn: $keepAwake)
                Toggle("Auto-Reconnect on Resume", isOn: $autoReconnect)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Auto-reconnect checks dropped SSH sessions when returning to Tamio or switching between Wi-Fi and cellular.")
            }

            Section {
                Toggle("Face ID / Passcode Lock", isOn: $appLockEnabled)
                if appLockEnabled {
                    Picker("Require After", selection: $lockTimeout) {
                        Text("Immediately").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Blurs the app switcher preview and locks Tamio after leaving the app.")
            }

            Section("Sync & Files") {
                NavigationLink {
                    ScrollView {
                        CloudSyncSettings()
                            .padding(16)
                    }
                    .appleGroupedBackground()
                    .navigationTitle("iCloud Sync")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("iCloud Sync", value: syncStatusLabel)
                }

                NavigationLink {
                    BackupTransferView()
                } label: {
                    Label("Export & Import Backup", systemImage: "arrow.up.arrow.down.circle")
                }

                Toggle("Show Hidden Files in SFTP", isOn: $showsHidden)

                Button("Open App Files") {
                    UIBridge.openFileContainer()
                }
                .foregroundStyle(.primary)
            }

            Section("SSH & Monitor") {
                Stepper(value: $store.timeout, in: 2 ... 30) {
                    LabeledContent("Connection Timeout", value: String(localized: "\(store.timeout) s"))
                }

                Toggle("Live Server Status", isOn: $live.isEnabled)

                if live.isEnabled {
                    Picker("Refresh Interval", selection: Binding(
                        get: { max(3, store.monitorInterval) },
                        set: { store.monitorInterval = $0 }
                    )) {
                        ForEach(refreshIntervals, id: \.self) { seconds in
                            Text(String(localized: "Every \(seconds) s")).tag(seconds)
                        }
                    }
                }

                Button(role: .destructive) {
                    UIBridge.requiresConfirmation(
                        message: String(localized: "Forget all saved host keys?"),
                        confirmTitle: String(localized: "Forget All"),
                        destructive: true
                    ) { confirmed in
                        guard confirmed else { return }
                        KnownHosts.shared.forgetAll()
                        hostKeyCount = KnownHosts.shared.count
                    }
                } label: {
                    LabeledContent("Forget Saved Host Keys", value: "\(hostKeyCount)")
                }
                .disabled(hostKeyCount == 0)
            }

            Section {
                NavigationLink {
                    AIProviderSettingsView(store: AIProviderStore.shared)
                } label: {
                    let appleReady = AppleIntelligenceStatus.current == .available
                    let selection = AIProviderStore.shared.effectiveSelection(appleIntelligenceAvailable: appleReady)
                    HStack(spacing: 10) {
                        AIProviderInlineIcon(
                            source: AIProviderIconSource.from(selection: selection, store: AIProviderStore.shared),
                            length: 18
                        )
                        Text("AI Providers")
                        Spacer()
                        Text(AIProviderStore.shared.activeDisplayName(appleIntelligenceAvailable: appleReady))
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    ServerOpsSkillsView(
                        store: ServerOpsSkillStore.shared,
                        assistant: ServerAssistant.shared,
                        showsDoneButton: false
                    )
                } label: {
                    LabeledContent("Ops Skills", value: "\(ServerOpsSkillStore.shared.enabledSkills.count)")
                }

                Picker("Context Budget", selection: Binding(
                    get: { ServerAssistant.shared.contextTokenBudget },
                    set: { ServerAssistant.shared.contextTokenBudget = $0 }
                )) {
                    Text("16K").tag(16_000)
                    Text("32K").tag(32_000)
                    Text("64K").tag(64_000)
                    Text("128K").tag(128_000)
                }

                Toggle("Cross-Session Memory", isOn: Binding(
                    get: { ServerAssistant.shared.crossSessionMemoryEnabled },
                    set: { ServerAssistant.shared.crossSessionMemoryEnabled = $0 }
                ))
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Cross-Session Memory summarizes past ops sessions locally so new chats remember recent findings.")
            }

            Section("Activity & Diagnostics") {
                NavigationLink("MCP Agent Activity") {
                    MobileAgentActivityPage()
                }
                NavigationLink("Diagnostic Logs") {
                    LogView()
                }
            }

            Section("About") {
                NavigationLink {
                    AboutView()
                } label: {
                    HStack(spacing: 12) {
                        Image("TamioLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(.rect(cornerRadius: 6.5, style: .continuous))
                        Text("About Tamio")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { hostKeyCount = KnownHosts.shared.count }
        .sheet(isPresented: $showsKeyboardEditor) {
            NavigationStack {
                KeyboardBarEditorSheet()
            }
        }
    }

    private var syncStatusLabel: String {
        switch sync.status {
        case .off: return String(localized: "Off")
        case .syncing: return String(localized: "Syncing…")
        case .synced: return String(localized: "On")
        case .locked: return String(localized: "Locked")
        case .unavailable, .unreadable, .failed: return String(localized: "Unavailable")
        }
    }
}

private struct GhosttySettingsDestination: View {
    @ObservedObject private var store = TamioStore.shared

    var body: some View {
        GhosttyConfigurationView(
            hostSections: [],
            onApplied: { size in
                if let size { store.terminalFontSize = Int(size.rounded()) }
            }
        )
        .navigationTitle("Terminal Engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileAgentActivityPage: View {
    @ObservedObject private var log = AgentServer.shared.log
    @State private var server: String?

    private var servers: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for entry in log.entries {
            for (id, name) in zip(entry.hosts, entry.hostNames) { names[id] = name }
        }
        for machine in TamioStore.shared.machineGroup.machines where names[machine.id.uuidString] != nil {
            names[machine.id.uuidString] = machine.name
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var shown: [AgentActivity] {
        guard let server else { return log.entries }
        return log.entries.filter { $0.hosts.contains(server) }
    }

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Agent Activity Yet", systemImage: "sparkles")
                } description: {
                    Text("MCP actions approved on your Mac sync here over iCloud so you can review what AI agents did on your servers.")
                }
                .appleGroupedBackground()
            } else {
                List {
                    Section {
                        Picker("Server", selection: $server) {
                            Text("All Servers").tag(String?.none)
                            ForEach(servers, id: \.id) { item in
                                Text(verbatim: item.name).tag(Optional(item.id))
                            }
                        }
                    }
                    Section("History") {
                        ForEach(shown.suffix(50).reversed()) { entry in
                            AgentActivityRow(entry: entry, showsHosts: server == nil)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("MCP Agent Activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementsPage: View {
    var body: some View {
        List {
            Section("Contributors") {
                Text(verbatim: "@mizorewww · @missuo · @Lakr233 · @sarkrui · @SukkaW · @thedavidweng · @delete-cloud · @FahimFBA · @NyaMisty · @FaiChou")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Upstream") {
                LabeledContent("Based on", value: "mizorewww/catussh · Lakr233/Rayon")
                Text("Originally created by Lakr Aream (@Lakr233) with @__oquery, @zlind0, @unixzii, @82flex and @xnth97. This version is not affiliated with or endorsed by them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Open Source") {
                Text("Ghostty and its configuration catalog (MIT, Ghostty contributors).")
                    .font(.subheadline)
                Text("Mobile terminal UX & Ghost Remote concepts inspired by iGhostVT (MIT, owngoal-dev).")
                    .font(.subheadline)
                Text("Libraries: libssh2 · NSRemoteShell · XMLCoder · SymbolPicker · Keychain · Runestone · Lucide Icons.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let key = "sb.moe.tamio.appearance"

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: key) ?? AppearancePreference.system.rawValue
        (AppearancePreference(rawValue: raw) ?? .system).apply()
    }
}

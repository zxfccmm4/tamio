//
//  SettingView.swift
//  TamioMobile
//
//  Unified Apple Settings-style `.insetGrouped` layout with tinted
//  `AppleFeatureBadge` icons matching MoreView, AboutView, and BackupTransferView.
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
    @AppStorage(HapticsPreference.enabledKey) private var hapticsEnabled = true
    @AppStorage(HapticsPreference.intensityKey) private var hapticsIntensity = HapticsIntensity.medium.rawValue
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
            // MARK: Appearance & Terminal
            Section("Appearance & Terminal") {
                Picker(selection: $appearance) {
                    Text("System").tag(AppearancePreference.system.rawValue)
                    Text("Light").tag(AppearancePreference.light.rawValue)
                    Text("Dark").tag(AppearancePreference.dark.rawValue)
                } label: {
                    settingLabel("Appearance", icon: "circle.lefthalf.filled", tint: .indigo)
                }
                .onChange(of: appearance) { _, raw in
                    (AppearancePreference(rawValue: raw) ?? .system).apply()
                }

                Toggle(isOn: $hapticsEnabled) {
                    settingLabel("Haptic Feedback", icon: "iphone.radiowaves.left.and.right", tint: .orange)
                }
                .onChange(of: hapticsEnabled) { _, enabled in
                    if enabled { HapticsPreference.impact() }
                }

                if hapticsEnabled {
                    Picker(selection: $hapticsIntensity) {
                        ForEach(HapticsIntensity.allCases) { level in
                            Text(level.localizedTitle).tag(level.rawValue)
                        }
                    } label: {
                        settingLabel("Haptic Intensity", icon: "waveform", tint: .orange)
                    }
                    .onChange(of: hapticsIntensity) { _, raw in
                        HapticsPreference.preview(HapticsIntensity(rawValue: raw) ?? .medium)
                    }
                }

                NavigationLink {
                    GhosttySettingsDestination()
                } label: {
                    settingLabel("Terminal Engine & Themes", icon: "paintpalette.fill", tint: .pink)
                }

                Button {
                    showsKeyboardEditor = true
                } label: {
                    HStack(spacing: 12) {
                        settingLabel("Keyboard Bar", icon: "keyboard.fill", tint: .purple)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)

                Toggle(isOn: $allowsRemoteClipboard) {
                    settingLabel("Allow Programs to Copy (OSC 52)", icon: "doc.on.clipboard.fill", tint: .teal)
                }
            }

            // MARK: Sessions & Security
            Section {
                Toggle(isOn: $store.openInterfaceAutomatically) {
                    settingLabel("Open Terminal Automatically", icon: "terminal.fill", tint: .blue)
                }
                Toggle(isOn: Binding(
                    get: { !store.disableConformation },
                    set: { store.disableConformation = !$0 }
                )) {
                    settingLabel("Confirm Before Closing", icon: "exclamationmark.shield.fill", tint: .orange)
                }
                Toggle(isOn: $keepAwake) {
                    settingLabel("Keep Screen Awake", icon: "sun.max.fill", tint: .yellow)
                }
                Toggle(isOn: $autoReconnect) {
                    settingLabel("Auto-Reconnect on Resume", icon: "arrow.triangle.2.circlepath", tint: .green)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Auto-reconnect checks dropped SSH sessions when returning to Tamio or switching between Wi-Fi and cellular.")
            }

            Section {
                Toggle(isOn: $appLockEnabled) {
                    settingLabel("Face ID / Passcode Lock", icon: "faceid", tint: .green)
                }
                if appLockEnabled {
                    Picker(selection: $lockTimeout) {
                        Text("Immediately").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    } label: {
                        settingLabel("Require After", icon: "timer", tint: .secondary)
                    }
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Blurs the app switcher preview and locks Tamio after leaving the app.")
            }

            // MARK: Sync, Backup & Files
            Section("Sync & Files") {
                NavigationLink {
                    ScrollView {
                        VStack(spacing: 16) {
                            CloudSyncSettings()
                                .padding(16)
                                .background(
                                    Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                        }
                        .padding(16)
                    }
                    .appleGroupedBackground()
                    .navigationTitle("iCloud Sync")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: 12) {
                        settingLabel("iCloud Sync", icon: "icloud.fill", tint: .blue)
                        Spacer()
                        Text(syncStatusLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    BackupTransferView()
                } label: {
                    settingLabel("Export & Import Backup", icon: "arrow.up.arrow.down.circle.fill", tint: .cyan)
                }

                Toggle(isOn: $showsHidden) {
                    settingLabel("Show Hidden Files in SFTP", icon: "eye.fill", tint: .indigo)
                }

                Button {
                    UIBridge.openFileContainer()
                } label: {
                    HStack(spacing: 12) {
                        settingLabel("Open App Files", icon: "folder.fill", tint: .blue)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }

            // MARK: SSH & Monitor
            Section("SSH & Monitor") {
                Stepper(value: $store.timeout, in: 2 ... 30) {
                    HStack(spacing: 12) {
                        settingLabel("Connection Timeout", icon: "clock.fill", tint: .orange)
                        Spacer()
                        Text(String(localized: "\(store.timeout) s"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $live.isEnabled) {
                    settingLabel("Live Server Status", icon: "waveform.path.ecg", tint: .green)
                }

                if live.isEnabled {
                    Picker(selection: Binding(
                        get: { max(3, store.monitorInterval) },
                        set: { store.monitorInterval = $0 }
                    )) {
                        ForEach(refreshIntervals, id: \.self) { seconds in
                            Text(String(localized: "Every \(seconds) s")).tag(seconds)
                        }
                    } label: {
                        settingLabel("Refresh Interval", icon: "gauge.with.dots.needle.67percent", tint: .teal)
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
                    HStack(spacing: 12) {
                        AppleFeatureBadge(systemImage: "key.slash.fill", tint: .red, size: 28)
                        Text("Forget Saved Host Keys")
                        Spacer()
                        Text("\(hostKeyCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(hostKeyCount == 0)
            }

            // MARK: AI Assistant
            Section {
                NavigationLink {
                    AIProviderSettingsView(store: AIProviderStore.shared)
                } label: {
                    let appleReady = AppleIntelligenceStatus.current == .available
                    let selection = AIProviderStore.shared.effectiveSelection(appleIntelligenceAvailable: appleReady)
                    HStack(spacing: 12) {
                        AIProviderInlineIcon(
                            source: AIProviderIconSource.from(selection: selection, store: AIProviderStore.shared),
                            length: 22
                        )
                        .frame(width: 28, height: 28)
                        .background(
                            Color.purple.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        Text("AI Providers")
                        Spacer()
                        Text(AIProviderStore.shared.activeDisplayName(appleIntelligenceAvailable: appleReady))
                            .font(.subheadline)
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
                    HStack(spacing: 12) {
                        settingLabel("Ops Skills", icon: "wand.and.stars", tint: .purple)
                        Spacer()
                        Text("\(ServerOpsSkillStore.shared.enabledSkills.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(selection: Binding(
                    get: { ServerAssistant.shared.contextTokenBudget },
                    set: { ServerAssistant.shared.contextTokenBudget = $0 }
                )) {
                    Text("16K").tag(16_000)
                    Text("32K").tag(32_000)
                    Text("64K").tag(64_000)
                    Text("128K").tag(128_000)
                } label: {
                    settingLabel("Context Budget", icon: "memorychip.fill", tint: .indigo)
                }

                Toggle(isOn: Binding(
                    get: { ServerAssistant.shared.crossSessionMemoryEnabled },
                    set: { ServerAssistant.shared.crossSessionMemoryEnabled = $0 }
                )) {
                    settingLabel("Cross-Session Memory", icon: "brain.head.profile", tint: .pink)
                }
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Cross-Session Memory summarizes past ops sessions locally so new chats remember recent findings.")
            }

            // MARK: Activity & Diagnostics
            Section("Activity & Diagnostics") {
                NavigationLink {
                    MobileAgentActivityPage()
                } label: {
                    settingLabel("MCP Agent Activity", icon: "sparkles", tint: .purple)
                }
                NavigationLink {
                    LogView()
                } label: {
                    settingLabel("Diagnostic Logs", icon: "doc.text.magnifyingglass", tint: .secondary)
                }
            }

            // MARK: About
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
        .appleGroupedBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { hostKeyCount = KnownHosts.shared.count }
        .sheet(isPresented: $showsKeyboardEditor) {
            NavigationStack {
                KeyboardBarEditorSheet()
            }
        }
    }

    private func settingLabel(_ title: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            AppleFeatureBadge(systemImage: icon, tint: tint, size: 28)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
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
        .navigationTitle("Terminal Engine & Themes")
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

enum HapticsIntensity: String, CaseIterable, Identifiable {
    case light
    case medium
    case heavy

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .light: return "Soft"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        }
    }

    var feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }

    var intensityValue: CGFloat {
        switch self {
        case .light: return 0.55
        case .medium: return 0.80
        case .heavy: return 1.0
        }
    }
}

enum HapticsPreference {
    static let enabledKey = "sb.moe.tamio.haptics.enabled"
    static let intensityKey = "sb.moe.tamio.haptics.intensity"

    static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
            return stored
        }
        return true
    }

    static var intensity: HapticsIntensity {
        let raw = UserDefaults.standard.string(forKey: intensityKey) ?? HapticsIntensity.medium.rawValue
        return HapticsIntensity(rawValue: raw) ?? .medium
    }

    @MainActor
    static func impact() {
        guard isEnabled else { return }
        preview(intensity)
    }

    @MainActor
    static func preview(_ level: HapticsIntensity) {
        let generator = UIImpactFeedbackGenerator(style: level.feedbackStyle)
        generator.prepare()
        generator.impactOccurred(intensity: level.intensityValue)
    }
}

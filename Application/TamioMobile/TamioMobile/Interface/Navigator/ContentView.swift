//
//  ContentView.swift
//  TamioMobile
//
//  Native Apple iOS 26/27 navigation shell:
//  - iOS 18+/26+: Adaptive TabView (`Tab` + `TabSection` + `.sidebarAdaptable`
//    + `.tabBarMinimizeBehavior(.onScrollDown)`), presenting a Liquid Glass
//    floating tab bar on iPhone and a collapsible sidebar / top bar on iPad.
//  - iOS 17: Clean fallback to TabView (iPhone) and NavigationSplitView (iPad).
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

enum AppRoute: Hashable {
    case home
    case servers
    case assistant
    case sessions
    case snippets
    case more
    case identities
    case portForward
    case ghostRemote
    case settings
    case terminal(UUID)
    case ghostSession(UUID)
    case monitor(UUID)
    case transfer(UUID)
}

struct ContentView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selection: AppRoute = {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["TAMIO_PREVIEW_TAB"]
                ?? ProcessInfo.processInfo.environment["TAMIO_PREVIEW_ROUTE"]
            {
            case "servers": return .servers
            case "assistant": return .assistant
            case "sessions": return .sessions
            case "snippets": return .snippets
            case "more": return .more
            case "identities": return .identities
            case "portforward": return .portForward
            case "ghostremote": return .ghostRemote
            case "settings": return .settings
            default: break
            }
        #endif
        return .home
    }()

    @ObservedObject private var terminals = TerminalManager.shared
    @ObservedObject private var remoteSessions = GhostRemoteSessionManager.shared
    @ObservedObject private var remoteStore = GhostRemoteStore.shared
    @ObservedObject private var monitors = MonitorCenter.shared
    @ObservedObject private var transfers = FileTransferManager.shared

    private var activeSessionCount: Int {
        terminals.terminals.count + remoteSessions.sessions.count + monitors.sessions.count + transfers.transfers.count
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabShell
            } else if sizeClass == .compact {
                legacyPhoneShell
            } else {
                legacyPadShell
            }
        }
        .tint(.rxAccent)
    }

    // MARK: - iOS 18 / 26 / 27 Adaptive Native Shell

    /// Places the AI Assistant as a detached standalone Liquid Glass button on
    /// the far right of the floating tab bar on iOS 26+.
    @available(iOS 18.0, *)
    private var assistantTabRole: TabRole? {
        if #available(iOS 26.0, *) {
            return .search
        }
        return nil
    }

    @available(iOS 18.0, *)
    private var modernTabShell: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "square.grid.2x2", value: AppRoute.home) {
                NavigationStack { HomeView() }
            }

            Tab("Servers", systemImage: "server.rack", value: AppRoute.servers) {
                NavigationStack { ServersView() }
            }

            Tab("Sessions", systemImage: "terminal", value: AppRoute.sessions) {
                NavigationStack { SessionsView() }
            }
            .badge(activeSessionCount)

            // On iPhone the main pill holds four tabs; Snippets moves into More.
            if sizeClass != .compact {
                Tab("Snippets", systemImage: "chevron.left.forwardslash.chevron.right", value: AppRoute.snippets) {
                    NavigationStack { SnippetView() }
                }
            }

            if sizeClass == .compact {
                Tab("More", systemImage: "ellipsis.circle", value: AppRoute.more) {
                    NavigationStack { MoreView() }
                }
            } else {
                TabSection("Manage") {
                    Tab("Identities", systemImage: "key", value: AppRoute.identities) {
                        NavigationStack { IdentityView() }
                    }
                    .badge(store.identityGroup.shared.count)

                    Tab("Port Forward", systemImage: "arrow.left.arrow.right", value: AppRoute.portForward) {
                        NavigationStack { PortForwardView() }
                    }
                    .badge(store.portForwardGroup.count)

                    Tab("Ghost Remote", systemImage: "wifi", value: AppRoute.ghostRemote) {
                        NavigationStack { GhostRemoteView() }
                    }
                    .badge(remoteStore.pairedHosts.count)

                    Tab("Settings", systemImage: "gearshape", value: AppRoute.settings) {
                        NavigationStack { SettingView() }
                    }
                }

                if activeSessionCount > 0 {
                    TabSection("Active Sessions") {
                        ForEach(terminals.terminals) { context in
                            Tab(
                                context.machine.isNotPlaceholder() ? context.machine.name : context.navigationTitle,
                                systemImage: "terminal",
                                value: AppRoute.terminal(context.id)
                            ) {
                                NavigationStack { TerminalView(context: context).id(context.id) }
                            }
                        }
                        ForEach(remoteSessions.sessions) { session in
                            Tab(session.hostName, systemImage: "bolt.horizontal", value: AppRoute.ghostSession(session.id)) {
                                NavigationStack { GhostRemoteTerminalView(session: session).id(session.id) }
                            }
                        }
                        ForEach(monitors.sessions) { session in
                            Tab(session.machine.name, systemImage: "waveform.path.ecg", value: AppRoute.monitor(session.id)) {
                                NavigationStack { MonitorView(session: session).id(session.id) }
                            }
                        }
                        ForEach(transfers.transfers) { context in
                            Tab(context.machine.name, systemImage: "folder", value: AppRoute.transfer(context.id)) {
                                NavigationStack { FileTransferView(context: context).id(context.id) }
                            }
                        }
                    }
                }
            }

            // Detached far-right standalone button for AI Assistant.
            Tab(value: AppRoute.assistant, role: assistantTabRole) {
                NavigationStack { AssistantView() }
            } label: {
                Label("Assistant", systemImage: "sparkles")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .appleTabBarMinimize()
    }

    // MARK: - iOS 17 Fallbacks

    private var legacyPhoneShell: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "square.grid.2x2") }
                .tag(AppRoute.home)
            NavigationStack { ServersView() }
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(AppRoute.servers)
            NavigationStack { SessionsView() }
                .tabItem { Label("Sessions", systemImage: "terminal") }
                .badge(activeSessionCount)
                .tag(AppRoute.sessions)
            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppRoute.more)
            NavigationStack { AssistantView() }
                .tabItem { Label("Assistant", systemImage: "sparkles") }
                .tag(AppRoute.assistant)
        }
    }

    private var legacyPadShell: some View {
        NavigationSplitView {
            List(selection: Binding<AppRoute?>(get: { selection }, set: { if let v = $0 { selection = v } })) {
                Label("Home", systemImage: "square.grid.2x2").tag(AppRoute.home)
                Label("Assistant", systemImage: "sparkles").tag(AppRoute.assistant)
                Section("Manage") {
                    Label("Servers", systemImage: "server.rack").badge(store.machineGroup.count).tag(AppRoute.servers)
                    Label("Identities", systemImage: "key").badge(store.identityGroup.shared.count).tag(AppRoute.identities)
                    Label("Snippets", systemImage: "chevron.left.forwardslash.chevron.right").badge(store.snippetGroup.count).tag(AppRoute.snippets)
                    Label("Port Forward", systemImage: "arrow.left.arrow.right").badge(store.portForwardGroup.count).tag(AppRoute.portForward)
                    Label("Ghost Remote", systemImage: "wifi").badge(remoteStore.pairedHosts.count).tag(AppRoute.ghostRemote)
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(AppRoute.settings)
                }
            }
            .navigationTitle("Tamio")
        } detail: {
            NavigationStack {
                switch selection {
                case .home: HomeView()
                case .servers: ServersView()
                case .assistant: AssistantView()
                case .sessions: SessionsView()
                case .identities: IdentityView()
                case .snippets: SnippetView()
                case .portForward: PortForwardView()
                case .ghostRemote: GhostRemoteView()
                case .settings: SettingView()
                case .more: MoreView()
                case let .terminal(id):
                    if let ctx = terminals.terminals.first(where: { $0.id == id }) {
                        TerminalView(context: ctx).id(id)
                    } else {
                        HomeView()
                    }
                case let .ghostSession(id):
                    if let sess = remoteSessions.sessions.first(where: { $0.id == id }) {
                        GhostRemoteTerminalView(session: sess).id(id)
                    } else {
                        HomeView()
                    }
                case let .monitor(id):
                    if let sess = monitors.session(withID: id) {
                        MonitorView(session: sess).id(id)
                    } else {
                        HomeView()
                    }
                case let .transfer(id):
                    if let ctx = transfers.transfers.first(where: { $0.id == id }) {
                        FileTransferView(context: ctx).id(id)
                    } else {
                        HomeView()
                    }
                }
            }
        }
    }
}

// MARK: - Sessions Hub

struct SessionsView: View {
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var remoteSessions = GhostRemoteSessionManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared

    private var isEmpty: Bool {
        terminals.terminals.isEmpty && remoteSessions.sessions.isEmpty && monitors.sessions.isEmpty && transfers.transfers.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView {
                    Label("No Active Sessions", systemImage: "terminal")
                } description: {
                    Text("Open a server terminal, Ghost Remote session, SFTP transfer, or live monitor to manage it here.")
                }
                .appleGroupedBackground()
            } else {
                List {
                    if !terminals.terminals.isEmpty {
                        Section("Terminals") {
                            ForEach(terminals.terminals) { context in
                                NavigationLink {
                                    TerminalView(context: context)
                                } label: {
                                    SessionListRow(
                                        title: context.machine.isNotPlaceholder() ? context.machine.name : context.navigationTitle,
                                        subtitle: context.closed ? String(localized: "Disconnected") : String(localized: "Connected"),
                                        systemImage: "terminal",
                                        tint: .indigo,
                                        dotState: context.closed ? .offline : .online
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Close", role: .destructive) {
                                        TerminalManager.shared.end(for: context.id)
                                    }
                                }
                            }
                        }
                    }

                    if !remoteSessions.sessions.isEmpty {
                        Section("Ghost Remote") {
                            ForEach(remoteSessions.sessions) { session in
                                NavigationLink {
                                    GhostRemoteTerminalView(session: session)
                                } label: {
                                    SessionListRow(
                                        title: session.hostName,
                                        subtitle: session.state == .connected ? String(localized: "Connected") : String(localized: "Connecting…"),
                                        systemImage: "bolt.horizontal",
                                        tint: .teal,
                                        dotState: session.state == .connected ? .online : .connecting
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Close", role: .destructive) {
                                        GhostRemoteSessionManager.shared.closeSession(session.id)
                                    }
                                }
                            }
                        }
                    }

                    if !monitors.sessions.isEmpty {
                        Section("Monitors") {
                            ForEach(monitors.sessions) { session in
                                NavigationLink {
                                    MonitorView(session: session)
                                } label: {
                                    SessionListRow(
                                        title: session.machine.name,
                                        subtitle: String(localized: "Live metrics"),
                                        systemImage: "waveform.path.ecg",
                                        tint: .green,
                                        dotState: .online
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Close", role: .destructive) {
                                        MonitorCenter.shared.end(session.id)
                                    }
                                }
                            }
                        }
                    }

                    if !transfers.transfers.isEmpty {
                        Section("File Transfers") {
                            ForEach(transfers.transfers) { context in
                                NavigationLink {
                                    FileTransferView(context: context)
                                } label: {
                                    SessionListRow(
                                        title: context.machine.name,
                                        subtitle: String(localized: "SFTP Browser"),
                                        systemImage: "folder",
                                        tint: .blue,
                                        dotState: .online
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Close", role: .destructive) {
                                        FileTransferManager.shared.end(for: context.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SessionListRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let dotState: MobileStatusDot.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MobileStatusDot(state: dotState)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - More Hub (iPhone)

struct MoreView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var remoteStore = GhostRemoteStore.shared
    @ObservedObject private var forwardBackend = PortForwardBackend.shared
    @State private var pushed: Destination?
    @Namespace private var zoomNamespace

    enum Destination: String, Hashable, Identifiable {
        case snippets
        case identities
        case portForward
        case ghostRemote
        case aiProviders
        case settings
        case about
        case diagnostics

        var id: String { rawValue }
    }

    private var activeTunnelCount: Int {
        forwardBackend.container.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 2x2 Quick Tool Tiles with native iOS 18+ Zoom transition
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Manage")

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                        ],
                        spacing: 12
                    ) {
                        moreTile(
                            destination: .snippets,
                            title: String(localized: "Snippets"),
                            subtitle: String(localized: "Reusable commands"),
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: .green,
                            badge: store.snippetGroup.count > 0 ? "\(store.snippetGroup.count)" : nil
                        )

                        moreTile(
                            destination: .identities,
                            title: String(localized: "Identities"),
                            subtitle: String(localized: "SSH keys & auth"),
                            systemImage: "key.fill",
                            tint: .orange,
                            badge: store.identityGroup.shared.count > 0 ? "\(store.identityGroup.shared.count)" : nil
                        )

                        moreTile(
                            destination: .portForward,
                            title: String(localized: "Port Forward"),
                            subtitle: activeTunnelCount > 0
                                ? String(localized: "\(activeTunnelCount) active")
                                : String(localized: "Local & remote tunnels"),
                            systemImage: "arrow.left.arrow.right",
                            tint: .blue,
                            badge: store.portForwardGroup.count > 0 ? "\(store.portForwardGroup.count)" : nil,
                            badgeAccent: activeTunnelCount > 0 ? .green : nil
                        )

                        moreTile(
                            destination: .ghostRemote,
                            title: String(localized: "Ghost Remote"),
                            subtitle: String(localized: "LAN & relay sessions"),
                            systemImage: "wifi",
                            tint: .teal,
                            badge: remoteStore.pairedHosts.count > 0 ? "\(remoteStore.pairedHosts.count)" : nil
                        )
                    }
                }

                // AI & Preferences grouped card
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Application")

                    VStack(spacing: 0) {
                        let appleReady = AppleIntelligenceStatus.current == .available
                        let selection = AIProviderStore.shared.effectiveSelection(appleIntelligenceAvailable: appleReady)
                        moreCardRow(
                            destination: .aiProviders,
                            title: String(localized: "AI Providers"),
                            detail: AIProviderStore.shared.activeDisplayName(appleIntelligenceAvailable: appleReady)
                        ) {
                            AIProviderInlineIcon(
                                source: AIProviderIconSource.from(selection: selection, store: AIProviderStore.shared),
                                length: 18
                            )
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        rowDivider

                        moreCardRow(
                            destination: .settings,
                            title: String(localized: "Settings"),
                            detail: nil
                        ) {
                            AppleFeatureBadge(systemImage: "gearshape.fill", tint: .gray, size: 30)
                        }

                        rowDivider

                        moreCardRow(
                            destination: .about,
                            title: String(localized: "About Tamio"),
                            detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ) {
                            Image("TamioLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .clipShape(.rect(cornerRadius: 7.5, style: .continuous))
                        }

                        rowDivider

                        moreCardRow(
                            destination: .diagnostics,
                            title: String(localized: "Diagnostics"),
                            detail: nil
                        ) {
                            AppleFeatureBadge(systemImage: "doc.text.magnifyingglass", tint: .purple, size: 30)
                        }
                    }
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
                    )
                }

                Text(appVersion)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .appleGroupedBackground()
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $pushed) { destination in
            destinationView(for: destination)
                .appleGroupedBackground()
                .appleZoomDestination(sourceID: destination, in: zoomNamespace)
        }
        .onAppear {
            #if DEBUG
                switch ProcessInfo.processInfo.environment["TAMIO_PREVIEW_MORE"] {
                case "identities": pushed = .identities
                case "portforward": pushed = .portForward
                case "ghostremote": pushed = .ghostRemote
                case "settings": pushed = .settings
                default: break
                }
            #endif
        }
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .snippets: SnippetView()
        case .identities: IdentityView()
        case .portForward: PortForwardView()
        case .ghostRemote: GhostRemoteView()
        case .aiProviders: AIProviderSettingsView(store: AIProviderStore.shared)
        case .settings: SettingView()
        case .about: AboutView()
        case .diagnostics: LogView()
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 56)
            .opacity(colorScheme == .dark ? 0.5 : 0.45)
    }

    private func moreTile(
        destination: Destination,
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        badge: String?,
        badgeAccent: Color? = nil
    ) -> some View {
        Button {
            pushed = destination
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    AppleFeatureBadge(systemImage: systemImage, tint: tint, size: 34)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(badgeAccent ?? .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (badgeAccent ?? Color.primary).opacity(badgeAccent == nil ? 0.06 : 0.14),
                                in: Capsule()
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
            )
            .shadow(
                color: colorScheme == .dark ? .clear : Color.black.opacity(0.03),
                radius: 8,
                x: 0,
                y: 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .appleZoomSource(id: destination, in: zoomNamespace, cornerRadius: 18)
    }

    private func moreCardRow<Icon: View>(
        destination: Destination,
        title: String,
        detail: String?,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            pushed = destination
        } label: {
            HStack(spacing: 12) {
                icon()
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appleZoomSource(id: destination, in: zoomNamespace, cornerRadius: 12, appliesCardSurface: false)
    }
}

var appVersion: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? String(localized: "Unknown")
    #if DEBUG
        return "Tamio \(short) (\(build)) · Debug"
    #else
        return "Tamio \(short) (\(build))"
    #endif
}

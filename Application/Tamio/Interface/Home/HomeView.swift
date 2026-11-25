//
//  HomeView.swift
//  Tamio (macOS)
//
//  Redesigned compact, high-density server telemetry cards on macOS:
//  - Crisp header: live status dot, country flag, server title, OS + uptime
//    subtitle, and quick-action icon buttons (Terminal, Files, Monitor).
//  - Compact 3-column bar metrics: CPU, Memory (click to toggle Swap), Disk
//    with animated capsule bars and capacity captions.
//  - Rich single-line footer: live network ↑/↓ (click for cumulative totals),
//    process count, and 1·5·15m load averages.
//  - Animated connecting skeleton matching connected card geometry with zero shift.
//

import Combine
import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct HomeView: View {
    @State private var search = ""

    var body: some View {
        HomeContent(search: search)
            .pageChrome()
            .pageToolbar(
                primary: ToolbarAction("New Server", systemImage: "plus", primary: true) {
                    AppRouter.shared.presentNewServer = true
                },
                trailingMetrics: .group,
                search: ($search, "Search servers")
            ) {} trailing: {}
            .rxPlainToolbar {
                ToolbarItem(placement: .navigation) {
                    AlignedWithContent(margin: RX.Space.s4) { HomeGroupSwitcher() }
                }
            }
    }
}

private struct HomeContent: View {
    let search: String

    @EnvironmentObject var store: TamioStore
    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var filterStore = HomeGroupFilterStore.shared
    @State private var selection: RDMachine.ID?
    @State private var inspectorWidth: CGFloat = ServerInspector.width

    static func inspectorWidth(forPage width: CGFloat) -> CGFloat {
        min(ServerInspector.width, max(300, width.rounded() - 320 - RX.Space.s4 * 2))
    }

    private var filteredMachines: [RDMachine] {
        filterStore.selection.machines(in: store, search: search)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                cardsGrid
                    .padding(.horizontal, RX.Space.s4)
                    .padding(.top, RX.Space.s2)
                    .padding(.bottom, RX.Space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 320 + RX.Space.s4 * 2, maxWidth: .infinity)

            if let selection, store.machineGroup.machines.contains(where: { $0.id == selection }) {
                ServerInspector(machine: selection) { self.selection = nil }
                    .frame(width: inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.9)))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let fitted = Self.inspectorWidth(forPage: width)
            if fitted != inspectorWidth { inspectorWidth = fitted }
        }
        .onChange(of: store.machineGroup.machines.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .background {
            if selection != nil {
                Button("Close Inspector") { selection = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    @ViewBuilder
    private var cardsGrid: some View {
        let allMachines = store.machineGroup.machines
        if allMachines.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 36))
                    .foregroundStyle(.rxInkTertiary)
                Text("No Servers Yet")
                    .font(.title3.bold())
                Text("Add your first SSH server to monitor live metrics, browse SFTP files, and open Ghostty terminals.")
                    .font(.subheadline)
                    .foregroundStyle(.rxInkSecondary)
                Button("New Server") {
                    AppRouter.shared.presentNewServer = true
                }
                .buttonStyle(.rxPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)
        } else {
            let machines = filteredMachines
            if machines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.rxInkTertiary)
                    Text("No matching servers")
                        .font(.rxBodyStrong)
                        .foregroundStyle(.rxInkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 72)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if live.isEnabled, machines.count > 1 {
                        MacFleetSummaryLine(
                            machines: machines,
                            sessions: machines.compactMap { live.session(for: $0.id) }
                        )
                        .padding(.horizontal, 2)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300, maximum: 430), spacing: 12, alignment: .top)],
                        spacing: 12
                    ) {
                        ForEach(machines) { machine in
                            MacServerStatusCard(
                                machine: machine,
                                session: live.session(for: machine.id),
                                liveEnabled: live.isEnabled,
                                isSelected: selection == machine.id,
                                onSelect: { selection = (selection == machine.id) ? nil : machine.id }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Fleet Summary Pulse

private struct MacFleetSummaryLine: View {
    let machines: [RDMachine]
    let sessions: [MonitorSession]
    @StateObject private var watcher = Watcher()

    var body: some View {
        let _ = watcher.revision
        let online = sessions.filter { $0.phase == .connected && $0.status.hasData }.count
        let offline = sessions.filter {
            if case .failed = $0.phase { return true }
            return false
        }.count

        HStack(spacing: 7) {
            Circle()
                .fill(online > 0 ? Color.green : (offline > 0 ? Color.red : Color.orange))
                .frame(width: 7, height: 7)
            Text("\(online) of \(machines.count) online")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
            if offline > 0 {
                Text("·").foregroundStyle(.rxInkTertiary)
                Text("\(offline) offline")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .onAppear { watcher.bind(sessions) }
        .onChange(of: sessions.map(\.id)) { _, _ in watcher.bind(sessions) }
    }

    @MainActor
    private final class Watcher: ObservableObject {
        @Published var revision = 0
        private var boundIDs: [MonitorSession.ID] = []
        private var cancellables = Set<AnyCancellable>()

        func bind(_ sessions: [MonitorSession]) {
            let ids = sessions.map(\.id)
            guard ids != boundIDs else { return }
            boundIDs = ids
            cancellables.removeAll()
            for session in sessions {
                session.$phase
                    .dropFirst()
                    .combineLatest(session.$lastUpdate.map { $0 != nil }.removeDuplicates())
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _, _ in self?.revision &+= 1 }
                    .store(in: &cancellables)
            }
        }
    }
}

// MARK: - Redesigned Compact macOS Server Card

private struct MacServerStatusCard: View {
    let machine: RDMachine
    let session: MonitorSession?
    let liveEnabled: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var store: TamioStore
    @Environment(\.serverActions) private var actions
    @State private var isHovered = false

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header + quick tool buttons
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        MacCardStatusDot(session: session)
                        if let flag = machine.countryFlag {
                            Text(flag).font(.footnote).fixedSize()
                        }
                        Text(store.machineRedacted == .all ? "••••••" : machine.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.rxInk)
                            .lineLimit(1)
                    }
                    MacCardSubtitle(machine: machine, session: session)
                }

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    quickButton("terminal", help: "Open Terminal") {
                        actions.openTerminal(machine.id)
                    }
                    quickButton("folder", help: "Open Files") {
                        actions.openFiles(machine.id)
                    }
                    quickButton("waveform.path.ecg", help: "Open Monitor") {
                        actions.openMonitor(machine.id)
                    }
                }
                .opacity(isHovered || isSelected ? 1 : 0.72)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let session {
                MacCardLiveBody(session: session, machine: machine)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: liveEnabled ? "key" : "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                    Text(liveEnabled
                        ? "Add credentials to see live metrics"
                        : "Live status is paused in Settings")
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .rxCard()
        .overlay {
            if isSelected {
                cardShape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
            } else if isHovered {
                cardShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
            }
        }
        .contentShape(cardShape)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering }
        }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            ServerContextMenu(machine: machine.id)
        }
    }

    private func quickButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct MacCardStatusDot: View {
    let session: MonitorSession?

    var body: some View {
        if let session {
            Observed(session: session)
        } else {
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
    }

    private struct Observed: View {
        @ObservedObject var session: MonitorSession
        var body: some View {
            let color: Color = switch session.phase {
            case .connected: session.status.hasData ? .green : .orange
            case .connecting: .orange
            case .failed, .closed: .red
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

private struct MacCardSubtitle: View {
    let machine: RDMachine
    let session: MonitorSession?
    @EnvironmentObject private var store: TamioStore

    var body: some View {
        if let session {
            Observed(machine: machine, session: session)
        } else {
            addressText
        }
    }

    private var addressText: some View {
        let port = (machine.remotePort.isEmpty || machine.remotePort == "22") ? "" : ":\(machine.remotePort)"
        let raw = store.machineRedacted != .none ? "••••••" : "\(machine.remoteAddress)\(port)"
        return Text(raw)
            .font(.caption.monospaced())
            .foregroundStyle(.rxInkSecondary)
            .lineLimit(1)
    }

    private struct Observed: View {
        let machine: RDMachine
        @ObservedObject var session: MonitorSession
        @EnvironmentObject private var store: TamioStore

        var body: some View {
            if session.phase == .connected, session.status.hasData {
                let release = cleanRelease(session.status.system.releaseName)
                let uptimeSec = session.status.system.uptimeSec
                let uptime = uptimeSec > 0 ? String(localized: "up \(RXFormat.duration(uptimeSec))") : ""
                let text = [release, uptime].filter { !$0.isEmpty }.joined(separator: " · ")
                Text(text.isEmpty ? addressString : text)
                    .font(.caption)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            } else {
                Text(addressString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
        }

        private var addressString: String {
            if store.machineRedacted != .none { return "••••••" }
            let port = (machine.remotePort.isEmpty || machine.remotePort == "22") ? "" : ":\(machine.remotePort)"
            return "\(machine.remoteAddress)\(port)"
        }

        private func cleanRelease(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
            return s.replacingOccurrences(of: " GNU/Linux", with: "")
                .replacingOccurrences(of: " Linux", with: "")
                .replacingOccurrences(of: " LTS", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct MacCardLiveBody: View {
    @ObservedObject var session: MonitorSession
    let machine: RDMachine

    @State private var showsSwap = false
    @State private var showsNetTotals = false

    var body: some View {
        let isConnected = session.phase == .connected && session.status.hasData
        Group {
            if isConnected {
                connectedBody(session.status)
                    .transition(.opacity)
            } else if case let .failed(reason) = session.phase, !session.status.hasData {
                offlineBody(reason: reason)
                    .transition(.opacity)
            } else {
                MacCardConnectingSkeleton()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isConnected)
    }

    @ViewBuilder
    private func connectedBody(_ status: ServerStatus) -> some View {
        let cpu = Double(status.processor.summary.sumUsed)
        let memUsed = status.memoryUsedPercent / 100
        let memCache = status.memory.memTotal > 0 ? status.memoryCacheKB / status.memory.memTotal : 0
        let swapUsed = status.memory.swapTotal > 0 ? status.memory.swapUsed : 0
        let rootDisk = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }

        let coresCaption = status.cores == 1 ? String(localized: "1 core") : String(localized: "\(status.cores) cores")
        let memDetail = status.memory.memTotal > 0
            ? "\(ShortBytes.string(status.memoryUsedKB * 1000))/\(ShortBytes.string(status.memory.memTotal * 1000))"
            : "—"
        let swapUsedBytes = max(0, status.memory.swapTotal - status.memory.swapFree) * 1000
        let swapDetail = "\(ShortBytes.string(swapUsedBytes))/\(ShortBytes.string(status.memory.swapTotal * 1000))"
        let diskDetail = rootDisk.map { "\($0.used)/\($0.size)" } ?? "—"

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                metricColumn(
                    title: String(localized: "CPU"),
                    percentText: "\(Int(cpu.rounded()))%",
                    fraction: cpu / 100,
                    secondaryFraction: 0,
                    detail: coresCaption
                )

                metricColumn(
                    title: showsSwap && status.memory.swapTotal > 0 ? String(localized: "Swap") : String(localized: "Memory"),
                    percentText: showsSwap && status.memory.swapTotal > 0
                        ? "\(Int((swapUsed * 100).rounded()))%"
                        : "\(Int(status.memoryUsedPercent.rounded()))%",
                    fraction: showsSwap && status.memory.swapTotal > 0 ? swapUsed : memUsed,
                    secondaryFraction: showsSwap && status.memory.swapTotal > 0 ? 0 : memCache,
                    detail: showsSwap && status.memory.swapTotal > 0 ? swapDetail : memDetail
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard status.memory.swapTotal > 0 else { return }
                    withAnimation(.snappy(duration: 0.2)) { showsSwap.toggle() }
                }

                metricColumn(
                    title: String(localized: "Disk"),
                    percentText: rootDisk.map { "\(Int($0.percent))%" } ?? "—",
                    fraction: Double(rootDisk?.percent ?? 0) / 100,
                    secondaryFraction: 0,
                    detail: diskDetail,
                    empty: rootDisk == nil
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.45)
                .padding(.horizontal, 14)

            footerStrip(status)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private func metricColumn(
        title: String,
        percentText: String,
        fraction: Double,
        secondaryFraction: Double,
        detail: String,
        empty: Bool = false
    ) -> some View {
        let p = min(max(fraction, 0), 1)
        let s = min(max(secondaryFraction, 0), max(0, 1 - p))
        let tint: Color = empty ? .secondary : (p >= 0.85 ? .red : (p >= 0.65 ? .orange : .accentColor))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.rxInkSecondary)
                Spacer(minLength: 2)
                Text(percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(empty ? .rxInkTertiary : .rxInk)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if s > 0.01 {
                        Capsule()
                            .fill(tint.opacity(0.28))
                            .frame(width: max(4, geo.size.width * min(1, p + s)))
                    }
                    if !empty, p > 0.005 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(4, geo.size.width * p))
                    }
                }
                .animation(.easeOut(duration: 0.35), value: p)
            }
            .frame(height: 5)

            Text(detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.rxInkTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerStrip(_ status: ServerStatus) -> some View {
        let physicalNet = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        let netUp = Double(physicalNet.map(\.txBytesPerSec).reduce(0, +))
        let netDown = Double(physicalNet.map(\.rxBytesPerSec).reduce(0, +))
        let netUpTotal = Double(physicalNet.map(\.txBytesTotal).reduce(0, +))
        let netDownTotal = Double(physicalNet.map(\.rxBytesTotal).reduce(0, +))

        let load1 = Double(status.system.load1)
        let load5 = Double(status.system.load5)
        let load15 = Double(status.system.load15)
        let loadRatio = load1 / Double(max(1, status.cores))
        let loadColor: Color = loadRatio >= 1.0 ? .red : (loadRatio >= 0.75 ? .orange : .secondary)

        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                netPill("arrow.up", showsNetTotals ? ShortBytes.string(netUpTotal) : "\(ShortBytes.string(netUp))/s", active: (showsNetTotals ? netUpTotal : netUp) > 0)
                netPill("arrow.down", showsNetTotals ? ShortBytes.string(netDownTotal) : "\(ShortBytes.string(netDown))/s", active: (showsNetTotals ? netDownTotal : netDown) > 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { showsNetTotals.toggle() }
            }

            Spacer(minLength: 4)

            if status.system.totalProcs > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "cpu").font(.system(size: 9)).foregroundStyle(.rxInkTertiary)
                    Text("\(status.system.totalProcs)").font(.caption2.monospacedDigit()).foregroundStyle(.rxInkSecondary)
                }
            }

            Text(String(format: "%.2f · %.2f · %.2f", load1, load5, load15))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(loadColor)
                .lineLimit(1)
        }
    }

    private func netPill(_ icon: String, _ text: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? Color.green : Color.secondary.opacity(0.5))
            Text(text)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(active ? .rxInk : .rxInkSecondary)
                .contentTransition(.numericText())
        }
    }

    private func offlineBody(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

private struct MacCardConnectingSkeleton: View {
    @State private var sweep = false
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                col(String(localized: "CPU"), width: 40)
                col(String(localized: "Memory"), width: 56)
                col(String(localized: "Disk"), width: 48)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.45).padding(.horizontal, 14)

            HStack(spacing: 8) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(width: 44, height: 9).opacity(shimmer ? 0.95 : 0.4)
                Capsule().fill(Color.primary.opacity(0.09)).frame(width: 44, height: 9).opacity(shimmer ? 0.95 : 0.4)
                Spacer()
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption2).foregroundStyle(.rxInkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { sweep = true }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }

    private func col(_ title: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.rxInkSecondary)
                Spacer()
                Capsule().fill(Color.primary.opacity(0.09)).frame(width: 24, height: 10).opacity(shimmer ? 0.95 : 0.4)
            }
            GeometryReader { geo in
                let barW = max(18, geo.size.width * 0.42)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.05), .accentColor.opacity(0.5), .accentColor.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: barW)
                        .offset(x: sweep ? geo.size.width - barW : 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            Capsule().fill(Color.primary.opacity(0.09)).frame(width: width, height: 9).opacity(shimmer ? 0.95 : 0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

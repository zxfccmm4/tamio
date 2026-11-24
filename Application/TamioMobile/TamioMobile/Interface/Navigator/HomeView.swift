//
//  HomeView.swift
//  TamioMobile
//
//  Apple-native server telemetry cards on a grouped canvas:
//  - Header: live status dot, optional country flag, server title, concise
//    OS + uptime subtitle (or host when offline), and a crisp quick-terminal
//    icon button.
//  - Telemetry body: three symmetrical circular gauges (CPU, Memory/Swap,
//    Disk) with compact capacity sublabels so every Linux and macOS host
//    shares identical visual balance.
//  - Footer strip: live network ↑/↓ throughput (tap to flip to cumulative
//    totals) alongside system load averages.
//

import Combine
import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct HomeView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.serverActions) private var actions
    @ObservedObject private var live = LiveStatusCenter.shared

    @State private var search = ""
    @State private var groupFilter: String?
    @State private var selectedMachine: RDMachine.ID?
    @State private var pageWidth: CGFloat = 0
    @Namespace private var zoomNamespace

    private var sideBySide: Bool { sizeClass == .regular && pageWidth >= 800 }

    private var groups: [String] {
        Set(store.machineGroup.machines.map(\.group))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredMachines: [RDMachine] {
        store.machineGroup.machines
            .filter { machine in
                if let groupFilter, machine.group != groupFilter { return false }
                if !search.isEmpty { return machine.isQualifiedForSearch(text: search) }
                return true
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var gridColumns: [GridItem] {
        if sizeClass == .compact {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: 336, maximum: 460), spacing: 14, alignment: .top)]
    }

    var body: some View {
        HStack(spacing: 0) {
            cardsCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sideBySide, let selectedMachine, store.machineGroup.machines.contains(where: { $0.id == selectedMachine }) {
                Divider()
                NavigationStack {
                    ServerDetailView(machineID: selectedMachine, embedded: true)
                }
                .id(selectedMachine)
                .frame(width: 420)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .appleGroupedBackground()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: Text("Search servers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    actions.newServer()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Server")
            }
        }
        .navigationDestination(item: Binding(
            get: { sideBySide ? nil : selectedMachine.map(SelectedMachine.init) },
            set: { selectedMachine = $0?.id }
        )) { item in
            ServerDetailView(machineID: item.id)
                .appleZoomDestination(sourceID: item.id, in: zoomNamespace)
        }
        .onChange(of: groups) { _, next in
            if let groupFilter, !next.contains(groupFilter) { self.groupFilter = nil }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_OPEN"] == "inspector" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    selectedMachine = store.machineGroup.machines.first?.id
                }
            }
        }
        #endif
    }

    @ViewBuilder private var cardsCanvas: some View {
        let allMachines = store.machineGroup.machines
        if allMachines.isEmpty {
            ContentUnavailableView {
                Label("No Servers Yet", systemImage: "server.rack")
            } description: {
                Text("Add your first SSH server to monitor live metrics, browse SFTP files, and open Ghostty terminals.")
            } actions: {
                Button("New Server") {
                    actions.newServer()
                }
                .appleProminentButton()
            }
        } else {
            let currentGroups = groups
            let machines = filteredMachines
            if machines.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !currentGroups.isEmpty {
                            MobileGroupFilterBar(groups: currentGroups, selection: $groupFilter)
                        }

                        if live.isEnabled, machines.count > 1 {
                            FleetStatusLine(machines: machines, sessions: machines.compactMap { live.session(for: $0.id) })
                                .padding(.horizontal, 20)
                        }

                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(machines) { machine in
                                ServerStatusCard(
                                    machine: machine,
                                    session: live.session(for: machine.id),
                                    liveEnabled: live.isEnabled,
                                    isSelected: sideBySide && selectedMachine == machine.id,
                                    onOpenDetail: { selectedMachine = machine.id }
                                )
                                .appleZoomSource(id: machine.id, in: zoomNamespace, cornerRadius: 20)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private struct SelectedMachine: Identifiable, Hashable { let id: RDMachine.ID }
}

// MARK: - Subtle Fleet Summary Line

/// Compact single-line fleet pulse above multi-server grids without adding a heavy banner.
private struct FleetStatusLine: View {
    let machines: [RDMachine]
    let sessions: [MonitorSession]

    @StateObject private var watcher = Watcher()

    private var sessionIDs: [MonitorSession.ID] { sessions.map(\.id) }

    var body: some View {
        let _ = watcher.revision
        let online = sessions.filter { $0.phase == .connected && $0.status.hasData }.count
        let offline = sessions.filter {
            if case .failed = $0.phase { return true }
            return false
        }.count

        HStack(spacing: 8) {
            MobileStatusDot(state: online > 0 ? .online : (offline > 0 ? .offline : .connecting))
            Text("\(online) of \(machines.count) online")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if offline > 0 {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("\(offline) offline")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .onAppear { watcher.bind(sessions) }
        .onChange(of: sessionIDs) { _, _ in watcher.bind(sessions) }
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
                session.$lastUpdate
                    .map { $0 != nil }
                    .removeDuplicates()
                    .dropFirst()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.revision &+= 1 }
                    .store(in: &cancellables)
            }
        }
    }
}

// MARK: - Redesigned Apple-Native Server Card

private struct ServerStatusCard: View {
    let machine: RDMachine
    let session: MonitorSession?
    let liveEnabled: Bool
    let isSelected: Bool
    let onOpenDetail: () -> Void

    @EnvironmentObject private var store: TamioStore
    @Environment(\.serverActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: status dot, flag, title, subtitle + quick terminal trigger
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        CardStatusDot(session: session)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3.5 }

                        if let flag = machine.countryFlag {
                            Text(flag)
                                .font(.subheadline)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }

                        RedactableText(machine.name, redacted: store.machineRedacted == .all)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CardSubtitle(machine: machine, session: session)
                }

                Spacer(minLength: 8)

                Button {
                    actions.openTerminal(machine.id)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(
                            Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Terminal")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // Body + Footer
            if let session {
                CardLiveBody(session: session, machine: machine)
            } else {
                CardUnmonitoredBody(machine: machine, liveEnabled: liveEnabled)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: cardShape)
        .overlay {
            if isSelected {
                cardShape.strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
            } else {
                cardShape.strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    lineWidth: 0.5
                )
            }
        }
        .shadow(
            color: colorScheme == .dark ? .clear : Color.black.opacity(0.03),
            radius: 4,
            x: 0,
            y: 1
        )
        .contentShape(cardShape)
        .onTapGesture(perform: onOpenDetail)
        .contextMenu {
            ServerMenuItems(machine: machine.id)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Header Helpers

private struct CardStatusDot: View {
    let session: MonitorSession?

    var body: some View {
        if let session {
            Observed(session: session)
        } else {
            MobileStatusDot(state: .idle)
        }
    }

    private struct Observed: View {
        @ObservedObject var session: MonitorSession

        var body: some View {
            MobileStatusDot(state: dotState)
        }

        private var dotState: MobileStatusDot.State {
            switch session.phase {
            case .connected:
                return session.status.hasData ? .online : .connecting
            case .connecting:
                return .connecting
            case .failed, .closed:
                return .offline
            }
        }
    }
}

private struct CardSubtitle: View {
    let machine: RDMachine
    let session: MonitorSession?

    @EnvironmentObject private var store: TamioStore

    var body: some View {
        if let session {
            Observed(machine: machine, session: session)
        } else {
            addressLine
        }
    }

    private var addressLine: some View {
        let portSuffix = (machine.remotePort.isEmpty || machine.remotePort == "22") ? "" : ":\(machine.remotePort)"
        return RedactableText("\(machine.remoteAddress)\(portSuffix)", redacted: store.machineRedacted != .none)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private struct Observed: View {
        let machine: RDMachine
        @ObservedObject var session: MonitorSession
        @EnvironmentObject private var store: TamioStore

        var body: some View {
            if session.phase == .connected, session.status.hasData {
                let release = shortOSRelease(session.status.system.releaseName)
                let uptimeSec = session.status.system.uptimeSec
                let uptime = uptimeSec > 0 ? String(localized: "up \(RXFormat.duration(uptimeSec))") : ""

                HStack(spacing: 5) {
                    OSLogo(session: session, size: 12)
                    FirstThatFits {
                        if !release.isEmpty, !uptime.isEmpty {
                            metaText("\(release) · \(uptime)")
                        }
                        if !release.isEmpty {
                            metaText(release)
                        }
                        if !uptime.isEmpty {
                            metaText(uptime)
                        }
                        addressFallback
                    }
                }
            } else {
                addressFallback
            }
        }

        private func metaText(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }

        private var addressFallback: some View {
            let portSuffix = (machine.remotePort.isEmpty || machine.remotePort == "22") ? "" : ":\(machine.remotePort)"
            return RedactableText("\(machine.remoteAddress)\(portSuffix)", redacted: store.machineRedacted != .none)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Live Telemetry Body (3 Symmetrical Rings + Compact Footer)

private struct CardLiveBody: View {
    @ObservedObject var session: MonitorSession
    let machine: RDMachine

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.serverActions) private var actions

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
                CardConnectingSkeleton()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isConnected)
    }

    // MARK: Connected

    @ViewBuilder
    private func connectedBody(_ status: ServerStatus) -> some View {
        let cpu = Double(status.processor.summary.sumUsed)
        let memUsed = status.memoryUsedPercent / 100
        let memCache = status.memory.memTotal > 0 ? status.memoryCacheKB / status.memory.memTotal : 0
        let swapUsed = status.memory.swapTotal > 0 ? status.memory.swapUsed : 0
        let rootDisk = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }

        let coresCaption = status.cores == 1
            ? String(localized: "1 core")
            : String(localized: "\(status.cores) cores")

        let memDetail = status.memory.memTotal > 0
            ? "\(ShortBytes.string(status.memoryUsedKB * 1000)) / \(ShortBytes.string(status.memory.memTotal * 1000))"
            : "—"
        let swapUsedBytes = max(0, status.memory.swapTotal - status.memory.swapFree) * 1000
        let swapDetail = "\(ShortBytes.string(swapUsedBytes)) / \(ShortBytes.string(status.memory.swapTotal * 1000))"
        let diskDetail = rootDisk.map { "\($0.used) / \($0.size)" } ?? "—"

        VStack(spacing: 0) {
            // Three symmetrical circular gauges
            HStack(alignment: .top, spacing: 8) {
                gaugeSlot(
                    title: String(localized: "CPU"),
                    detail: coresCaption
                ) {
                    CleanRingGauge(
                        fraction: cpu / 100,
                        lineWidth: 5.5,
                        size: 58,
                        centerText: "\(Int(cpu.rounded()))%"
                    )
                }

                gaugeSlot(
                    title: showsSwap && status.memory.swapTotal > 0
                        ? String(localized: "Swap")
                        : String(localized: "Memory"),
                    detail: showsSwap && status.memory.swapTotal > 0 ? swapDetail : memDetail
                ) {
                    if showsSwap, status.memory.swapTotal > 0 {
                        CleanRingGauge(
                            fraction: swapUsed,
                            lineWidth: 5.5,
                            size: 58,
                            centerText: "\(Int((swapUsed * 100).rounded()))%"
                        )
                    } else {
                        CleanRingGauge(
                            fraction: memUsed,
                            secondaryFraction: memCache,
                            lineWidth: 5.5,
                            size: 58,
                            centerText: "\(Int(status.memoryUsedPercent.rounded()))%"
                        )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard status.memory.swapTotal > 0 else { return }
                    withAnimation(.snappy(duration: 0.22)) { showsSwap.toggle() }
                }

                gaugeSlot(
                    title: String(localized: "Disk"),
                    detail: diskDetail
                ) {
                    CleanRingGauge(
                        fraction: Double(rootDisk?.percent ?? 0) / 100,
                        lineWidth: 5.5,
                        size: 58,
                        centerText: rootDisk.map { "\(Int($0.percent))%" } ?? "—",
                        empty: rootDisk == nil
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider()
                .opacity(colorScheme == .dark ? 0.5 : 0.45)
                .padding(.horizontal, 18)

            // Compact live footer strip: Network throughput + Load average
            footerStrip(status)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
        }
    }

    private func gaugeSlot(
        title: String,
        detail: String,
        @ViewBuilder gauge: () -> some View
    ) -> some View {
        VStack(spacing: 7) {
            gauge()
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
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

        HStack(alignment: .center, spacing: 10) {
            // Network live rate / cumulative totals (tap to toggle)
            HStack(spacing: 10) {
                if showsNetTotals {
                    netPill(symbol: "arrow.up", text: ShortBytes.string(netUpTotal), active: netUpTotal > 0)
                    netPill(symbol: "arrow.down", text: ShortBytes.string(netDownTotal), active: netDownTotal > 0)
                } else {
                    netPill(symbol: "arrow.up", text: "\(ShortBytes.string(netUp))/s", active: netUp > 0)
                    netPill(symbol: "arrow.down", text: "\(ShortBytes.string(netDown))/s", active: netDown > 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { showsNetTotals.toggle() }
            }

            Spacer(minLength: 6)

            // Load average, gracefully stepping down to fit any width without ellipsis
            FirstThatFits {
                loadText(
                    prefix: String(localized: "Load"),
                    values: String(format: "%.2f · %.2f · %.2f", load1, load5, load15),
                    color: loadColor
                )
                loadText(
                    prefix: String(localized: "Load"),
                    values: String(format: "%.2f", load1),
                    color: loadColor
                )
                Text(String(format: "%.2f", load1))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(loadColor)
                    .fixedSize()
            }
        }
    }

    private func netPill(symbol: String, text: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? Color.green : Color(uiColor: .tertiaryLabel))
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .contentTransition(.numericText())
                .fixedSize()
        }
    }

    private func loadText(prefix: String, values: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(values)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    // MARK: Offline

    private func offlineBody(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.red.opacity(colorScheme == .dark ? 0.14 : 0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            HStack {
                Text("Offline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                Spacer()
                Button("Edit Server") {
                    actions.edit(machine.id)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }
}

// MARK: - Animated Connecting Skeleton (Matches Connected Card Geometry)

private struct CardConnectingSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation: Double = 0
    @State private var shimmerPhase = false

    private var trackColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }

    private var pillBaseColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.08)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Three symmetrical animated ring placeholders matching connectedBody
            HStack(alignment: .top, spacing: 8) {
                skeletonSlot(title: String(localized: "CPU"), detailWidth: 44, angleOffset: 0)
                skeletonSlot(title: String(localized: "Memory"), detailWidth: 64, angleOffset: 120)
                skeletonSlot(title: String(localized: "Disk"), detailWidth: 56, angleOffset: 240)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider()
                .opacity(colorScheme == .dark ? 0.5 : 0.45)
                .padding(.horizontal, 18)

            // Footer strip matching connectedBody height & alignment
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 10) {
                    networkSkeletonPill(symbol: "arrow.up", width: 42)
                    networkSkeletonPill(symbol: "arrow.down", width: 42)
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Connecting…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                shimmerPhase = true
            }
        }
    }

    private func skeletonSlot(title: String, detailWidth: CGFloat, angleOffset: Double) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(trackColor, lineWidth: 5.5)

                Circle()
                    .trim(from: 0.0, to: 0.30)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.accentColor.opacity(0.0),
                                Color.accentColor.opacity(0.55),
                            ]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(108)
                        ),
                        style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation + angleOffset - 90))

                Capsule()
                    .fill(pillBaseColor)
                    .frame(width: 24, height: 11)
                    .opacity(shimmerPhase ? 0.95 : 0.42)
            }
            .frame(width: 58, height: 58)

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Capsule()
                    .fill(pillBaseColor)
                    .frame(width: detailWidth, height: 10)
                    .padding(.vertical, 2)
                    .opacity(shimmerPhase ? 0.95 : 0.42)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func networkSkeletonPill(symbol: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            Capsule()
                .fill(pillBaseColor)
                .frame(width: width, height: 10)
                .opacity(shimmerPhase ? 0.95 : 0.42)
        }
    }
}

// MARK: - Unmonitored State (No Credentials / Live Status Off)

private struct CardUnmonitoredBody: View {
    let machine: RDMachine
    let liveEnabled: Bool

    @Environment(\.serverActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: liveEnabled ? "key" : "waveform.path.ecg")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(liveEnabled
                ? "Add credentials to see live metrics"
                : "Live status is paused in Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            if liveEnabled {
                Button("Edit") {
                    actions.edit(machine.id)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    in: Capsule()
                )
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.7 : 0.8),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
}

// MARK: - Release Name Trimming

/// Condenses verbose `/etc/os-release` names ("Debian GNU/Linux 12 (bookworm)")
/// into clean card-friendly labels ("Debian 12") so subtitles stay crisp without truncation.
private func shortOSRelease(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }
    if let paren = text.range(of: " (") {
        text = String(text[..<paren.lowerBound])
    }
    text = text
        .replacingOccurrences(of: " GNU/Linux", with: "")
        .replacingOccurrences(of: " Linux", with: "")
        .replacingOccurrences(of: " LTS", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text
}

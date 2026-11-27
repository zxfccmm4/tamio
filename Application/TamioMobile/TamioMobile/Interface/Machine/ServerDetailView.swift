//
//  ServerDetailView.swift
//  TamioMobile
//
//  Lightweight native iOS server inspector inspired by ServerCat + iOS 26
//  Liquid Glass toolbar icons:
//  - Top-right glass icon switcher: Overview | Processes | Containers
//  - Overview: OS line, CPU breakdown + 2-row dot-matrix history + Load rings,
//    Memory bar + dual ring, Network + TCP + physical/virtual interfaces,
//    per-mount Disk cards with vertical fill pill & I/O table.
//  - Processes: ultra-clean sortable Process | CPU% | Mem table.
//  - Containers: crisp Docker rows with CPU ring, MEM, R/W, ↑/↓ & actions.
//

import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct ServerDetailView: View {
    let machineID: RDMachine.ID
    var embedded = false

    enum SectionTab: CaseIterable, Hashable {
        case overview
        case charts
        case processes
        case containers

        var systemImage: String {
            switch self {
            case .overview: "gauge.medium"
            case .charts: "chart.xyaxis.line"
            case .processes: "waveform.path.ecg"
            case .containers: "shippingbox"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .charts: String(localized: "Charts")
            case .processes: String(localized: "Processes")
            case .containers: String(localized: "Containers")
            }
        }
    }

    @EnvironmentObject private var store: TamioStore
    @Environment(\.serverActions) private var actions
    @ObservedObject private var live = LiveStatusCenter.shared

    @State private var tab: SectionTab = .overview

    private var machine: RDMachine { store.machineGroup[machineID] }

    var body: some View {
        Group {
            if let session = live.session(for: machineID) {
                Group {
                    switch tab {
                    case .overview:
                        DetailOverviewTab(session: session, machineID: machineID)
                            .id(session.id)
                    case .charts:
                        DetailChartsTab(session: session, machineID: machineID)
                            .id(session.id)
                    case .processes:
                        DetailProcessesTab(session: session, machineID: machineID)
                    case .containers:
                        DetailContainersTab(session: session, machineID: machineID)
                    }
                }
                .onAppear { session.holdDetail() }
                .onDisappear { session.releaseDetail() }
            } else {
                ContentUnavailableView {
                    Label("No Live Status", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Enable Live Server Status in Settings and assign credentials to inspect real-time metrics.")
                } actions: {
                    Button("Open Terminal") {
                        actions.openTerminal(machineID)
                    }
                    .appleProminentButton()
                }
                .appleGroupedBackground()
            }
        }
        .appleGroupedBackground()
        .navigationTitle(store.machineRedacted == .all ? String(localized: "Server") : machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ServerMenuItems(machine: machineID)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .accessibilityLabel("Server Actions")

                // Compact 3-icon switcher matching iOS 26 Liquid Glass toolbar aesthetic
                HStack(spacing: 2) {
                    ForEach(SectionTab.allCases, id: \.self) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { tab = item }
                        } label: {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 14, weight: tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                                .frame(width: 30, height: 28)
                                .background(
                                    tab == item ? Color.primary.opacity(0.1) : Color.clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.accessibilityTitle)
                    }
                }
            }
        }
    }
}

// MARK: - Overview Tab

private struct DetailOverviewTab: View {
    @ObservedObject var session: MonitorSession
    let machineID: RDMachine.ID
    @EnvironmentObject private var store: TamioStore

    private var machine: RDMachine { store.machineGroup[machineID] }

    var body: some View {
        let status = session.status
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !status.system.releaseName.isEmpty {
                    Text(status.system.releaseName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .textSelection(.enabled)
                }

                notesAndRenewalBlock

                if status.hasData {
                    cpuBlock(status)
                    memoryBlock(status)
                    networkBlock(status)
                    ForEach(status.fileSystem.elements, id: \.mountPoint) { disk in
                        diskBlock(disk, io: ioDevice(for: disk, in: status))
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading metrics…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 48)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .appleGroupedBackground()
    }

    @ViewBuilder
    private var notesAndRenewalBlock: some View {
        let showNotes = store.showServerNotes && !machine.trimmedComment.isEmpty
        let showRenewal = store.showRenewalReminder && machine.renewalEnabled && machine.renewalDate != nil
        if showNotes || showRenewal {
            card {
                if showRenewal, let date = machine.renewalDate, let badge = machine.renewalBadgeText(), let urgency = machine.renewalUrgency() {
                    let tint: Color = switch urgency {
                    case .expired: .red
                    case .urgent: .orange
                    case .soon: .yellow
                    case .normal: .secondary
                    }
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(urgency == .soon ? .orange : tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(badge)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(urgency == .soon ? .orange : tint)
                                if !machine.formattedRenewalPrice.isEmpty {
                                    Text("· \(machine.formattedRenewalPrice)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(date.formatted(date: .abbreviated, time: .omitted)) · \(machine.renewalCycle.localizedTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if machine.renewalCycle != .custom {
                            Button("Renewed") {
                                var updated = machine
                                updated.advanceRenewalCycle()
                                store.machineGroup.insert(updated)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                if showNotes && showRenewal {
                    Divider()
                }

                if showNotes {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Notes", systemImage: "note.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(machine.trimmedComment)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statCell(_ title: LocalizedStringKey, value: String, unit: String = "", dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let dot {
                    Capsule().fill(dot).frame(width: 3.5, height: 10)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cpuBlock(_ status: ServerStatus) -> some View {
        let s = status.processor.summary
        let idle = max(0, 100 - Double(s.sumUsed))
        return card {
            HStack(alignment: .top, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(Double(s.sumUsed).rounded()))")
                        .font(.system(size: 32, weight: .regular).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 64, alignment: .leading)

                statCell("Sys", value: "\(Int(Double(s.sumSystem).rounded()))", unit: "%", dot: .red)
                statCell("User", value: "\(Int(Double(s.sumUser).rounded()))", unit: "%", dot: .green)
                statCell("Nice", value: "\(Int(Double(s.sumNice).rounded()))", unit: "%", dot: .purple)
                statCell("I/O Wait", value: "\(Int(Double(s.sumIOWait).rounded()))", unit: "%", dot: .yellow)
            }

            DotMatrixHistoryBar(values: session.history.cpu)

            HStack(alignment: .center, spacing: 8) {
                statCell("Cores", value: "\(status.cores)")
                statCell("Idle", value: "\(Int(idle.rounded()))", unit: "%")
                statCell("Uptime", value: RXFormat.duration(status.system.uptimeSec))
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Load")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("1,5,15m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    CleanLoadRings(
                        load1: Double(status.system.load1),
                        load5: Double(status.system.load5),
                        load15: Double(status.system.load15),
                        cores: status.cores
                    )
                }
            }
        }
    }

    private func memoryBlock(_ status: ServerStatus) -> some View {
        let mem = status.memory
        let free = RXFormat.bytes(mem.memFree * 1000)
        let used = RXFormat.bytes(status.memoryUsedKB * 1000)
        let cache = RXFormat.bytes(status.memoryCacheKB * 1000)
        let cacheFrac = mem.memTotal > 0 ? status.memoryCacheKB / mem.memTotal : 0
        return card {
            HStack(alignment: .center, spacing: 8) {
                statCell("Free", value: free.value, unit: free.unit)
                statCell("Used", value: used.value, unit: used.unit, dot: .green)
                statCell("Cache", value: cache.value, unit: cache.unit, dot: .secondary.opacity(0.6))
                CleanRingGauge(
                    fraction: status.memoryUsedPercent / 100,
                    secondaryFraction: cacheFrac,
                    lineWidth: 5,
                    size: 42,
                    centerText: "\(Int(status.memoryUsedPercent.rounded()))%"
                )
            }
        }
    }

    private func networkBlock(_ status: ServerStatus) -> some View {
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        let virtual = status.network.elements.filter { NetworkFilter.isVirtual($0.device) }
        return card {
            trafficRow(physical)

            if status.tcp.outSegments > 0 {
                Divider()
                HStack(spacing: 8) {
                    statCell("Retrans", value: String(format: "%.0f", status.tcp.retransmitPercent), unit: "%")
                    statCell("Active", value: compactCount(status.tcp.activeOpens))
                    statCell("Passive", value: compactCount(status.tcp.passiveOpens))
                    statCell("Fails", value: compactCount(status.tcp.attemptFails))
                }
            }

            ForEach(physical) { iface in
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: iface.device.hasPrefix("w") ? "wifi" : "network")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(iface.device)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let ip = status.addresses[iface.device] {
                            Text(ip)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    trafficRow([iface])
                }
            }

            if !virtual.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(spacing: 6) {
                        ForEach(virtual) { iface in
                            HStack {
                                Text(iface.device)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("↑ \(RXFormat.rateString(Double(iface.txBytesPerSec)))  ↓ \(RXFormat.rateString(Double(iface.rxBytesPerSec)))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text("Virtual Interfaces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(virtual.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.secondary)
            }
        }
    }

    private func trafficRow(_ elements: [ServerStatus.NetworkInfo.NetworkInfoElement]) -> some View {
        let up = Double(elements.map(\.txBytesPerSec).reduce(0, +))
        let down = Double(elements.map(\.rxBytesPerSec).reduce(0, +))
        let upTotal = Double(elements.map(\.txBytesTotal).reduce(0, +))
        let downTotal = Double(elements.map(\.rxBytesTotal).reduce(0, +))
        let upRate = RXFormat.rate(up)
        let downRate = RXFormat.rate(down)
        let upBytes = RXFormat.bytes(upTotal)
        let downBytes = RXFormat.bytes(downTotal)

        return HStack(alignment: .center, spacing: 8) {
            statCell("↑/s", value: upRate.value, unit: upRate.unit)
            statCell("↓/s", value: downRate.value, unit: downRate.unit)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text("↑").font(.caption2).foregroundStyle(.secondary)
                    Text(upBytes.value).font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(upBytes.unit).font(.caption2).foregroundStyle(.secondary)
                    Capsule().fill(Color.orange).frame(width: 3.5, height: 10)
                }
                HStack(spacing: 4) {
                    Text("↓").font(.caption2).foregroundStyle(.secondary)
                    Text(downBytes.value).font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(downBytes.unit).font(.caption2).foregroundStyle(.secondary)
                    Capsule().fill(Color.green).frame(width: 3.5, height: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            NetworkShareRing(up: upTotal, down: downTotal)
        }
    }

    private func diskBlock(_ disk: ServerStatus.FileSystemInfo.FileSystemInfoElement, io: ServerStatus.DiskIOInfo.Device?) -> some View {
        card {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.mountPoint)
                        .font(.headline.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(disk.free + " " + String(localized: "free"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(disk.percent))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(disk.used)/\(disk.size)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                VerticalFillPill(fraction: Double(disk.percent) / 100)
            }

            if let io {
                Divider()
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Circle().fill(Color.green.opacity(0.6)).frame(width: 7, height: 7).gridColumnAlignment(.leading)
                        Text("Speed").font(.caption2).foregroundStyle(.secondary)
                        Text("Bytes").font(.caption2).foregroundStyle(.secondary)
                        Text("IOPS").font(.caption2).foregroundStyle(.secondary)
                        Text("Wait").font(.caption2).foregroundStyle(.secondary)
                    }
                    ioRow(String(localized: "Read"), rate: io.readBytesPerSec, total: io.readBytesTotal, ops: io.readOpsPerSec, wait: io.readWaitMs)
                    ioRow(String(localized: "Write"), rate: io.writeBytesPerSec, total: io.writeBytesTotal, ops: io.writeOpsPerSec, wait: io.writeWaitMs)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func ioRow(_ label: String, rate: Int, total: Int, ops: Int, wait: Double) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(RXFormat.rateString(Double(rate)))
                .font(.caption.weight(rate > 0 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(rate > 0 ? .primary : .secondary)
            Text(RXFormat.bytesString(Double(total)))
                .font(.caption.weight(.semibold).monospacedDigit())
            Text("\(ops)")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(String(format: "%.0f", wait))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func ioDevice(for disk: ServerStatus.FileSystemInfo.FileSystemInfoElement, in status: ServerStatus) -> ServerStatus.DiskIOInfo.Device? {
        let devices = status.diskIO.devices
        if devices.count == 1, disk.mountPoint == "/" { return devices.first }
        return nil
    }

    private func compactCount(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }
}

/// Clean 2-row dot-matrix bar matching ServerCat's CPU activity strip.
private struct DotMatrixHistoryBar: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let count = max(12, Int(proxy.size.width / 8))
            let shown = Array(values.suffix(count))
            HStack(spacing: 4) {
                ForEach(0 ..< count, id: \.self) { index in
                    let offset = index - (count - shown.count)
                    let value = offset >= 0 ? shown[offset] : 0
                    let active = offset >= 0 && value > 1
                    let high = offset >= 0 && value >= 50
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(high ? Color.red : (active && value >= 25 ? Color.green : Color.primary.opacity(0.08)))
                            .frame(width: 4, height: 8)
                        Capsule()
                            .fill(active ? (value >= 80 ? Color.red : Color.green) : Color.primary.opacity(0.08))
                            .frame(width: 4, height: 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 20)
    }
}

private struct NetworkShareRing: View {
    let up: Double
    let down: Double

    var body: some View {
        let total = up + down
        let upShare = total > 0 ? up / total : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: 5)
            if total > 0 {
                Circle().trim(from: 0, to: upShare)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Circle().trim(from: upShare, to: 1)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 36, height: 36)
    }
}

private struct VerticalFillPill: View {
    let fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(clamped >= 0.85 ? Color.red : Color.green)
                .frame(height: max(4, 38 * clamped))
        }
        .frame(width: 18, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Processes Tab (Clean Table)

@MainActor
private final class MobileProcessStore: ObservableObject {
    private static var cache: [RDMachine.ID: MobileProcessStore] = [:]
    static func of(_ id: RDMachine.ID) -> MobileProcessStore {
        if let existing = cache[id] { return existing }
        let created = MobileProcessStore()
        cache[id] = created
        return created
    }

    struct Row: Identifiable, Equatable {
        let pid: Int
        let cpu: Double
        let rssKB: Double
        let command: String
        var id: Int { pid }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loaded = false
    private var busy = false

    func refresh(_ session: MonitorSession) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let cmd = """
        if [ "$(uname -s)" = Darwin ]; then ps -Ao pid=,%cpu=,rss=,command= -r | head -100; \
        else ps -eo pid=,pcpu=,rss=,args= --sort=-pcpu | head -100; fi
        """
        guard let output = await session.run(cmd) else { return }
        let parsed = output.split(separator: "\n").compactMap { line -> Row? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]) else { return nil }
            return Row(pid: pid, cpu: Double(fields[1]) ?? 0, rssKB: Double(fields[2]) ?? 0, command: String(fields[3]))
        }
        if parsed != rows { rows = parsed }
        loaded = true
    }
}

private struct DetailProcessesTab: View {
    @ObservedObject var session: MonitorSession
    @ObservedObject private var model: MobileProcessStore
    @Environment(\.serverActions) private var actions

    enum SortKey { case name, cpu, mem }
    @State private var sort: SortKey = .cpu

    init(session: MonitorSession, machineID: RDMachine.ID) {
        self.session = session
        model = MobileProcessStore.of(machineID)
    }

    private var sorted: [MobileProcessStore.Row] {
        switch sort {
        case .cpu: model.rows.sorted { $0.cpu > $1.cpu }
        case .mem: model.rows.sorted { $0.rssKB > $1.rssKB }
        case .name: model.rows.sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Table header
                HStack(spacing: 8) {
                    sortButton("Process", key: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sortButton("CPU%", key: .cpu)
                        .frame(width: 64, alignment: .trailing)
                    sortButton("Mem", key: .mem)
                        .frame(width: 66, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 16)

                if !model.loaded {
                    ProgressView()
                        .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sorted) { row in
                            HStack(spacing: 8) {
                                Text(row.command)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Int(row.cpu.rounded()))%")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(row.cpu >= 50 ? .orange : .primary)
                                    .frame(width: 64, alignment: .trailing)
                                Text(compactBytes(row.rssKB * 1024))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .frame(width: 66, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Copy PID") { actions.copy("\(row.pid)") }
                                Button("Copy Command") { actions.copy(row.command) }
                                Divider()
                                Button("Kill…", role: .destructive) { sendSignal("TERM", to: row) }
                                Button("Kill -9…", role: .destructive) { sendSignal("KILL", to: row) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(14)
        }
        .appleGroupedBackground()
        .task(id: session.id) {
            while !Task.isCancelled {
                await model.refresh(session)
                try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC)
            }
        }
    }

    private func sortButton(_ title: LocalizedStringKey, key: SortKey) -> some View {
        Button {
            sort = key
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == key {
                    Text(key == .name ? "↑" : "↓")
                }
            }
            .font(.caption.weight(sort == key ? .semibold : .regular))
            .foregroundStyle(sort == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func compactBytes(_ bytes: Double) -> String {
        let pair = RXFormat.bytes(bytes)
        return "\(pair.value)\(pair.unit.replacingOccurrences(of: "B", with: ""))"
    }

    private func sendSignal(_ signal: String, to row: MobileProcessStore.Row) {
        actions.confirm(
            String(localized: "Send SIG\(signal) to \(row.pid)?"),
            row.command,
            signal == "KILL" ? String(localized: "Kill -9") : String(localized: "Kill"),
            true
        ) { confirmed in
            guard confirmed else { return }
            Task {
                _ = await session.run("kill -\(signal) \(row.pid) 2>&1")
                await model.refresh(session)
            }
        }
    }
}

// MARK: - Containers Tab (Clean List)

@MainActor
private final class MobileContainerStore: ObservableObject {
    private static var cache: [RDMachine.ID: MobileContainerStore] = [:]
    static func of(_ id: RDMachine.ID) -> MobileContainerStore {
        if let existing = cache[id] { return existing }
        let created = MobileContainerStore(machineID: id)
        cache[id] = created
        return created
    }

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let status: String
        var cpu = ""
        var memory = ""
        var blockIO = ""
        var netIO = ""
        var running: Bool { state == "running" }
        var unhealthy: Bool { status.contains("unhealthy") }
    }

    let machineID: RDMachine.ID
    @Published private(set) var containers: [Container] = []
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    private var busy = false

    init(machineID: RDMachine.ID) {
        self.machineID = machineID
    }

    func refresh(_ session: MonitorSession) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let listing = """
        if ! command -v docker >/dev/null 2>&1; then echo 'TAMIO:NODOCKER'; \
        else docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}' 2>&1; fi
        """
        guard let output = await session.run(listing, timeout: 20) else { return }
        if output.contains("TAMIO:NODOCKER") {
            problem = String(localized: "Docker isn't installed on this server.")
            loaded = true
            return
        }
        if output.contains("permission denied") || output.contains("Got permission denied") {
            problem = String(localized: "Permission denied accessing the Docker socket.")
            loaded = true
            return
        }

        let prev = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var list = output.split(separator: "\n").compactMap { line -> Container? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            var c = Container(id: fields[0], name: fields[1], state: fields[2], status: fields[3])
            if let old = prev[c.id], c.running {
                c.cpu = old.cpu; c.memory = old.memory; c.blockIO = old.blockIO; c.netIO = old.netIO
            }
            return c
        }
        publish(list)
        guard list.contains(where: \.running) else { return }

        let stats = "docker stats --no-stream --format '{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}\t{{.NetIO}}' 2>/dev/null"
        guard let figures = await session.run(stats, timeout: 30) else { return }
        for line in figures.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5,
                  let idx = list.firstIndex(where: { fields[0].hasPrefix($0.id) || $0.id.hasPrefix(fields[0]) })
            else { continue }
            list[idx].cpu = fields[1]
            list[idx].memory = fields[2]
            list[idx].blockIO = fields[3]
            list[idx].netIO = fields[4]
        }
        publish(list)
    }

    private func publish(_ list: [Container]) {
        problem = list.isEmpty ? String(localized: "No containers on this server.") : nil
        let sorted = list.sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running }
            let l = Double(lhs.cpu.replacingOccurrences(of: "%", with: "")) ?? 0
            let r = Double(rhs.cpu.replacingOccurrences(of: "%", with: "")) ?? 0
            if l != r { return l > r }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if sorted != containers { containers = sorted }
        loaded = true
    }
}

private struct DetailContainersTab: View {
    @ObservedObject var session: MonitorSession
    @ObservedObject private var model: MobileContainerStore
    @Environment(\.serverActions) private var actions
    let machineID: RDMachine.ID

    init(session: MonitorSession, machineID: RDMachine.ID) {
        self.session = session
        self.machineID = machineID
        model = MobileContainerStore.of(machineID)
    }

    var body: some View {
        Group {
            if !model.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appleGroupedBackground()
            } else if let problem = model.problem {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text(problem)
                }
                .appleGroupedBackground()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.containers.enumerated()), id: \.element.id) { index, container in
                            containerRow(container)
                            if index < model.containers.count - 1 {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(14)
                }
                .appleGroupedBackground()
            }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await model.refresh(session)
                try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
            }
        }
    }

    private func containerRow(_ container: MobileContainerStore.Container) -> some View {
        let cpuVal = Double(container.cpu.replacingOccurrences(of: "%", with: "")) ?? 0
        let memUsed = container.memory.components(separatedBy: " / ").first ?? "—"
        let blockParts = container.blockIO.components(separatedBy: " / ")
        let netParts = container.netIO.components(separatedBy: " / ")

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(container.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(container.running && !container.unhealthy ? Color.secondary : Color.red)
                    .lineLimit(1)
                Menu {
                    if container.running {
                        Button("Restart") { runDocker("restart", container) }
                        Button("Stop") { runDocker("stop", container) }
                    } else {
                        Button("Start") { runDocker("start", container) }
                    }
                    Divider()
                    Button("Logs") { actions.openTerminalRunning(machineID, "docker logs -f --tail 200 \(container.name)") }
                    Button("Shell") { actions.openTerminalRunning(machineID, "docker exec -it \(container.name) sh -c 'command -v bash >/dev/null && exec bash || exec sh'") }
                        .disabled(!container.running)
                    Button("Copy ID") { actions.copy(container.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                CleanRingGauge(
                    fraction: cpuVal / 100,
                    lineWidth: 4.5,
                    size: 44,
                    centerText: "\(Int(cpuVal.rounded()))%",
                    empty: !container.running
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("MEM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(memUsed.isEmpty ? "—" : memUsed)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    ioMini("R", blockParts.first ?? "—")
                    ioMini("W", blockParts.count > 1 ? blockParts[1] : "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    ioMini("↑", netParts.count > 1 ? netParts[1] : "—")
                    ioMini("↓", netParts.first ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func ioMini(_ tag: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }

    private func runDocker(_ verb: String, _ container: MobileContainerStore.Container) {
        Task {
            _ = await session.run("docker \(verb) \(container.name) 2>&1", timeout: 60)
            await model.refresh(session)
        }
    }
}

//
//  MacChartsDashboard.swift
//  Tamio (macOS)
//
//  Animated 6-chart real-time telemetry dashboard inside MonitorPage:
//  CPU, Memory / Swap, Disk, Processes, Upload / Download, and TCP / UDP.
//

import Charts
import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

@MainActor
final class MacTelemetryChartsStore: ObservableObject {
    private static var cache: [RDMachine.ID: MacTelemetryChartsStore] = [:]

    static func of(_ id: RDMachine.ID) -> MacTelemetryChartsStore {
        if let existing = cache[id] { return existing }
        let created = MacTelemetryChartsStore()
        cache[id] = created
        return created
    }

    struct Sample: Identifiable, Equatable {
        let id: Int
        let timestamp: Date
        let cpu: Double
        let memory: Double
        let swap: Double
        let disk: Double
        let processes: Double
        let upload: Double
        let download: Double
    }

    struct SocketSample: Identifiable, Equatable {
        let id: Int
        let timestamp: Date
        let tcp: Double
        let udp: Double
    }

    static let capacity = 60

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var socketSamples: [SocketSample] = []
    @Published private(set) var socketProbed = false
    @Published var isPaused = false

    private var nextSampleID = 1
    private var nextSocketID = 1
    private var lastSyncedDate: Date?
    private var pollingSockets = false

    func sync(from session: MonitorSession) {
        guard !isPaused else { return }
        let history = session.history

        if samples.isEmpty, !history.cpu.isEmpty {
            let count = history.cpu.count
            let fallbackInterval = Double(max(1, session.refreshInterval))
            let anchor = session.lastUpdate ?? Date()
            var seeded: [Sample] = []
            seeded.reserveCapacity(count)

            for index in 0 ..< count {
                let ts: Date = if index < history.timestamps.count {
                    history.timestamps[index]
                } else {
                    anchor.addingTimeInterval(Double(index - (count - 1)) * fallbackInterval)
                }
                seeded.append(Sample(
                    id: allocateSampleID(),
                    timestamp: ts,
                    cpu: history.cpu[index],
                    memory: index < history.memory.count ? history.memory[index] : 0,
                    swap: index < history.swap.count ? history.swap[index] : session.status.swapUsedPercent,
                    disk: index < history.disk.count ? history.disk[index] : session.status.primaryDiskUsedPercent,
                    processes: index < history.processes.count ? history.processes[index] : Double(session.status.system.totalProcs),
                    upload: index < history.transmit.count ? history.transmit[index] : 0,
                    download: index < history.receive.count ? history.receive[index] : 0
                ))
            }
            samples = Array(seeded.suffix(Self.capacity))
            lastSyncedDate = session.lastUpdate ?? seeded.last?.timestamp
            return
        }

        guard let updatedAt = session.lastUpdate else { return }
        if let lastSyncedDate, updatedAt <= lastSyncedDate { return }
        lastSyncedDate = updatedAt

        let status = session.status
        guard status.hasData else { return }
        samples.append(Sample(
            id: allocateSampleID(),
            timestamp: updatedAt,
            cpu: Double(status.processor.summary.sumUsed),
            memory: status.memoryUsedPercent,
            swap: status.swapUsedPercent,
            disk: status.primaryDiskUsedPercent,
            processes: Double(status.system.totalProcs),
            upload: Double(status.physicalTransmitPerSecond),
            download: Double(status.physicalReceivePerSecond)
        ))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    func pollSockets(_ session: MonitorSession) async {
        guard !isPaused, !pollingSockets, session.phase == .connected else { return }
        pollingSockets = true
        defer { pollingSockets = false }

        let command = """
        if [ "$(uname -s)" = Darwin ]; then \
        printf 'tcp %s\\nudp %s\\n' "$(netstat -an -p tcp 2>/dev/null | grep -c '^tcp')" "$(netstat -an -p udp 2>/dev/null | grep -c '^udp')"; \
        else \
        awk '/^TCP:/ {t+=$3} /^TCP6:/ {t+=$3} /^UDP:/ {u+=$3} /^UDP6:/ {u+=$3} END {printf "tcp %d\\nudp %d\\n", t+0, u+0}' /proc/net/sockstat /proc/net/sockstat6 2>/dev/null; \
        fi
        """
        guard let output = await session.run(command, timeout: 10) else { return }

        var tcp: Double?
        var udp: Double?
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let value = Double(parts[1]) else { continue }
            if parts[0] == "tcp" { tcp = value }
            if parts[0] == "udp" { udp = value }
        }
        guard let tcp, let udp else { return }

        socketProbed = true
        guard !isPaused else { return }
        socketSamples.append(SocketSample(id: allocateSocketID(), timestamp: Date(), tcp: tcp, udp: udp))
        if socketSamples.count > Self.capacity {
            socketSamples.removeFirst(socketSamples.count - Self.capacity)
        }
    }

    private func allocateSampleID() -> Int { defer { nextSampleID += 1 }; return nextSampleID }
    private func allocateSocketID() -> Int { defer { nextSocketID += 1 }; return nextSocketID }
}

struct MacChartsDashboard: View {
    @ObservedObject var session: MonitorSession
    @ObservedObject private var model: MacTelemetryChartsStore
    @Environment(\.rxOpenWidth) private var openWidth
    @State private var appeared = false

    init(session: MonitorSession) {
        self.session = session
        model = MacTelemetryChartsStore.of(session.machine.id)
    }

    private var columns: [GridItem] {
        let count = openWidth >= 1060 ? 3 : (openWidth >= 660 ? 2 : 1)
        return Array(repeating: GridItem(.flexible(), spacing: RX.Space.s4, alignment: .top), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s4) {
            // Live status strip
            HStack(spacing: 10) {
                Circle()
                    .fill(!model.isPaused && session.phase == .connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.isPaused ? String(localized: "Paused") : String(localized: "Live"))
                    .font(.rxBodyStrong)
                if !model.samples.isEmpty {
                    Text("·")
                        .foregroundStyle(.rxInkTertiary)
                    Text(String(localized: "\(model.samples.count) samples"))
                        .font(.rxHelp.monospacedDigit())
                        .foregroundStyle(.rxInkSecondary)
                }
                Text("·")
                    .foregroundStyle(.rxInkTertiary)
                Text("\(session.refreshInterval)s")
                    .font(.rxHelp.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.isPaused.toggle() }
                } label: {
                    Label(
                        model.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                        systemImage: model.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.rx)
            }

            LazyVGrid(columns: columns, spacing: RX.Space.s4) {
                MacAnimatedChartCard(
                    title: String(localized: "CPU"),
                    unitLabel: "%",
                    series: [
                        .init(id: "cpu", label: String(localized: "CPU"), color: .orange,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.cpu) },
                              showsAreaFill: true),
                    ],
                    yMode: .percentage,
                    valueFormatter: { String(format: "%.1f%%", $0) },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 0,
                    appeared: appeared
                )

                MacAnimatedChartCard(
                    title: String(localized: "Memory / Swap"),
                    unitLabel: "%",
                    series: [
                        .init(id: "memory", label: String(localized: "Memory"), color: .blue,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.memory) },
                              showsAreaFill: true),
                        .init(id: "swap", label: String(localized: "Swap"), color: .indigo,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.swap) },
                              showsAreaFill: false),
                    ],
                    yMode: .percentage,
                    valueFormatter: { String(format: "%.1f%%", $0) },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 1,
                    appeared: appeared
                )

                MacAnimatedChartCard(
                    title: String(localized: "Disk"),
                    unitLabel: "%",
                    series: [
                        .init(id: "disk", label: String(localized: "Disk"), color: .pink,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.disk) },
                              showsAreaFill: true),
                    ],
                    yMode: .percentage,
                    valueFormatter: { String(format: "%.0f%%", $0) },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 2,
                    appeared: appeared
                )

                MacAnimatedChartCard(
                    title: String(localized: "Processes"),
                    unitLabel: String(localized: "Count"),
                    series: [
                        .init(id: "processes", label: String(localized: "Processes"), color: .teal,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.processes) },
                              showsAreaFill: true),
                    ],
                    yMode: .count(floor: 20),
                    valueFormatter: { "\(Int($0.rounded()))" },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 3,
                    appeared: appeared
                )

                MacAnimatedChartCard(
                    title: String(localized: "Upload / Download"),
                    unitLabel: "B/s",
                    series: [
                        .init(id: "upload", label: String(localized: "Upload"), color: .purple,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.upload) },
                              showsAreaFill: true),
                        .init(id: "download", label: String(localized: "Download"), color: .green,
                              points: model.samples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.download) },
                              showsAreaFill: true),
                    ],
                    yMode: .byteRate,
                    valueFormatter: { "\(ShortBytes.string($0))/s" },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 4,
                    appeared: appeared
                )

                MacAnimatedChartCard(
                    title: String(localized: "TCP / UDP"),
                    unitLabel: String(localized: "Count"),
                    series: [
                        .init(id: "tcp", label: "TCP", color: .cyan,
                              points: model.socketSamples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.tcp) },
                              showsAreaFill: true),
                        .init(id: "udp", label: "UDP", color: .brown,
                              points: model.socketSamples.map { .init(id: $0.id, timestamp: $0.timestamp, value: $0.udp) },
                              showsAreaFill: false),
                    ],
                    yMode: .count(floor: 20),
                    valueFormatter: { "\(Int($0.rounded()))" },
                    isLive: !model.isPaused && session.phase == .connected,
                    cardIndex: 5,
                    appeared: appeared,
                    emptyHint: model.socketProbed ? nil : String(localized: "Sampling sockets…")
                )
            }
        }
        .onAppear {
            model.sync(from: session)
            if !appeared { appeared = true }
        }
        .onChange(of: session.lastUpdate) { _, _ in
            model.sync(from: session)
        }
        .onChange(of: model.isPaused) { _, paused in
            if !paused { model.sync(from: session) }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await model.pollSockets(session)
                try? await Task.sleep(nanoseconds: UInt64(max(2, session.refreshInterval)) * NSEC_PER_SEC)
            }
        }
    }
}

private struct MacChartPoint: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    let value: Double
}

private struct MacChartSeries: Identifiable, Equatable {
    let id: String
    let label: String
    let color: Color
    let points: [MacChartPoint]
    let showsAreaFill: Bool
}

private enum MacChartYMode: Equatable {
    case percentage
    case count(floor: Double)
    case byteRate
}

private struct MacAnimatedChartCard: View {
    let title: String
    let unitLabel: String
    let series: [MacChartSeries]
    let yMode: MacChartYMode
    let valueFormatter: (Double) -> String
    let isLive: Bool
    let cardIndex: Int
    let appeared: Bool
    var emptyHint: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    @State private var drawProgress: CGFloat = 0

    private var allPoints: [MacChartPoint] { series.flatMap(\.points) }
    private var latestSampleID: Int { allPoints.last?.id ?? 0 }

    private var xDomain: ClosedRange<Date> {
        guard let first = allPoints.map(\.timestamp).min(),
              let last = allPoints.map(\.timestamp).max()
        else {
            let now = Date()
            return now.addingTimeInterval(-30) ... now
        }
        let span = last.timeIntervalSince(first)
        if span < 1 { return first.addingTimeInterval(-15) ... last.addingTimeInterval(2) }
        return first ... last.addingTimeInterval(max(0.5, span * 0.03))
    }

    private var yUpperBound: Double {
        switch yMode {
        case .percentage: return 100
        case .count(let floor):
            let peak = allPoints.map(\.value).max() ?? 0
            return max(floor, ceil(peak * 1.2 / 10) * 10)
        case .byteRate:
            let peak = allPoints.map(\.value).max() ?? 0
            return max(1024, peak * 1.25)
        }
    }

    private var snappedTimestamp: Date? {
        guard let selectedDate,
              let ref = series.first(where: { !$0.points.isEmpty }),
              let nearest = ref.points.min(by: { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) })
        else { return nil }
        return nearest.timestamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                Spacer()
                if let snapped = snappedTimestamp {
                    Text(snapped.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(String(localized: "Unit: \(unitLabel)"))
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                }
            }

            if allPoints.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let emptyHint {
                        Text(emptyHint)
                            .font(.caption)
                            .foregroundStyle(.rxInkSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 156)
            } else {
                Chart {
                    ForEach(series) { line in
                        if line.showsAreaFill {
                            ForEach(line.points) { point in
                                AreaMark(
                                    x: .value("Time", point.timestamp),
                                    yStart: .value("Baseline", 0),
                                    yEnd: .value(line.label, point.value),
                                    series: .value("Series", line.id)
                                )
                                .interpolationMethod(.monotone)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [line.color.opacity(0.22), line.color.opacity(0.01)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                        }

                        ForEach(line.points) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value(line.label, point.value),
                                series: .value("Series", line.id)
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(line.color)
                        }
                    }

                    if let target = snappedTimestamp {
                        RuleMark(x: .value("Selected", target))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.55))
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: 0 ... yUpperBound)
                .chartXSelection(value: $selectedDate)
                .chartLegend(.hidden)
                .frame(height: 156)
                .padding(.top, 8)
                .padding(.trailing, 6)
                .mask(
                    Rectangle()
                        .scaleEffect(x: drawProgress, y: 1, anchor: .leading)
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: latestSampleID)
            }

            HStack(spacing: 14) {
                ForEach(series) { line in
                    let val: Double? = if let target = snappedTimestamp {
                        line.points.min(by: { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) })?.value
                    } else {
                        line.points.last?.value
                    }
                    HStack(spacing: 5) {
                        Circle().fill(line.color).frame(width: 7, height: 7)
                        Text(line.label).font(.caption).foregroundStyle(.rxInkSecondary)
                        if let val {
                            Text(valueFormatter(val))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.rxInk)
                                .contentTransition(.numericText())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .rxCard()
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .animation(
            reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.85).delay(Double(cardIndex) * 0.05),
            value: appeared
        )
        .onAppear {
            if reduceMotion {
                drawProgress = 1
            } else {
                drawProgress = 0
                withAnimation(.easeOut(duration: 0.72).delay(0.06 + Double(cardIndex) * 0.05)) {
                    drawProgress = 1
                }
            }
        }
    }
}

//
//  ServerChartsView.swift
//  TamioMobile
//
//  Animated real-time telemetry charts tab inside ServerDetailView:
//  CPU, Memory / Swap, Disk, Processes, Upload / Download, and TCP / UDP.
//

import Charts
import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

// MARK: - Telemetry History Store

@MainActor
final class MobileTelemetryChartsStore: ObservableObject {
    private static var cache: [RDMachine.ID: MobileTelemetryChartsStore] = [:]

    static func of(_ id: RDMachine.ID) -> MobileTelemetryChartsStore {
        if let existing = cache[id] { return existing }
        let created = MobileTelemetryChartsStore()
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

    /// Syncs from `MonitorSession.history` on first open and appends live
    /// readings whenever `session.lastUpdate` advances.
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
                let sample = Sample(
                    id: allocateSampleID(),
                    timestamp: ts,
                    cpu: history.cpu[index],
                    memory: index < history.memory.count ? history.memory[index] : 0,
                    swap: index < history.swap.count ? history.swap[index] : session.status.swapUsedPercent,
                    disk: index < history.disk.count ? history.disk[index] : session.status.primaryDiskUsedPercent,
                    processes: index < history.processes.count ? history.processes[index] : Double(session.status.system.totalProcs),
                    upload: index < history.transmit.count ? history.transmit[index] : 0,
                    download: index < history.receive.count ? history.receive[index] : 0
                )
                seeded.append(sample)
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
        let sample = Sample(
            id: allocateSampleID(),
            timestamp: updatedAt,
            cpu: Double(status.processor.summary.sumUsed),
            memory: status.memoryUsedPercent,
            swap: status.swapUsedPercent,
            disk: status.primaryDiskUsedPercent,
            processes: Double(status.system.totalProcs),
            upload: Double(status.physicalTransmitPerSecond),
            download: Double(status.physicalReceivePerSecond)
        )
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// Reads active TCP and UDP socket counts directly from `/proc/net/sockstat*`
    /// on Linux or `netstat` on Darwin.
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
        let point = SocketSample(
            id: allocateSocketID(),
            timestamp: Date(),
            tcp: tcp,
            udp: udp
        )
        socketSamples.append(point)
        if socketSamples.count > Self.capacity {
            socketSamples.removeFirst(socketSamples.count - Self.capacity)
        }
    }

    private func allocateSampleID() -> Int {
        defer { nextSampleID += 1 }
        return nextSampleID
    }

    private func allocateSocketID() -> Int {
        defer { nextSocketID += 1 }
        return nextSocketID
    }
}

// MARK: - Detail Charts Tab

struct DetailChartsTab: View {
    @ObservedObject var session: MonitorSession
    @ObservedObject private var model: MobileTelemetryChartsStore
    @State private var appeared = false

    init(session: MonitorSession, machineID: RDMachine.ID) {
        self.session = session
        model = MobileTelemetryChartsStore.of(machineID)
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = gridColumns(for: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusStrip

                    if !session.status.hasData && model.samples.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading metrics…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            cpuChartCard
                            memorySwapChartCard
                            diskChartCard
                            processesChartCard
                            bandwidthChartCard
                            socketChartCard
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .appleGroupedBackground()
        }
        .onAppear {
            model.sync(from: session)
            if !appeared {
                appeared = true
            }
        }
        .onChange(of: session.lastUpdate) { _, _ in
            model.sync(from: session)
        }
        .onChange(of: model.isPaused) { _, paused in
            if !paused {
                model.sync(from: session)
            }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await model.pollSockets(session)
                let delay = UInt64(max(2, session.refreshInterval)) * NSEC_PER_SEC
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let count: Int = if width >= 960 {
            3
        } else if width >= 620 {
            2
        } else {
            1
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    // MARK: - Live Control Strip

    private var statusStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                LiveStatusBeacon(active: !model.isPaused && session.phase == .connected)
                Text(model.isPaused ? String(localized: "Paused") : String(localized: "Live"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.isPaused ? .orange : .primary)
            }

            if !model.samples.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(String(localized: "\(model.samples.count) samples"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(session.refreshInterval)s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    model.isPaused.toggle()
                }
            } label: {
                Label(
                    model.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isPaused ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 6 Telemetry Cards

    private var cpuChartCard: some View {
        let points = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.cpu)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "CPU"),
            unitLabel: "%",
            yAxisCaption: "%",
            series: [
                TelemetrySeries(
                    id: "cpu",
                    label: String(localized: "CPU"),
                    color: .orange,
                    points: points,
                    showsAreaFill: true
                ),
            ],
            yMode: .percentage,
            valueFormatter: { String(format: "%.1f%%", $0) },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 0,
            appeared: appeared
        )
    }

    private var memorySwapChartCard: some View {
        let memPoints = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.memory)
        }
        let swapPoints = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.swap)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "Memory / Swap"),
            unitLabel: "%",
            yAxisCaption: "%",
            series: [
                TelemetrySeries(
                    id: "memory",
                    label: String(localized: "Memory"),
                    color: .blue,
                    points: memPoints,
                    showsAreaFill: true
                ),
                TelemetrySeries(
                    id: "swap",
                    label: String(localized: "Swap"),
                    color: .indigo,
                    points: swapPoints,
                    showsAreaFill: false
                ),
            ],
            yMode: .percentage,
            valueFormatter: { String(format: "%.1f%%", $0) },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 1,
            appeared: appeared
        )
    }

    private var diskChartCard: some View {
        let points = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.disk)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "Disk"),
            unitLabel: "%",
            yAxisCaption: "%",
            series: [
                TelemetrySeries(
                    id: "disk",
                    label: String(localized: "Disk"),
                    color: .pink,
                    points: points,
                    showsAreaFill: true
                ),
            ],
            yMode: .percentage,
            valueFormatter: { String(format: "%.0f%%", $0) },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 2,
            appeared: appeared
        )
    }

    private var processesChartCard: some View {
        let points = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.processes)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "Processes"),
            unitLabel: String(localized: "Count"),
            yAxisCaption: String(localized: "Count"),
            series: [
                TelemetrySeries(
                    id: "processes",
                    label: String(localized: "Processes"),
                    color: .teal,
                    points: points,
                    showsAreaFill: true
                ),
            ],
            yMode: .count(floor: 20),
            valueFormatter: { "\(Int($0.rounded()))" },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 3,
            appeared: appeared
        )
    }

    private var bandwidthChartCard: some View {
        let uploadPoints = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.upload)
        }
        let downloadPoints = model.samples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.download)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "Upload / Download"),
            unitLabel: "B/s",
            yAxisCaption: "B/s",
            series: [
                TelemetrySeries(
                    id: "upload",
                    label: String(localized: "Upload"),
                    color: .purple,
                    points: uploadPoints,
                    showsAreaFill: true
                ),
                TelemetrySeries(
                    id: "download",
                    label: String(localized: "Download"),
                    color: .green,
                    points: downloadPoints,
                    showsAreaFill: false
                ),
            ],
            yMode: .byteRate,
            valueFormatter: { RXFormat.rateString($0) },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 4,
            appeared: appeared
        )
    }

    private var socketChartCard: some View {
        let tcpPoints = model.socketSamples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.tcp)
        }
        let udpPoints = model.socketSamples.map {
            TelemetryPoint(sampleID: $0.id, timestamp: $0.timestamp, value: $0.udp)
        }
        return AnimatedTelemetryCard(
            title: String(localized: "TCP / UDP"),
            unitLabel: String(localized: "Count"),
            yAxisCaption: String(localized: "Count"),
            series: [
                TelemetrySeries(
                    id: "tcp",
                    label: "TCP",
                    color: .cyan,
                    points: tcpPoints,
                    showsAreaFill: true
                ),
                TelemetrySeries(
                    id: "udp",
                    label: "UDP",
                    color: .brown,
                    points: udpPoints,
                    showsAreaFill: false
                ),
            ],
            yMode: .count(floor: 10),
            valueFormatter: { "\(Int($0.rounded()))" },
            isLive: !model.isPaused && session.phase == .connected,
            cardIndex: 5,
            appeared: appeared,
            emptyHint: model.socketProbed ? nil : String(localized: "Sampling sockets…")
        )
    }
}

// MARK: - Chart Data Types

private struct TelemetryPoint: Identifiable, Equatable {
    let sampleID: Int
    let timestamp: Date
    let value: Double

    var id: Int { sampleID }
}

private struct TelemetrySeries: Identifiable, Equatable {
    let id: String
    let label: String
    let color: Color
    let points: [TelemetryPoint]
    let showsAreaFill: Bool
}

private enum TelemetryYMode: Equatable {
    case percentage
    case count(floor: Double)
    case byteRate
}

// MARK: - Animated Chart Card

private struct AnimatedTelemetryCard: View {
    let title: String
    let unitLabel: String
    let yAxisCaption: String
    let series: [TelemetrySeries]
    let yMode: TelemetryYMode
    let valueFormatter: (Double) -> String
    let isLive: Bool
    let cardIndex: Int
    let appeared: Bool
    var emptyHint: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    @State private var drawProgress: CGFloat = 0

    private var allPoints: [TelemetryPoint] {
        series.flatMap(\.points)
    }

    private var latestSampleID: Int {
        allPoints.last?.sampleID ?? 0
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = allPoints.map(\.timestamp).min(),
              let last = allPoints.map(\.timestamp).max()
        else {
            let now = Date()
            return now.addingTimeInterval(-30) ... now
        }
        let span = last.timeIntervalSince(first)
        if span < 1 {
            return first.addingTimeInterval(-15) ... last.addingTimeInterval(2)
        }
        return first ... last.addingTimeInterval(max(0.5, span * 0.03))
    }

    private var usesSecondsFormat: Bool {
        xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) < 120
    }

    private var yUpperBound: Double {
        switch yMode {
        case .percentage:
            return 100
        case let .count(floor):
            let peak = allPoints.map(\.value).max() ?? 0
            return niceCeiling(max(peak * 1.18, floor))
        case .byteRate:
            let peak = allPoints.map(\.value).max() ?? 0
            return niceByteCeiling(peak)
        }
    }

    private var yTicks: [Double] {
        switch yMode {
        case .percentage:
            return [0, 25, 50, 75, 100]
        case .count, .byteRate:
            let top = yUpperBound
            return [0, top * 0.25, top * 0.5, top * 0.75, top]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            chartPlotArea
            legendRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 14)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.975)
        .animation(
            reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.84).delay(Double(cardIndex) * 0.05),
            value: appeared
        )
        .onAppear {
            if reduceMotion {
                drawProgress = 1
            } else {
                drawProgress = 0
                withAnimation(.easeOut(duration: 0.78).delay(0.08 + Double(cardIndex) * 0.055)) {
                    drawProgress = 1
                }
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let selected = snappedTimestamp {
                Text(formatTimestamp(selected, includeSeconds: true))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Text(String(localized: "Unit: \(unitLabel)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.2), value: snappedTimestamp)
    }

    // MARK: Plot Area

    private var chartPlotArea: some View {
        ZStack {
            if allPoints.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if let emptyHint {
                        Text(emptyHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 164)
            } else {
                HStack(alignment: .center, spacing: 4) {
                    Text(yAxisCaption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 4) {
                        telemetryChart
                            .frame(height: 148)
                            .mask(
                                Rectangle()
                                    .scaleEffect(x: drawProgress, y: 1, anchor: .leading)
                            )

                        Text("Time")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 36)
                    }
                }
            }
        }
    }

    private var telemetryChart: some View {
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
                                colors: [line.color.opacity(0.20), line.color.opacity(0.01)],
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

                // Pulsing live beacon on the latest reading when not scrubbing.
                if isLive, selectedDate == nil, let latest = line.points.last {
                    PointMark(
                        x: .value("Time", latest.timestamp),
                        y: .value(line.label, latest.value)
                    )
                    .symbolSize(0)
                    .annotation(position: .overlay) {
                        LivePointBeacon(color: line.color)
                    }
                }

                // Snapped point highlight when user scrubs horizontally.
                if let target = snappedTimestamp,
                   let nearest = nearestPoint(to: target, in: line.points)
                {
                    PointMark(
                        x: .value("Time", nearest.timestamp),
                        y: .value(line.label, nearest.value)
                    )
                    .symbolSize(42)
                    .foregroundStyle(line.color)
                    .annotation(position: .overlay) {
                        Circle()
                            .strokeBorder(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                    }
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
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(formatYAxisTick(number))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatTimestamp(date, includeSeconds: usesSecondsFormat))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: latestSampleID)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: snappedTimestamp)
    }

    // MARK: Footer Legend

    private var legendRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                legendItems
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                legendItems
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(series) { line in
            let displayValue = displayedValue(for: line)
            HStack(spacing: 5) {
                Circle()
                    .fill(line.color)
                    .frame(width: 7, height: 7)
                Text(line.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if let displayValue {
                    Text(valueFormatter(displayValue))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
            }
        }
    }

    // MARK: Helpers

    private var snappedTimestamp: Date? {
        guard let selectedDate,
              let referenceSeries = series.first(where: { !$0.points.isEmpty }),
              let nearest = nearestPoint(to: selectedDate, in: referenceSeries.points)
        else { return nil }
        return nearest.timestamp
    }

    private func displayedValue(for line: TelemetrySeries) -> Double? {
        if let target = snappedTimestamp,
           let nearest = nearestPoint(to: target, in: line.points)
        {
            return nearest.value
        }
        return line.points.last?.value
    }

    private func nearestPoint(to date: Date, in points: [TelemetryPoint]) -> TelemetryPoint? {
        points.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }

    private func formatYAxisTick(_ value: Double) -> String {
        switch yMode {
        case .percentage:
            return "\(Int(value.rounded()))"
        case .count:
            return "\(Int(value.rounded()))"
        case .byteRate:
            if value < 1 { return "-" }
            return compactByteAxis(value)
        }
    }

    private func compactByteAxis(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000_000 {
            return String(format: "%.1f GB", bytesPerSec / 1_000_000_000)
        }
        if bytesPerSec >= 1_000_000 {
            return String(format: "%.1f MB", bytesPerSec / 1_000_000)
        }
        if bytesPerSec >= 1_000 {
            return String(format: "%.1f KB", bytesPerSec / 1_000)
        }
        return "\(Int(bytesPerSec.rounded())) B"
    }

    private func formatTimestamp(_ date: Date, includeSeconds: Bool) -> String {
        if includeSeconds {
            return Self.secondFormatter.string(from: date)
        }
        return Self.minuteFormatter.string(from: date)
    }

    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let secondFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func niceCeiling(_ raw: Double) -> Double {
        let clamped = max(raw, 4)
        let magnitude = pow(10, floor(log10(clamped)))
        let normalized = clamped / magnitude
        let step: Double = if normalized <= 1.2 {
            1.2
        } else if normalized <= 2 {
            2
        } else if normalized <= 4 {
            4
        } else if normalized <= 6 {
            6
        } else if normalized <= 8 {
            8
        } else {
            10
        }
        return step * magnitude
    }

    private func niceByteCeiling(_ peak: Double) -> Double {
        guard peak > 1 else { return 1_000 }
        return niceCeiling(peak * 1.2)
    }
}

// MARK: - Animated Beacons

private struct LiveStatusBeacon: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .fill(Color.green.opacity(pulse ? 0 : 0.45))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1.55 : 0.7)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                            pulse = true
                        }
                    }
            }
            Circle()
                .fill(active ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
    }
}

private struct LivePointBeacon: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color.opacity(pulse ? 0 : 0.42))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.6 : 0.65)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                            pulse = true
                        }
                    }
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .strokeBorder(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.2)
                )
        }
        .allowsHitTesting(false)
    }
}

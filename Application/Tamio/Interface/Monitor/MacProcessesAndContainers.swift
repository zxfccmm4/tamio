//
//  MacProcessesAndContainers.swift
//  Tamio (macOS)
//
//  Native macOS Processes table (sortable, searchable, SIGTERM / SIGKILL) and
//  Docker Containers dashboard (start / restart / stop) inside MonitorPage,
//  matching iOS ServerDetailView's Processes & Containers tabs.
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

// MARK: - Processes Tab

struct MacProcessesTab: View {
    @ObservedObject var session: MonitorSession

    struct ProcessRow: Identifiable, Hashable {
        let id: Int
        let user: String
        let cpu: Double
        let mem: Double
        let command: String
    }

    enum SortKey: String, CaseIterable {
        case cpu, mem, pid
    }

    @State private var rows: [ProcessRow] = []
    @State private var search = ""
    @State private var sort: SortKey = .cpu
    @State private var loading = false

    private var displayed: [ProcessRow] {
        let filtered = search.isEmpty ? rows : rows.filter {
            $0.command.localizedCaseInsensitiveContains(search)
                || $0.user.localizedCaseInsensitiveContains(search)
                || "\($0.id)".contains(search)
        }
        switch sort {
        case .cpu: return filtered.sorted { $0.cpu > $1.cpu }
        case .mem: return filtered.sorted { $0.mem > $1.mem }
        case .pid: return filtered.sorted { $0.id < $1.id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Filter processes…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                RXSegmented(selection: $sort, options: [
                    .init(.cpu, "CPU"),
                    .init(.mem, "Memory"),
                    .init(.pid, "PID"),
                ], caps: false)

                Spacer()

                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }
                    .buttonStyle(.rx)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("PID").frame(width: 64, alignment: .leading)
                    Text("User").frame(width: 84, alignment: .leading)
                    Text("CPU").frame(width: 58, alignment: .trailing)
                    Text("Mem").frame(width: 58, alignment: .trailing)
                    Text("Command").frame(maxWidth: .infinity, alignment: .leading)
                    Text("").frame(width: 72)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.rxInkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if displayed.isEmpty {
                    Text(loading ? String(localized: "Loading processes…") : String(localized: "No processes"))
                        .font(.subheadline)
                        .foregroundStyle(.rxInkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(displayed.prefix(80)) { row in
                            HStack(spacing: 10) {
                                Text("\(row.id)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.rxInkSecondary)
                                    .frame(width: 64, alignment: .leading)
                                Text(row.user)
                                    .font(.caption)
                                    .foregroundStyle(.rxInkSecondary)
                                    .lineLimit(1)
                                    .frame(width: 84, alignment: .leading)
                                Text(String(format: "%.1f%%", row.cpu))
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(row.cpu >= 50 ? .orange : .rxInk)
                                    .frame(width: 58, alignment: .trailing)
                                Text(String(format: "%.1f%%", row.mem))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.rxInkSecondary)
                                    .frame(width: 58, alignment: .trailing)
                                Text(row.command)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Menu {
                                    Button("Send SIGTERM (kill)") { Task { await signal(pid: row.id, force: false) } }
                                    Button("Force Kill (kill -9)", role: .destructive) { Task { await signal(pid: row.id, force: true) } }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.rxInkSecondary)
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 72, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            .rxCard()
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
            }
        }
    }

    private func refresh() async {
        guard !loading, session.phase == .connected else { return }
        loading = true
        defer { loading = false }
        let cmd = "ps -eo pid,user,%cpu,%mem,comm --no-headers 2>/dev/null || ps -axo pid,user,%cpu,%mem,comm | tail -n +2"
        guard let output = await session.run(cmd, timeout: 10) else { return }
        var parsed: [ProcessRow] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[2]),
                  let mem = Double(parts[3])
            else { continue }
            parsed.append(ProcessRow(id: pid, user: String(parts[1]), cpu: cpu, mem: mem, command: String(parts[4])))
        }
        rows = parsed
    }

    private func signal(pid: Int, force: Bool) async {
        let flag = force ? "-9" : "-15"
        _ = await session.run("kill \(flag) \(pid)", timeout: 10)
        await refresh()
    }
}

// MARK: - Docker Containers Tab

struct MacContainersTab: View {
    @ObservedObject var session: MonitorSession

    struct ContainerRow: Identifiable, Hashable {
        let id: String
        let name: String
        let image: String
        let state: String
        let status: String
    }

    @State private var containers: [ContainerRow] = []
    @State private var loading = false
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "\(containers.count) containers"))
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInkSecondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }
                    .buttonStyle(.rx)
            }

            if unavailable {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.rxInkTertiary)
                    Text("Docker is not available on this server")
                        .font(.rxBodyStrong)
                        .foregroundStyle(.rxInkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .rxCard()
            } else if containers.isEmpty {
                Text(loading ? String(localized: "Loading containers…") : String(localized: "No containers found"))
                    .font(.subheadline)
                    .foregroundStyle(.rxInkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .rxCard()
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(containers) { item in
                        let running = item.state.lowercased() == "running"
                        HStack(spacing: 12) {
                            Circle()
                                .fill(running ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.rxBodyStrong)
                                Text("\(item.image) · \(item.status)")
                                    .font(.caption)
                                    .foregroundStyle(.rxInkSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if running {
                                Button("Restart") { Task { await runDocker("restart", id: item.id) } }
                                    .buttonStyle(.rx)
                                Button("Stop") { Task { await runDocker("stop", id: item.id) } }
                                    .buttonStyle(.rx)
                            } else {
                                Button("Start") { Task { await runDocker("start", id: item.id) } }
                                    .buttonStyle(.rxPrimary)
                            }
                        }
                        .padding(12)
                        .rxCard()
                    }
                }
            }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 8 * NSEC_PER_SEC)
            }
        }
    }

    private func refresh() async {
        guard !loading, session.phase == .connected else { return }
        loading = true
        defer { loading = false }
        let cmd = "command -v docker >/dev/null 2>&1 || { echo __NO_DOCKER__; exit 0; }; docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.State}}\\t{{.Status}}' 2>/dev/null"
        guard let output = await session.run(cmd, timeout: 10) else { return }
        if output.contains("__NO_DOCKER__") {
            unavailable = true
            containers = []
            return
        }
        unavailable = false
        var parsed: [ContainerRow] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            parsed.append(ContainerRow(id: parts[0], name: parts[1], image: parts[2], state: parts[3], status: parts[4]))
        }
        containers = parsed
    }

    private func runDocker(_ action: String, id: String) async {
        _ = await session.run("docker \(action) \(id)", timeout: 20)
        await refresh()
    }
}

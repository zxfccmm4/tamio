//
//  TraceSheetView.swift
//  TamioAssistantUI
//
//  FlowDown `TraceController` + `TraceStepController` in SwiftUI:
//  - Live-updates from `ConversationSession` as reasoning and tool calls
//    arrive or finish while the sheet stays open.
//  - Drills down into any Thought or Tool Call step to inspect every parameter
//    and the full selectable result with one-click copy.
//

import SwiftUI
import TamioAssistant

public struct TraceSheetView: View {
    public let session: ConversationSession
    public let summaryID: String
    public let showsInlineSteps: Bool

    @Environment(\.dismiss) private var dismiss

    public init(session: ConversationSession, summaryID: String, showsInlineSteps: Bool) {
        self.session = session
        self.summaryID = summaryID
        self.showsInlineSteps = showsInlineSteps
    }

    private var summary: AssistantActivitySummary? {
        for entry in session.transcriptEntries(showsInlineSteps: showsInlineSteps) {
            if case .activity(let candidate) = entry, candidate.id == summaryID {
                return candidate
            }
        }
        return nil
    }

    private var traceSteps: [AssistantTraceStep] {
        (summary?.steps ?? []).map(AssistantTraceStep.init)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if traceSteps.isEmpty {
                    ContentUnavailableView {
                        Label("No Activity Yet", systemImage: "sparkles")
                    } description: {
                        Text("Reasoning and tool execution steps will appear here as they run.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(traceSteps) { step in
                                if step.hasDetail {
                                    NavigationLink(value: step) {
                                        TraceStepRow(step: step)
                                    }
                                } else {
                                    TraceStepRow(step: step)
                                }
                            }
                        } header: {
                            if let summary {
                                HStack(spacing: 6) {
                                    if summary.isRunning {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(summary.title)
                                }
                            }
                        }
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle(String(localized: "Activity"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .navigationDestination(for: AssistantTraceStep.self) { step in
                TraceStepDetailView(step: step)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 520)
        #endif
    }
}

private struct TraceStepRow: View {
    let step: AssistantTraceStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stepIcon
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if case .tool(let exec, _) = step.kind {
                        statusBadge(exec)
                    }
                }

                if !step.subtitle.isEmpty {
                    Text(step.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .tool(let exec, _) = step.kind, !exec.targetHosts.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(exec.targetHosts.prefix(5), id: \.self) { host in
                            Text(host)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        if exec.targetHosts.count > 5 {
                            Text("+\(exec.targetHosts.count - 5)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.kind {
        case .thought:
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        case .tool(let exec, _):
            switch exec.status {
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            case .denied:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ exec: AssistantToolExecution) -> some View {
        HStack(spacing: 4) {
            if exec.durationMs > 0 {
                Text(exec.durationMs >= 1000 ? String(format: "%.1fs", Double(exec.durationMs) / 1000.0) : "\(exec.durationMs)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if exec.status != .succeeded {
                Text(statusLabel(exec.status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(exec.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(statusColor(exec.status).opacity(0.14), in: Capsule())
            }
        }
    }

    private func statusLabel(_ status: AssistantToolExecutionStatus) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "OK")
        case .failed: String(localized: "Failed")
        case .denied: String(localized: "Denied")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private func statusColor(_ status: AssistantToolExecutionStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .denied: .orange
        case .cancelled: .secondary
        }
    }
}

public struct TraceStepDetailView: View {
    public let step: AssistantTraceStep
    @State private var copied = false

    public init(step: AssistantTraceStep) {
        self.step = step
    }

    private var copyableText: String {
        switch step.kind {
        case .thought(let prose): prose
        case .tool(_, let detail): detail.plainText
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch step.kind {
                case .thought(let prose):
                    Text(prose)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .tool(let exec, let detail):
                    if !exec.targetHosts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Servers"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                ForEach(exec.targetHosts, id: \.self) { host in
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                        Text(host)
                                            .font(.caption.monospaced())
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                            }
                        }
                    }

                    ForEach(detail.sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            if let name = section.name {
                                Text(ToolArgumentLabel.text(for: name))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(section.value)
                                .font(section.isMonospaced ? .system(.caption, design: .monospaced) : .callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(step.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AssistantPasteboard.copy(copyableText)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? String(localized: "Copied") : String(localized: "Copy"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
            }
        }
    }
}

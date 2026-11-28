//
//  ActivitySummaryRow.swift
//  TamioAssistantUI
//
//  FlowDown `ActivitySummaryView`:
//  - Compact clickable status header ("Thought for 6s and called 2 tools >")
//    that opens the live-updating Trace sheet.
//  - Full-bleed subtle reason banner while running in collapsed mode.
//  - Optional inline step list (Thoughts prose + tool call status lines)
//    when `inlineActivityStepsEnabled` is active.
//

import SwiftUI
import TamioAssistant
import TamioDesign

public struct ActivitySummaryRow: View {
    public let summary: AssistantActivitySummary
    public let compact: Bool
    public let onOpenTrace: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        summary: AssistantActivitySummary,
        compact: Bool = false,
        onOpenTrace: @escaping () -> Void
    ) {
        self.summary = summary
        self.compact = compact
        self.onOpenTrace = onOpenTrace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpenTrace) {
                HStack(spacing: 6) {
                    if summary.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: summary.failedToolCount > 0 ? "exclamationmark.triangle.fill" : "sparkles")
                            .font(.system(size: compact ? 11 : 12, weight: .medium))
                            .foregroundStyle(summary.failedToolCount > 0 ? Color.orange : Color.secondary.opacity(0.75))
                    }

                    ShimmerThinkingText(
                        text: summary.title,
                        isActive: summary.isRunning,
                        font: compact ? .caption.weight(.medium) : .subheadline.weight(.medium)
                    )

                    Image(systemName: "chevron.right")
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // FlowDown MessageBannerView: subtle hairline banner displaying the live tool reason.
            if let banner = summary.banner, !banner.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(banner)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), lineWidth: 0.5)
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: banner)
                .onTapGesture(perform: onOpenTrace)
            }

            // FlowDown Inline Activity Steps mode
            if summary.showsSteps, !summary.inlineSteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.inlineSteps) { step in
                        inlineStepView(step)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10))
                        .frame(width: 2)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineStepView(_ step: AssistantActivitySummary.InlineStep) -> some View {
        switch step.kind {
        case .thought:
            Text(step.text)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .call(let status, let durationMs, let hosts):
            Button(action: onOpenTrace) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusGlyph(status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.text)
                            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)

                        if !hosts.isEmpty || durationMs > 0 {
                            HStack(spacing: 6) {
                                ForEach(hosts.prefix(4), id: \.self) { host in
                                    Text(host)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                if hosts.count > 4 {
                                    Text("+\(hosts.count - 4)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                if durationMs > 0 {
                                    Text(formatDuration(durationMs))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: AssistantToolExecutionStatus) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .denied:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000.0) : "\(ms)ms"
    }
}

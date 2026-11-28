//
//  ToolApprovalCardView.swift
//  TamioAssistantUI
//
//  FlowDown `ToolApprovalSection` + Tamio `CommandRiskAssessment`:
//  - Renders inside the composer card when `ConversationSession.approvalGate`
//    has a pending request (in-place morphing, never buried in scrollback).
//  - Displays tool title, risk badge, model-supplied `reason`, target server
//    chips, scrollable full command/arguments (never truncated with ellipsis),
//    and fixed decision footer (`Don't Allow`, optional `Allow 1 Hour` for
//    non-destructive actions, and `Allow`).
//

import SwiftUI
import TamioAssistant
import TamioModule

public struct ToolApprovalCardView: View {
    public let request: AssistantApprovalRequest
    public let compact: Bool
    public let onDecision: (AssistantApprovalDecision) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        request: AssistantApprovalRequest,
        compact: Bool = false,
        onDecision: @escaping (AssistantApprovalDecision) -> Void
    ) {
        self.request = request
        self.compact = compact
        self.onDecision = onDecision
    }

    private var riskTint: Color {
        switch request.risk.level {
        case .readOnly: .green
        case .modify: .orange
        case .destructive: .red
        }
    }

    private var extraArgumentRows: [ToolArgumentLabel.Row] {
        let rows = ToolArgumentLabel.rows(
            of: request.argumentsJSON,
            order: request.argumentOrder,
            title: request.title
        )
        let trimmedDetail = request.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            // Avoid duplicating the reason or the primary command already displayed in the detail block.
            if row.label == ToolArgumentLabel.known("reason") { return false }
            if !trimmedDetail.isEmpty && row.value.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedDetail {
                return false
            }
            return true
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            // Header: Icon + Title + Source + Risk Badge
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: request.isDestructive ? "exclamationmark.shield.fill" : request.icon)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(riskTint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(request.title)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let source = request.source, !source.isEmpty {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                Text(request.risk.level.localizedLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(riskTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(riskTint.opacity(colorScheme == .dark ? 0.22 : 0.14), in: Capsule())
            }

            // Risk classifier reasons
            if !request.risk.reasons.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: request.isDestructive ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(riskTint)
                        .padding(.top, 1.5)
                    Text(request.risk.reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(request.isDestructive ? riskTint : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Model-supplied `reason`
            if let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(String(localized: "Why"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Text(reason)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Target Server Host Chips
            if !request.hosts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(request.hosts, id: \.self) { host in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                Text(host)
                                    .font(.caption2.monospaced().weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }

            // Scrollable Command / Parameter Detail Block (bounded height, never truncated)
            let trimmedDetail = request.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDetail.isEmpty || !extraArgumentRows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !trimmedDetail.isEmpty {
                            Text(trimmedDetail)
                                .font(.system(compact ? .caption2 : .caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !extraArgumentRows.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(extraArgumentRows) { row in
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let label = row.label {
                                            Text(label)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(row.value)
                                            .font(row.isMonospaced ? .system(.caption2, design: .monospaced) : .caption)
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, trimmedDetail.isEmpty ? 0 : 4)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: compact ? 150 : 210)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(riskTint.opacity(0.22), lineWidth: 0.5)
                )
            }

            // Fixed Decision Footer
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onDecision(.deny)
                } label: {
                    Text(String(localized: "Don't Allow"))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: compact ? .infinity : nil)
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)

                if !request.isDestructive {
                    Button {
                        onDecision(.approveForOneHour)
                    } label: {
                        Text(String(localized: "Allow 1 Hour"))
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                }

                Spacer(minLength: 4)

                Button {
                    onDecision(.approve)
                } label: {
                    Label(
                        request.isDestructive ? String(localized: "Allow Destructive") : String(localized: "Allow"),
                        systemImage: request.isDestructive ? "exclamationmark.triangle.fill" : "checkmark"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(request.isDestructive ? .red : .accentColor)
                .controlSize(compact ? .small : .regular)
            }
            .padding(.top, 2)
        }
        .padding(compact ? 11 : 14)
    }
}

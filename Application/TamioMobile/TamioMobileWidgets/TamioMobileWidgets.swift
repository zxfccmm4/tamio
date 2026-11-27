//
//  TamioMobileWidgets.swift
//  TamioMobileWidgets
//
//  Refined Dynamic Island and Lock Screen Live Activity for active Tamio
//  SSH & Ghost Remote terminal sessions.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TamioMobileWidgets: WidgetBundle {
    var body: some Widget {
        TamioSessionLiveActivity()
    }
}

struct TamioSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TamioSessionAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(sessionURL(for: context.state.primarySessionID))
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 9) {
                        sessionBadgeIcon(isGhostRemote: context.state.isGhostRemote, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if !context.state.countryFlag.isEmpty {
                                    Text(context.state.countryFlag)
                                        .font(.caption)
                                }
                                Text(context.state.primaryHost)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            if !context.state.endpoint.isEmpty {
                                Text(context.state.endpoint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text(context.attributes.startedAt, style: .timer)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 40, alignment: .trailing)
                        }

                        Text(context.state.activeCount == 1 ? "SSH LIVE" : "\(context.state.activeCount) TABS")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(sessionAccentColor(for: context.state))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sessionAccentColor(for: context.state).opacity(0.22), in: Capsule())
                    }
                    .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        if let cpu = context.state.cpuPercent, let mem = context.state.memPercent {
                            compactMetricBar(label: "CPU", percent: cpu)
                            compactMetricBar(label: "MEM", percent: mem)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: context.state.isGhostRemote ? "bolt.horizontal.fill" : "chevron.right.square.fill")
                                    .font(.caption2)
                                    .foregroundStyle(sessionAccentColor(for: context.state))
                                Text(context.state.detail)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("Tamio")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: context.state.isGhostRemote ? "bolt.horizontal.fill" : "terminal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sessionAccentColor(for: context.state))
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                }
                .padding(.leading, 2)
            } compactTrailing: {
                if let cpu = context.state.cpuPercent, context.state.activeCount == 1 {
                    Text("\(cpu)%")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(metricColor(for: cpu))
                        .padding(.trailing, 2)
                } else {
                    Text("\(context.state.activeCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(sessionAccentColor(for: context.state).opacity(0.35), in: Capsule())
                }
            } minimal: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: context.state.isGhostRemote ? "bolt.horizontal.fill" : "terminal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sessionAccentColor(for: context.state))
                    Circle()
                        .fill(Color.green)
                        .frame(width: 4.5, height: 4.5)
                        .offset(x: 2, y: 1)
                }
            }
            .widgetURL(sessionURL(for: context.state.primarySessionID))
        }
    }

    private func sessionURL(for id: String) -> URL? {
        URL(string: "tamio://session/\(id)")
    }
}

// MARK: - Lock Screen & Notification Banner View

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TamioSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Top header: glowing icon + server identity + live timer pill
            HStack(alignment: .center, spacing: 11) {
                sessionBadgeIcon(isGhostRemote: context.state.isGhostRemote, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if !context.state.countryFlag.isEmpty {
                            Text(context.state.countryFlag)
                                .font(.footnote)
                        }
                        Text(context.state.primaryHost)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(context.state.isGhostRemote ? "REMOTE" : "SSH")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(sessionAccentColor(for: context.state))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(sessionAccentColor(for: context.state).opacity(0.22), in: Capsule())
                    }

                    if !context.state.endpoint.isEmpty {
                        Text(context.state.endpoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 42, alignment: .trailing)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.10), in: Capsule())
            }

            // Bottom telemetry / session status bar
            HStack(spacing: 10) {
                if let cpu = context.state.cpuPercent, let mem = context.state.memPercent {
                    compactMetricBar(label: "CPU", percent: cpu)
                    compactMetricBar(label: "MEM", percent: mem)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.caption2)
                            .foregroundStyle(sessionAccentColor(for: context.state))
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }

                HStack(spacing: 4) {
                    Text("\(context.state.activeCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(context.state.activeCount == 1 ? "session" : "sessions")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.60))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Shared Styling Helpers

private func sessionAccentColor(for state: TamioSessionAttributes.ContentState) -> Color {
    state.isGhostRemote
        ? Color(red: 0.72, green: 0.56, blue: 1.0)
        : Color(red: 0.45, green: 0.68, blue: 1.0)
}

private func metricColor(for percent: Int) -> Color {
    if percent >= 85 { return Color(red: 1.0, green: 0.38, blue: 0.38) }
    if percent >= 65 { return Color(red: 1.0, green: 0.68, blue: 0.25) }
    return Color(red: 0.35, green: 0.85, blue: 0.55)
}

private func sessionBadgeIcon(isGhostRemote: Bool, size: CGFloat) -> some View {
    let colors: [Color] = isGhostRemote
        ? [Color(red: 0.55, green: 0.32, blue: 0.96), Color(red: 0.36, green: 0.44, blue: 0.98)]
        : [Color(red: 0.26, green: 0.46, blue: 0.98), Color(red: 0.16, green: 0.72, blue: 0.88)]

    return ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: isGhostRemote ? "bolt.horizontal.fill" : "terminal.fill")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            }

        Circle()
            .fill(Color.green)
            .frame(width: size * 0.24, height: size * 0.24)
            .overlay {
                Circle().stroke(Color(red: 0.08, green: 0.09, blue: 0.13), lineWidth: 1.5)
            }
            .offset(x: 2, y: 2)
    }
}

private func compactMetricBar(label: String, percent: Int) -> some View {
    let clamped = min(max(percent, 0), 100)
    let tint = metricColor(for: clamped)
    return VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 2)
            Text("\(clamped)%")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
        }
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * CGFloat(clamped) / 100))
            }
        }
        .frame(height: 4)
    }
    .frame(maxWidth: .infinity)
}

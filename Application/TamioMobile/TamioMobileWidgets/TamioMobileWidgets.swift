//
//  TamioMobileWidgets.swift
//  TamioMobileWidgets
//
//  Dynamic Island and Lock Screen Live Activity for active Tamio sessions.
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
            HStack(spacing: 12) {
                Image(systemName: context.state.isGhostRemote ? "bolt.horizontal.circle.fill" : "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(Color.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.primaryHost)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(context.state.activeCount)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.indigo)
                    Text("active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(sessionURL(for: context.state.primarySessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.primaryHost, systemImage: context.state.isGhostRemote ? "bolt.horizontal" : "terminal")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.activeCount) open")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isGhostRemote ? "bolt.horizontal.fill" : "terminal.fill")
                    .foregroundStyle(Color.indigo)
            } compactTrailing: {
                Text("\(context.state.activeCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            } minimal: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color.indigo)
            }
            .widgetURL(sessionURL(for: context.state.primarySessionID))
        }
    }

    private func sessionURL(for id: String) -> URL? {
        URL(string: "tamio://session/\(id)")
    }
}

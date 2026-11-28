//
//  AttachmentsBarView.swift
//  TamioAssistantUI
//
//  Compact horizontal strip of pending attachments inside the composer
//  (terminal snapshots, text/log files, or images) with preview & remove.
//

import SwiftUI
import TamioAssistant
import TamioDesign

public struct AttachmentsBarView: View {
    @Binding public var attachments: [AssistantAttachment]
    @State private var previewing: AssistantAttachment?
    @Namespace private var zoomNamespace

    public init(attachments: Binding<[AssistantAttachment]>) {
        self._attachments = attachments
    }

    public var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(attachments) { item in
                        HStack(spacing: 6) {
                            Button {
                                previewing = item
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: item.systemImage)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(item.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.snappy(duration: 0.18)) {
                                    attachments.removeAll { $0.id == item.id }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove attachment"))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .zoomTransitionSource(id: item.id, in: zoomNamespace, cornerRadius: 8, appliesCardSurface: false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .sheet(item: $previewing) { item in
                AttachmentPreviewSheet(attachment: item)
                    .zoomTransitionDestination(sourceID: item.id, in: zoomNamespace)
            }
        }
    }
}

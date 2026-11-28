//
//  ErrorRowView.swift
//  TamioAssistantUI
//
//  FlowDown `ErrorMessageView` + `ErrorDetailController`:
//  - Compact red error row with trailing chevron + Retry button
//  - Tapping opens a popover with the full selectable error message and
//    one-click copy with checkmark feedback.
//

import SwiftUI

public struct ErrorRowView: View {
    public let text: String
    public let canRetry: Bool
    public let onRetry: () -> Void

    @State private var showDetail = false
    @State private var copied = false

    public init(text: String, canRetry: Bool, onRetry: @escaping () -> Void) {
        self.text = text
        self.canRetry = canRetry
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                showDetail = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.65))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                errorDetailPopover
            }

            Spacer(minLength: 6)

            if canRetry {
                Button(action: onRetry) {
                    Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var errorDetailPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "Error Details"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Button {
                    AssistantPasteboard.copy(text)
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
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 420)
    }
}

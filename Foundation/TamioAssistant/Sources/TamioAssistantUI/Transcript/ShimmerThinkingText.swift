//
//  ShimmerThinkingText.swift
//  TamioAssistantUI
//
//  FlowDown `ThinkingStatusLabel` in SwiftUI:
//  - Displays status text at subdued secondary opacity at rest
//  - Sweeps a soft highlight shimmer across the text while active
//  - Enforces a 1-second minimum display hold before transitioning between
//    distinct live statuses so rapid tool/thought updates never flicker.
//

import SwiftUI

public struct ShimmerThinkingText: View {
    public let text: String
    public let isActive: Bool
    public let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedText: String
    @State private var lastTransitionAt: Date = .distantPast
    @State private var pendingTask: Task<Void, Never>?
    @State private var shimmerPhase: CGFloat = -0.6

    private static let minimumHoldInterval: TimeInterval = 1.0

    public init(
        text: String,
        isActive: Bool,
        font: Font = .subheadline.weight(.medium)
    ) {
        self.text = text
        self.isActive = isActive
        self.font = font
        self._displayedText = State(initialValue: text)
    }

    public var body: some View {
        Group {
            if isActive && !reduceMotion {
                Text(displayedText)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .overlay {
                        GeometryReader { geo in
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .primary.opacity(0.85), location: 0.5),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(geo.size.width * 0.65, 48))
                            .offset(x: shimmerPhase * (geo.size.width + 64))
                        }
                        .mask(Text(displayedText).font(font))
                        .allowsHitTesting(false)
                    }
                    .onAppear { startShimmer() }
            } else {
                Text(displayedText)
                    .font(font)
                    .foregroundStyle(.secondary.opacity(isActive ? 0.85 : 0.7))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: text) { _, next in
            scheduleTextTransition(to: next)
        }
        .onChange(of: isActive) { _, active in
            if active {
                startShimmer()
            } else {
                // Immediately settle final summary title when activity ends.
                pendingTask?.cancel()
                pendingTask = nil
                displayedText = text
            }
        }
        .onDisappear {
            pendingTask?.cancel()
            pendingTask = nil
        }
    }

    private func startShimmer() {
        guard !reduceMotion else { return }
        shimmerPhase = -0.6
        withAnimation(.linear(duration: 1.65).repeatForever(autoreverses: false)) {
            shimmerPhase = 1.3
        }
    }

    private func scheduleTextTransition(to next: String) {
        guard next != displayedText else { return }
        pendingTask?.cancel()
        pendingTask = nil

        if !isActive {
            displayedText = next
            lastTransitionAt = Date()
            return
        }

        let elapsed = Date().timeIntervalSince(lastTransitionAt)
        if elapsed >= Self.minimumHoldInterval {
            withAnimation(.easeInOut(duration: 0.18)) {
                displayedText = next
            }
            lastTransitionAt = Date()
            return
        }

        let delay = Self.minimumHoldInterval - elapsed
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                displayedText = next
            }
            lastTransitionAt = Date()
        }
    }
}

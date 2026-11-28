//
//  AppleChrome.swift
//  TamioMobile
//
//  Ultra-lightweight Apple native HIG & iOS 26/27 Liquid Glass helpers.
//  Prioritizes clean typography, generous whitespace, and native system
//  controls over heavy custom chrome.
//

import SwiftUI
import TamioDesign
import UIKit

extension View {
    @ViewBuilder
    func appleGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func appleProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func appleTabBarMinimize() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    func appleGroupedBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder
    func appleInteractiveGlass<S: Shape, Fallback: ShapeStyle>(
        in shape: S,
        tint: Color? = nil,
        fallback: Fallback
    ) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            background(fallback, in: shape)
        }
    }

    /// Marks an individual card or thumbnail as the source of an iOS 18+ Zoom transition.
    /// Safely falls back to a no-op on iOS 17.
    func appleZoomSource<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        cornerRadius: CGFloat = 16,
        appliesCardSurface: Bool = true
    ) -> some View {
        zoomTransitionSource(
            id: id,
            in: namespace,
            cornerRadius: cornerRadius,
            appliesCardSurface: appliesCardSurface
        )
    }

    /// Applies the native iOS 18+ Zoom navigation transition on a destination view.
    /// Safely falls back to the system default transition on iOS 17 or when disabled.
    func appleZoomDestination<ID: Hashable>(
        sourceID: ID,
        in namespace: Namespace.ID,
        isEnabled: Bool = true
    ) -> some View {
        zoomTransitionDestination(
            sourceID: sourceID,
            in: namespace,
            isEnabled: isEnabled
        )
    }
}

/// Lightweight Apple-style tinted squircle icon badge for hub tiles and settings rows.
struct AppleFeatureBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.13),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

/// Wraps adjacent Liquid Glass controls on iOS 26+ so their glass merges cleanly.
struct AppleGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// Lightweight circular gauge in Apple Watch / ServerCat proportions:
/// green active arc (amber/red at high load), optional gray cache arc for
/// memory with a crisp visual gap, and subtle system track.
struct CleanRingGauge: View {
    let fraction: Double
    var secondaryFraction: Double = 0
    var lineWidth: CGFloat = 5.5
    var size: CGFloat = 58
    var centerText: String? = nil
    var activeColor: Color = .green
    var empty: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var clampedPrimary: Double { min(max(fraction.isFinite ? fraction : 0, 0), 1) }
    private var clampedSecondary: Double {
        let raw = secondaryFraction.isFinite ? secondaryFraction : 0
        return min(max(raw, 0), max(0, 1 - clampedPrimary))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.075), lineWidth: lineWidth)

            if !empty, clampedSecondary > 0.01 {
                let gap = clampedPrimary > 0.005 ? 0.018 : 0
                let start = min(1, clampedPrimary + gap)
                let end = min(1, clampedPrimary + clampedSecondary)
                if end > start + 0.005 {
                    Circle()
                        .trim(from: start, to: end)
                        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.5 : 0.42), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }

            if !empty {
                let shown = clampedPrimary > 0 ? max(clampedPrimary, 0.02) : 0
                if shown > 0 {
                    Circle()
                        .trim(from: 0, to: shown)
                        .stroke(resolvedColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }

            if let centerText {
                Text(centerText)
                    .font(.system(size: size * 0.255, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.35), value: clampedPrimary)
    }

    private var resolvedColor: Color {
        if clampedPrimary >= 0.9 { return .red }
        if clampedPrimary >= 0.75 { return .orange }
        return activeColor
    }
}

/// Three concentric rings for 1m / 5m / 15m load averages.
struct CleanLoadRings: View {
    let load1: Double
    let load5: Double
    let load15: Double
    let cores: Int

    var body: some View {
        let cap = Double(max(1, cores))
        ZStack {
            ring(min(1, load1 / cap), diameter: 38, width: 3.5)
            ring(min(1, load5 / cap), diameter: 27, width: 3.5)
            ring(min(1, load15 / cap), diameter: 16, width: 3.5)
        }
        .frame(width: 40, height: 40)
    }

    private func ring(_ fraction: Double, diameter: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: width)
            Circle()
                .trim(from: 0, to: max(fraction > 0 ? 0.04 : 0, fraction))
                .stroke(fraction >= 0.9 ? Color.red : Color.green, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Minimal horizontal pill strip for group filtering.
struct MobileGroupFilterBar: View {
    let groups: [String]
    @Binding var selection: String?

    var body: some View {
        if !groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(String(localized: "All"), selected: selection == nil) {
                        withAnimation(.snappy(duration: 0.2)) { selection = nil }
                    }
                    ForEach(groups, id: \.self) { group in
                        chip(group, selected: selection == group) {
                            withAnimation(.snappy(duration: 0.2)) { selection = group }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

struct MobileStatusDot: View {
    enum State {
        case online
        case connecting
        case offline
        case idle
    }

    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        case .offline: .red
        case .idle: Color(uiColor: .tertiaryLabel)
        }
    }
}

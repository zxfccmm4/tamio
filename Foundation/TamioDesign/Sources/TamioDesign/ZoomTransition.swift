//
//  ZoomTransition.swift
//  TamioDesign
//
//  iOS 18+ native Zoom Transition ViewModifiers with safe iOS 17 / macOS fallback.
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// Marks a card or thumbnail view as the source of an iOS 18+ Zoom transition.
/// Safely falls back to the unmodified content on iOS 17 and non-iOS platforms.
public struct ZoomTransitionSourceModifier<ID: Hashable>: ViewModifier {
    public let id: ID
    public let namespace: Namespace.ID
    public let cornerRadius: CGFloat
    public let appliesCardSurface: Bool

    public init(
        id: ID,
        namespace: Namespace.ID,
        cornerRadius: CGFloat = 16,
        appliesCardSurface: Bool = false
    ) {
        self.id = id
        self.namespace = namespace
        self.cornerRadius = cornerRadius
        self.appliesCardSurface = appliesCardSurface
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 18.0, *) {
                if appliesCardSurface {
                    content.matchedTransitionSource(id: id, in: namespace) { configuration in
                        configuration
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                } else {
                    content.matchedTransitionSource(id: id, in: namespace)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

/// Applies the native iOS 18+ Zoom navigation/sheet transition on a destination root view.
/// Safely falls back to the system default transition on iOS 17, when disabled, or on non-iOS platforms.
public struct ZoomTransitionDestinationModifier<ID: Hashable>: ViewModifier {
    public let sourceID: ID
    public let namespace: Namespace.ID
    public let isEnabled: Bool

    public init(
        sourceID: ID,
        namespace: Namespace.ID,
        isEnabled: Bool = true
    ) {
        self.sourceID = sourceID
        self.namespace = namespace
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        #if os(iOS)
            if isEnabled, #available(iOS 18.0, *) {
                content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            } else {
                content
            }
        #else
            content
        #endif
    }
}

public extension View {
    func zoomTransitionSource<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        cornerRadius: CGFloat = 16,
        appliesCardSurface: Bool = false
    ) -> some View {
        modifier(
            ZoomTransitionSourceModifier(
                id: id,
                namespace: namespace,
                cornerRadius: cornerRadius,
                appliesCardSurface: appliesCardSurface
            )
        )
    }

    func zoomTransitionDestination<ID: Hashable>(
        sourceID: ID,
        in namespace: Namespace.ID,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            ZoomTransitionDestinationModifier(
                sourceID: sourceID,
                namespace: namespace,
                isEnabled: isEnabled
            )
        )
    }
}

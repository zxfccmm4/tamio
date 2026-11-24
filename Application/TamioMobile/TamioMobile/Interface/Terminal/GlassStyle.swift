//
//  GlassStyle.swift
//  TamioMobile
//
//  Liquid Glass on iOS 26+, ultraThinMaterial / regularMaterial fallback on
//  iOS 17–25. Inspired by iGhostVT's GlassStyle.swift (MIT).
//

import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func barGlass<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .geometryGroup()
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .geometryGroup()
        }
    }

    @ViewBuilder
    func cardGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            clipShape(shape)
                .background(.regularMaterial)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .clipShape(shape)
        }
    }
}

struct GlassBarContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

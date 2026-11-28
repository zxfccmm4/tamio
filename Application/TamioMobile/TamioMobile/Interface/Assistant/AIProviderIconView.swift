//
//  AIProviderIconView.swift
//  TamioMobile
//
//  Vector brand badges, inline icons, menu labels, and custom icon picker
//  for all AI providers (OpenAI, Claude, Anthropic, Gemini, DeepSeek,
//  OpenRouter, Magpie, xAI, Ollama, and Apple Intelligence).
//

import SwiftUI
import TamioAssistant
import UIKit

// MARK: - Brand Asset Metadata

extension AIProviderKind {
    /// Vector asset name inside `Assets.xcassets/AIProviders`.
    var assetImageName: String {
        switch self {
        case .openAI, .openAICompatible: "ai-provider-openai"
        case .anthropic: "ai-provider-claude"
        case .anthropicCompatible: "ai-provider-anthropic"
        case .gemini: "ai-provider-gemini"
        case .deepSeek: "ai-provider-deepseek"
        case .openRouter: "ai-provider-openrouter"
        case .magpie: "ai-provider-magpie"
        case .xAI: "ai-provider-xai"
        case .ollama: "ai-provider-ollama"
        }
    }

    /// True for monochrome template SVGs that should be tinted via `.foregroundStyle`.
    var isTemplateAsset: Bool {
        switch self {
        case .anthropic, .gemini, .deepSeek:
            false
        case .openAI, .openRouter, .magpie, .xAI, .ollama, .openAICompatible, .anthropicCompatible:
            true
        }
    }

    /// Signature brand tint color.
    var brandColor: Color {
        switch self {
        case .openAI: Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .deepSeek: Color(red: 0.30, green: 0.42, blue: 1.00)
        case .openRouter: Color(red: 0.39, green: 0.40, blue: 0.95)
        case .magpie: Color(red: 0.14, green: 0.46, blue: 0.82)
        case .xAI: .primary
        case .ollama: .primary
        case .openAICompatible: .teal
        case .anthropicCompatible: .orange
        }
    }

    var badgeForegroundColor: Color {
        switch self {
        case .openAI: Color(red: 0.06, green: 0.64, blue: 0.50)
        case .openRouter: Color(red: 0.39, green: 0.40, blue: 0.95)
        case .magpie: Color(red: 0.14, green: 0.46, blue: 0.82)
        case .openAICompatible: .teal
        case .anthropicCompatible: .orange
        case .xAI, .ollama, .anthropic, .gemini, .deepSeek: .primary
        }
    }

    var isCustomCompatible: Bool {
        self == .openAICompatible || self == .anthropicCompatible
    }

    static let iconPickerBrands: [AIProviderKind] = [
        .openAI, .anthropic, .anthropicCompatible, .gemini, .deepSeek,
        .openRouter, .magpie, .xAI, .ollama,
    ]
}

// MARK: - Icon Tint Presets

enum AIProviderIconTint: String, CaseIterable, Identifiable {
    case accent, teal, blue, indigo, purple, pink, orange, green, red, primary

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .red: .red
        case .primary: .primary
        }
    }

    var displayName: String {
        switch self {
        case .accent: String(localized: "Default")
        case .teal: String(localized: "Teal")
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .orange: String(localized: "Orange")
        case .green: String(localized: "Green")
        case .red: String(localized: "Red")
        case .primary: String(localized: "Monochrome")
        }
    }

    static func resolve(_ name: String) -> Color {
        (AIProviderIconTint(rawValue: name) ?? .accent).color
    }
}

// MARK: - Icon Source

enum AIProviderIconSource: Equatable {
    case appleIntelligence
    case kind(AIProviderKind)
    case custom(AIProviderCustomIcon)

    static func from(provider: AIProviderConfig) -> AIProviderIconSource {
        if let customIcon = provider.customIcon {
            return .custom(customIcon)
        }
        return .kind(provider.kind)
    }

    static func from(kind: AIProviderKind, customIcon: AIProviderCustomIcon?) -> AIProviderIconSource {
        if let customIcon {
            return .custom(customIcon)
        }
        return .kind(kind)
    }

    @MainActor
    static func from(selection: AIActiveSelection, store: AIProviderStore) -> AIProviderIconSource {
        switch selection {
        case .appleIntelligence, .applePrivateCloudCompute:
            return .appleIntelligence
        case .custom(let id):
            if let provider = store.providers.first(where: { $0.id == id }) {
                return .from(provider: provider)
            }
            return .appleIntelligence
        }
    }

    fileprivate static var appleIntelligenceSymbol: String {
        if UIImage(systemName: "apple.intelligence") != nil {
            return "apple.intelligence"
        }
        return "sparkles"
    }
}

// MARK: - Squircle Brand Badge

struct AIProviderBadgeView: View {
    enum Size {
        case compact // 24pt
        case regular // 36pt
        case large   // 46pt

        var containerLength: CGFloat {
            switch self {
            case .compact: 24
            case .regular: 36
            case .large: 46
            }
        }

        var iconLength: CGFloat {
            switch self {
            case .compact: 14
            case .regular: 20
            case .large: 25
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .compact: 7
            case .regular: 10
            case .large: 13
            }
        }
    }

    let source: AIProviderIconSource
    var size: Size = .regular
    var isDimmed: Bool = false

    init(kind: AIProviderKind, size: Size = .regular, isDimmed: Bool = false) {
        self.source = .kind(kind)
        self.size = size
        self.isDimmed = isDimmed
    }

    init(provider: AIProviderConfig, size: Size = .regular, isDimmed: Bool = false) {
        self.source = .from(provider: provider)
        self.size = size
        self.isDimmed = isDimmed
    }

    init(source: AIProviderIconSource, size: Size = .regular, isDimmed: Bool = false) {
        self.source = source
        self.size = size
        self.isDimmed = isDimmed
    }

    private var appleIntelligenceGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.56, blue: 1.0),
                Color(red: 0.72, green: 0.40, blue: 0.96),
                Color(red: 0.98, green: 0.42, blue: 0.52),
                Color(red: 1.0, green: 0.62, blue: 0.25),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.75)
                )

            iconGlyph
                .frame(width: size.iconLength, height: size.iconLength)
                .frame(width: size.containerLength, height: size.containerLength)

            if case .kind(let kind) = source, kind.isCustomCompatible, size != .compact {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: size == .large ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.white, kind.brandColor)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size.containerLength, height: size.containerLength)
        .opacity(isDimmed ? 0.45 : 1.0)
    }

    private var backgroundFill: AnyShapeStyle {
        switch source {
        case .appleIntelligence:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.blue.opacity(0.14), Color.purple.opacity(0.14), Color.pink.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .kind(let kind):
            if kind == .xAI || kind == .ollama {
                return AnyShapeStyle(Color.primary.opacity(0.07))
            }
            return AnyShapeStyle(kind.brandColor.opacity(0.12))
        case .custom(let custom):
            if custom.tintName == AIProviderIconTint.primary.rawValue {
                return AnyShapeStyle(Color.primary.opacity(0.07))
            }
            return AnyShapeStyle(customIconColor(custom).opacity(0.13))
        }
    }

    private var borderColor: Color {
        switch source {
        case .appleIntelligence:
            return Color.purple.opacity(0.24)
        case .kind(let kind):
            if kind == .xAI || kind == .ollama {
                return Color.primary.opacity(0.14)
            }
            return kind.brandColor.opacity(0.24)
        case .custom(let custom):
            if custom.tintName == AIProviderIconTint.primary.rawValue {
                return Color.primary.opacity(0.14)
            }
            return customIconColor(custom).opacity(0.26)
        }
    }

    private func customIconColor(_ custom: AIProviderCustomIcon) -> Color {
        if custom.kind == .brandAsset,
           let brand = AIProviderKind(rawValue: custom.value),
           !brand.isTemplateAsset
        {
            return brand.brandColor
        }
        return AIProviderIconTint.resolve(custom.tintName)
    }

    @ViewBuilder
    private var iconGlyph: some View {
        switch source {
        case .appleIntelligence:
            Image(systemName: AIProviderIconSource.appleIntelligenceSymbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(appleIntelligenceGradient)
        case .kind(let kind):
            if kind.isTemplateAsset {
                Image(kind.assetImageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(kind.badgeForegroundColor)
            } else {
                Image(kind.assetImageName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            }
        case .custom(let custom):
            switch custom.kind {
            case .brandAsset:
                let brand = AIProviderKind(rawValue: custom.value) ?? .openAI
                if brand.isTemplateAsset {
                    Image(brand.assetImageName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(AIProviderIconTint.resolve(custom.tintName))
                } else {
                    Image(brand.assetImageName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                }
            case .symbol:
                Image(systemName: custom.value)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(AIProviderIconTint.resolve(custom.tintName))
            }
        }
    }
}

// MARK: - Inline Icon (Toolbars & Chips)

struct AIProviderInlineIcon: View {
    let source: AIProviderIconSource
    var length: CGFloat = 15

    init(kind: AIProviderKind, length: CGFloat = 15) {
        self.source = .kind(kind)
        self.length = length
    }

    init(provider: AIProviderConfig, length: CGFloat = 15) {
        self.source = .from(provider: provider)
        self.length = length
    }

    init(source: AIProviderIconSource, length: CGFloat = 15) {
        self.source = source
        self.length = length
    }

    var body: some View {
        switch source {
        case .appleIntelligence:
            Image(systemName: AIProviderIconSource.appleIntelligenceSymbol)
                .resizable()
                .scaledToFit()
                .frame(width: length, height: length)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple, .pink, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .kind(let kind):
            if kind.isTemplateAsset {
                Image(kind.assetImageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: length, height: length)
                    .foregroundStyle(kind.badgeForegroundColor)
            } else {
                Image(kind.assetImageName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: length, height: length)
            }
        case .custom(let custom):
            switch custom.kind {
            case .brandAsset:
                let brand = AIProviderKind(rawValue: custom.value) ?? .openAI
                if brand.isTemplateAsset {
                    Image(brand.assetImageName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: length, height: length)
                        .foregroundStyle(AIProviderIconTint.resolve(custom.tintName))
                } else {
                    Image(brand.assetImageName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: length, height: length)
                }
            case .symbol:
                Image(systemName: custom.value)
                    .resizable()
                    .scaledToFit()
                    .frame(width: length, height: length)
                    .foregroundStyle(AIProviderIconTint.resolve(custom.tintName))
            }
        }
    }
}

// MARK: - Menu Label

struct AIProviderMenuLabel: View {
    let title: String
    let provider: AIProviderConfig
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else if let custom = provider.customIcon {
            switch custom.kind {
            case .brandAsset:
                let brand = AIProviderKind(rawValue: custom.value) ?? provider.kind
                Label { Text(title) } icon: { Image(brand.assetImageName) }
            case .symbol:
                Label(title, systemImage: custom.value)
            }
        } else {
            Label { Text(title) } icon: { Image(provider.kind.assetImageName) }
        }
    }
}

// MARK: - Custom Icon Picker Sheet

struct AIProviderIconPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let providerKind: AIProviderKind
    let providerName: String
    @Binding var customIcon: AIProviderCustomIcon?

    @State private var selectedKind: AIProviderCustomIcon.Kind
    @State private var selectedValue: String
    @State private var selectedTint: String

    private static let curatedSymbols: [String] = [
        "sparkles", "cpu.fill", "bolt.fill", "globe",
        "server.rack", "network", "cloud.fill", "terminal.fill",
        "cube.fill", "brain", "wand.and.stars", "flame.fill",
        "bird.fill", "atom", "hexagon.fill", "shield.fill",
        "command", "paperplane.fill", "waveform", "antenna.radiowaves.left.and.right",
    ]

    init(
        providerKind: AIProviderKind,
        providerName: String,
        customIcon: Binding<AIProviderCustomIcon?>
    ) {
        self.providerKind = providerKind
        self.providerName = providerName
        self._customIcon = customIcon
        if let existing = customIcon.wrappedValue {
            _selectedKind = State(initialValue: existing.kind)
            _selectedValue = State(initialValue: existing.value)
            _selectedTint = State(initialValue: existing.tintName)
        } else {
            _selectedKind = State(initialValue: .brandAsset)
            _selectedValue = State(initialValue: providerKind.rawValue)
            _selectedTint = State(initialValue: AIProviderIconTint.teal.rawValue)
        }
    }

    private var previewIcon: AIProviderCustomIcon {
        AIProviderCustomIcon(kind: selectedKind, value: selectedValue, tintName: selectedTint)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AIProviderBadgeView(source: .custom(previewIcon), size: .large)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(providerName.isEmpty ? providerKind.displayName : providerName)
                                .font(.headline)
                            Text(selectedKind == .brandAsset ? String(localized: "Brand Vector Icon") : String(localized: "SF Symbol Icon"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if customIcon != nil {
                            Button("Reset") {
                                customIcon = nil
                                dismiss()
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Tint Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 10)], spacing: 10) {
                        ForEach(AIProviderIconTint.allCases) { tint in
                            let chosen = selectedTint == tint.rawValue
                            Button {
                                selectedTint = tint.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(tint.color.opacity(tint == .primary ? 0.85 : 0.9))
                                        .frame(width: 28, height: 28)
                                    if chosen {
                                        Circle()
                                            .strokeBorder(Color.primary, lineWidth: 2)
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(tint == .primary ? Color(uiColor: .systemBackground) : .white)
                                    }
                                }
                                .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tint.displayName)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Brand Icons") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                        ForEach(AIProviderKind.iconPickerBrands) { brand in
                            let chosen = selectedKind == .brandAsset && selectedValue == brand.rawValue
                            Button {
                                selectedKind = .brandAsset
                                selectedValue = brand.rawValue
                            } label: {
                                VStack(spacing: 6) {
                                    AIProviderBadgeView(
                                        source: .custom(AIProviderCustomIcon(kind: .brandAsset, value: brand.rawValue, tintName: selectedTint)),
                                        size: .regular
                                    )
                                    Text(brandShortName(brand))
                                        .font(.caption2)
                                        .foregroundStyle(chosen ? Color.accentColor : .secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(chosen ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("System Symbols") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 10)], spacing: 10) {
                        ForEach(Self.curatedSymbols, id: \.self) { symbol in
                            let chosen = selectedKind == .symbol && selectedValue == symbol
                            Button {
                                selectedKind = .symbol
                                selectedValue = symbol
                            } label: {
                                AIProviderBadgeView(
                                    source: .custom(AIProviderCustomIcon(kind: .symbol, value: symbol, tintName: selectedTint)),
                                    size: .regular
                                )
                                .padding(4)
                                .background(chosen ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Provider Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        customIcon = previewIcon
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func brandShortName(_ brand: AIProviderKind) -> String {
        switch brand {
        case .anthropic: "Claude"
        case .anthropicCompatible: "Anthropic"
        case .gemini: "Gemini"
        case .xAI: "xAI"
        case .ollama: "Ollama"
        default: brand.displayName
        }
    }
}

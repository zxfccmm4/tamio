//
//  AIProviderSettingsView.swift
//  TamioMobile
//
//  Lightweight Apple-native UI for managing AI providers (with vector brand
//  icons & custom icon picker), picking models, and managing/running
//  Server Ops Skills (SKILL.md).
//

import SwiftUI
import TamioAssistant

// MARK: - AI Provider Management View

struct AIProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AIProviderStore
    var showsDoneButton: Bool = false

    private struct AddSheetContext: Identifiable {
        let id = UUID()
        let initialKind: AIProviderKind
        let zoomSourceID: String?
    }

    @State private var addSheetContext: AddSheetContext?
    @State private var editingProvider: AIProviderConfig?
    @State private var providerPendingDelete: AIProviderConfig?
    @Namespace private var zoomNamespace

    private var appleStatus: AppleIntelligenceStatus { .current }
    private var appleReady: Bool { appleStatus == .available }
    private var pccStatus: ApplePrivateCloudComputeStatus { .current }
    private var pccReady: Bool { store.privateCloudComputeEnabled && pccStatus == .available }
    private var effectiveSelection: AIActiveSelection {
        store.effectiveSelection(appleIntelligenceAvailable: appleReady, pccAvailable: pccReady)
    }

    private var activeCustomProvider: AIProviderConfig? {
        if case .custom(let id) = effectiveSelection {
            return store.provider(id: id)
        }
        return nil
    }

    var body: some View {
        List {
            activeOverviewSection
            appleIntelligenceSection
            if !store.providers.isEmpty {
                configuredProvidersSection
            }
            quickAddSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addSheetContext = AddSheetContext(initialKind: .openAI, zoomSourceID: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add AI Provider")
            }
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $addSheetContext) { ctx in
            NavigationStack {
                AIProviderEditorView(store: store, existing: nil, initialKind: ctx.initialKind)
            }
            .appleGroupedBackground()
            .appleZoomDestination(
                sourceID: ctx.zoomSourceID ?? ctx.initialKind.id,
                in: zoomNamespace,
                isEnabled: ctx.zoomSourceID != nil
            )
        }
        .sheet(item: $editingProvider) { provider in
            NavigationStack {
                AIProviderEditorView(store: store, existing: provider)
            }
            .appleGroupedBackground()
        }
        .alert(
            "Delete AI Provider?",
            isPresented: Binding(
                get: { providerPendingDelete != nil },
                set: { if !$0 { providerPendingDelete = nil } }
            )
        ) {
            if let target = providerPendingDelete {
                Button("Delete", role: .destructive) {
                    store.deleteProvider(id: target.id)
                    providerPendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { providerPendingDelete = nil }
        } message: {
            if let target = providerPendingDelete {
                Text("This will also remove the saved API key for \(target.name) from Keychain.")
            }
        }
    }

    // MARK: Active Overview

    private var activeOverviewSection: some View {
        Section {
            HStack(spacing: 14) {
                AIProviderBadgeView(
                    source: AIProviderIconSource.from(selection: effectiveSelection, store: store),
                    size: .large,
                    isDimmed: activeCustomProvider == nil && !appleReady
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())

                        if let custom = activeCustomProvider {
                            Text(custom.kind.protocolBadgeText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }

                    Text(store.activeDisplayName(appleIntelligenceAvailable: appleReady))
                        .font(.headline)

                    if let custom = activeCustomProvider {
                        Text(custom.model.isEmpty ? "—" : custom.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !store.hasCredential(for: custom) {
                            Label("API Key required", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(appleStatus.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if let custom = activeCustomProvider {
                    Button("Edit") { editingProvider = custom }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Built-In Apple Intelligence (On-Device & Private Cloud Compute)

    private var appleIntelligenceSection: some View {
        Section {
            Button {
                if appleReady { store.selectActive(.appleIntelligence) }
            } label: {
                HStack(spacing: 12) {
                    AIProviderBadgeView(source: .appleIntelligence, size: .regular, isDimmed: !appleReady)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Intelligence (On-Device)")
                            .font(.body.weight(.medium))
                            .foregroundStyle(appleReady ? .primary : .secondary)
                        Text(appleStatus.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if effectiveSelection == .appleIntelligence, appleReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!appleReady)

            Button {
                if pccReady { store.selectActive(.applePrivateCloudCompute) }
            } label: {
                HStack(spacing: 12) {
                    AppleFeatureBadge(systemImage: "cloud.fill", tint: .indigo, size: 32)
                        .opacity(pccReady ? 1 : 0.45)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Apple Intelligence (PCC)")
                                .font(.body.weight(.medium))
                                .foregroundStyle(pccReady ? .primary : .secondary)
                            Text("Cloud")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.indigo.opacity(0.12), in: Capsule())
                        }
                        Text(pccStatus.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if effectiveSelection == .applePrivateCloudCompute, pccReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pccReady)

            Toggle(isOn: $store.privateCloudComputeEnabled) {
                HStack(spacing: 12) {
                    AppleFeatureBadge(systemImage: "lock.icloud.fill", tint: .blue, size: 28)
                    Text("Enable Private Cloud Compute")
                }
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("Private Cloud Compute runs larger Apple Intelligence models on Apple Silicon servers with verifiable privacy (requires iOS 27+ and entitlement).")
        }
    }

    // MARK: Configured Providers

    private var configuredProvidersSection: some View {
        Section {
            ForEach(store.providers) { provider in
                let isActive = effectiveSelection == .custom(providerId: provider.id)
                let host = URL(string: provider.resolvedBaseURL)?.host()
                HStack(spacing: 10) {
                    Button {
                        if provider.isEnabled { store.selectActive(.custom(providerId: provider.id)) }
                    } label: {
                        HStack(spacing: 12) {
                            AIProviderBadgeView(provider: provider, size: .regular, isDimmed: !provider.isEnabled)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                                Text([provider.model, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if !store.hasCredential(for: provider) {
                                    Label("API Key required", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingProvider = provider
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) { providerPendingDelete = provider }
                    Button("Edit") { editingProvider = provider }.tint(.blue)
                }
            }
        } header: {
            Text("Configured Providers")
        }
    }

    // MARK: Quick Add Gallery

    private var quickAddSection: some View {
        Section {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(AIProviderKind.allCases) { kind in
                    Button {
                        addSheetContext = AddSheetContext(initialKind: kind, zoomSourceID: kind.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                AIProviderBadgeView(kind: kind, size: .regular)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor.opacity(0.85))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(kind.shortDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .appleZoomSource(id: kind.id, in: zoomNamespace, cornerRadius: 14)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            Text("Quick Add Provider")
        } footer: {
            Text("API keys are stored only in your device Keychain. Server passwords and SSH private keys are never sent to any AI provider.")
        }
    }
}

// MARK: - AI Provider Editor View

struct AIProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: AIProviderStore
    let existing: AIProviderConfig?

    @State private var name: String
    @State private var kind: AIProviderKind
    @State private var baseURL: String
    @State private var appendV1Suffix: Bool
    @State private var apiKey: String
    @State private var showKey = false
    @State private var model: String
    @State private var availableModels: [String]
    @State private var customUserAgent: String
    @State private var customIcon: AIProviderCustomIcon?
    @State private var isEnabled: Bool
    @State private var makeActive = true

    @State private var isTesting = false
    @State private var testResult: AIProviderTestResult?
    @State private var showIconPicker = false
    @State private var showModelPicker = false
    @State private var saveError: String?

    init(store: AIProviderStore, existing: AIProviderConfig?, initialKind: AIProviderKind = .openAI) {
        self.store = store
        self.existing = existing
        let resolved = existing?.kind ?? initialKind
        _name = State(initialValue: existing?.name ?? resolved.displayName)
        _kind = State(initialValue: resolved)
        _baseURL = State(initialValue: existing?.baseURL ?? resolved.defaultBaseURL)
        _appendV1Suffix = State(initialValue: existing?.appendV1Suffix ?? resolved.defaultAppendV1Suffix)
        _apiKey = State(initialValue: existing.flatMap { store.apiKey(for: $0.id) } ?? "")
        _model = State(initialValue: existing?.model ?? resolved.defaultModel)
        _availableModels = State(initialValue: existing?.mergedModels ?? resolved.recommendedModels)
        _customUserAgent = State(initialValue: existing?.customUserAgent ?? "")
        _customIcon = State(initialValue: existing?.customIcon)
        _isEnabled = State(initialValue: existing?.isEnabled ?? true)
    }

    private var currentIconSource: AIProviderIconSource {
        AIProviderIconSource.from(kind: kind, customIcon: customIcon)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftConfig: AIProviderConfig {
        AIProviderConfig(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            appendV1Suffix: appendV1Suffix,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            availableModels: availableModels,
            customUserAgent: customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines),
            customIcon: customIcon,
            isEnabled: isEnabled,
            createdAt: existing?.createdAt ?? Date()
        )
    }

    var body: some View {
        Form {
            Section("Provider") {
                HStack(spacing: 14) {
                    Button {
                        showIconPicker = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            AIProviderBadgeView(source: currentIconSource, size: .large)
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 4, y: 4)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name)
                            .font(.headline)
                        Text(kind.protocolBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(kind.brandColor == .primary ? .secondary : kind.brandColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((kind.brandColor == .primary ? Color.primary : kind.brandColor).opacity(0.12), in: Capsule())
                    }

                    Spacer()

                    Button("Icon") { showIconPicker = true }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AIProviderKind.allCases) { item in
                            let selected = item == kind
                            Button {
                                selectKind(item)
                            } label: {
                                HStack(spacing: 6) {
                                    AIProviderBadgeView(kind: item, size: .compact)
                                    Text(item.displayName)
                                        .font(.caption.weight(selected ? .semibold : .medium))
                                        .foregroundStyle(selected ? Color.accentColor : .primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                TextField("Display Name", text: $name)
            }

            Section {
                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Toggle("Append /v1 automatically", isOn: $appendV1Suffix)

                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField(kind.requiresAPIKey ? String(localized: "API Key") : String(localized: "API Key (Optional)"), text: $apiKey)
                        } else {
                            SecureField(kind.requiresAPIKey ? String(localized: "API Key") : String(localized: "API Key (Optional)"), text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Endpoint & Credentials")
            } footer: {
                Text("Resolved endpoint: \(draftConfig.resolvedBaseURL)")
                    .font(.caption.monospaced())
            }

            Section("Model") {
                HStack {
                    TextField("Model ID", text: $model)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Browse") { showModelPicker = true }
                        .font(.subheadline.weight(.medium))
                }
            }

            Section("Verification") {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView().controlSize(.small)
                            Text("Testing connection…")
                        } else {
                            Label("Test Connection & Fetch Models", systemImage: "network")
                        }
                    }
                }
                .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let testResult {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: testResult.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testResult.succeeded ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(testResult.message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if testResult.latencyMs > 0 {
                                Text("\(testResult.latencyMs) ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Advanced") {
                Toggle("Enabled", isOn: $isEnabled)
                if existing == nil {
                    Toggle("Set as Active Provider", isOn: $makeActive)
                }
                TextField("Custom User-Agent (Optional)", text: $customUserAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle(existing == nil ? String(localized: "Add AI Provider") : String(localized: "Edit AI Provider"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showIconPicker) {
            AIProviderIconPickerSheet(
                providerKind: kind,
                providerName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                customIcon: $customIcon
            )
        }
        .sheet(isPresented: $showModelPicker) {
            AIModelPickerSheet(
                providerName: name.isEmpty ? kind.displayName : name,
                iconSource: currentIconSource,
                selectedModel: $model,
                availableModels: $availableModels,
                recommendedModels: kind.recommendedModels,
                onRefreshModels: {
                    try await store.fetchModels(for: draftConfig, apiKeyOverride: apiKey)
                }
            )
        }
        .alert("Error", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func selectKind(_ newKind: AIProviderKind) {
        let oldKind = kind
        kind = newKind
        if name.isEmpty || name == oldKind.displayName { name = newKind.displayName }
        if baseURL.isEmpty || baseURL == oldKind.defaultBaseURL { baseURL = newKind.defaultBaseURL }
        appendV1Suffix = newKind.defaultAppendV1Suffix
        if model.isEmpty || oldKind.recommendedModels.contains(model) { model = newKind.defaultModel }
        availableModels = newKind.recommendedModels
        testResult = nil
    }

    private func runConnectionTest() async {
        isTesting = true
        defer { isTesting = false }
        let result = await store.testConnection(for: draftConfig, apiKeyOverride: apiKey)
        testResult = result
        if !result.discoveredModels.isEmpty {
            availableModels = result.discoveredModels
            if model.isEmpty, let first = result.discoveredModels.first {
                model = first
            }
        }
    }

    private func save() {
        do {
            if existing != nil {
                try store.updateProvider(draftConfig, apiKey: apiKey)
            } else {
                try store.addProvider(draftConfig, apiKey: apiKey, makeActive: makeActive)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Searchable Grouped Model Picker Sheet

struct AIModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let providerName: String
    var iconSource: AIProviderIconSource = .appleIntelligence
    @Binding var selectedModel: String
    @Binding var availableModels: [String]
    let recommendedModels: [String]
    let onRefreshModels: (() async throws -> [String])?

    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var isRefreshing = false
    @State private var statusMessage: String?

    private var allModels: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for m in ([selectedModel] + availableModels + recommendedModels) {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func vendorGroup(for modelID: String) -> String {
        if let slash = modelID.firstIndex(of: "/") {
            let prefix = String(modelID[..<slash]).trimmingCharacters(in: .whitespaces).lowercased()
            if !prefix.isEmpty { return prefix }
        }
        let lower = modelID.lowercased()
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return "openai" }
        if lower.hasPrefix("claude") { return "anthropic" }
        if lower.hasPrefix("gemini") || lower.hasPrefix("gemma") { return "google" }
        if lower.hasPrefix("deepseek") { return "deepseek" }
        if lower.hasPrefix("grok") { return "xai" }
        if lower.hasPrefix("qwen") || lower.hasPrefix("qwq") { return "qwen" }
        if lower.hasPrefix("llama") { return "meta" }
        return "other"
    }

    private static func displayGroup(_ key: String) -> String {
        switch key {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "deepseek": "DeepSeek"
        case "xai", "x-ai": "xAI"
        case "qwen": "Qwen"
        case "meta", "meta-llama": "Meta"
        case "other": String(localized: "Other")
        default: key
        }
    }

    private var groupKeys: [String] {
        let counts = Dictionary(grouping: allModels, by: Self.vendorGroup).mapValues(\.count)
        return counts.keys.sorted { a, b in
            if a == "other" { return false }
            if b == "other" { return true }
            let ca = counts[a] ?? 0
            let cb = counts[b] ?? 0
            return ca != cb ? ca > cb : a < b
        }
    }

    private var filteredModels: [String] {
        let tokens = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return allModels.filter { model in
            if let selectedGroup, Self.vendorGroup(for: model) != selectedGroup { return false }
            guard !tokens.isEmpty else { return true }
            let lower = model.lowercased()
            return tokens.allSatisfy { lower.contains($0) }
        }
    }

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        AIProviderBadgeView(source: iconSource, size: .compact)
                        Text(providerName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(allModels.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if groupKeys.count >= 2 {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterChip(String(localized: "All"), active: selectedGroup == nil) { selectedGroup = nil }
                                ForEach(groupKeys, id: \.self) { key in
                                    filterChip(Self.displayGroup(key), active: selectedGroup == key) {
                                        selectedGroup = selectedGroup == key ? nil : key
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !trimmedQuery.isEmpty, !allModels.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
                    Section {
                        Button {
                            selectAndDismiss(trimmedQuery)
                        } label: {
                            Label("Use custom model \"\(trimmedQuery)\"", systemImage: "plus.circle.fill")
                                .font(.callout.monospaced())
                        }
                    }
                }

                Section("\(providerName) · \(filteredModels.count)") {
                    ForEach(filteredModels, id: \.self) { modelID in
                        Button {
                            selectAndDismiss(modelID)
                        } label: {
                            HStack(spacing: 8) {
                                Text(modelID)
                                    .font(.callout.monospaced().weight(modelID == selectedModel ? .semibold : .regular))
                                    .foregroundStyle(modelID == selectedModel ? Color.accentColor : .primary)
                                if recommendedModels.contains(modelID) {
                                    Text("Recommended")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                                if modelID == selectedModel {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: Text("Search or enter custom model ID"))
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if onRefreshModels != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isRefreshing)
                        .accessibilityLabel("Refresh Models")
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func selectAndDismiss(_ modelID: String) {
        selectedModel = modelID
        if !availableModels.contains(modelID) {
            availableModels.insert(modelID, at: 0)
        }
        dismiss()
    }

    private func refresh() async {
        guard let onRefreshModels else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await onRefreshModels()
            if !fetched.isEmpty {
                availableModels = fetched
                statusMessage = String(localized: "Fetched \(fetched.count) models")
            } else {
                statusMessage = String(localized: "Provider returned no models")
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - Server Ops Skills View

struct ServerOpsSkillsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ServerOpsSkillStore
    @Bindable var assistant: ServerAssistant
    var showsDoneButton = true
    var onRunSkill: ((ServerOpsSkill) -> Void)? = nil

    @State private var selectedCategory: ServerOpsSkillCategory?
    @State private var searchText = ""
    @State private var showImportSheet = false
    @State private var importURL = ""
    @State private var importMarkdown = ""
    @State private var importError: String?
    @State private var isImporting = false

    private var filteredSkills: [ServerOpsSkill] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.skills.filter { skill in
            if let selectedCategory, skill.category != selectedCategory { return false }
            if !query.isEmpty {
                return skill.name.lowercased().contains(query)
                    || skill.description.lowercased().contains(query)
                    || skill.category.displayName.lowercased().contains(query)
            }
            return true
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip(String(localized: "All"), icon: "square.grid.2x2", active: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(ServerOpsSkillCategory.allCases) { category in
                            categoryChip(category.displayName, icon: category.systemImage, active: selectedCategory == category) {
                                selectedCategory = selectedCategory == category ? nil : category
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                ForEach(filteredSkills) { skill in
                    NavigationLink {
                        ServerOpsSkillDetailView(
                            skill: skill,
                            store: store,
                            assistant: assistant,
                            onRunSkill: onRunSkill == nil ? nil : { chosen in
                                dismiss()
                                onRunSkill?(chosen)
                            }
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: skill.category.systemImage)
                                .font(.body)
                                .foregroundStyle(skill.isEnabled ? Color.accentColor : .secondary)
                                .frame(width: 24)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(skill.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(skill.isEnabled ? .primary : .secondary)
                                    if assistant.pinnedSkillIDs.contains(skill.id) {
                                        Text("Pinned")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 4)

                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { _ in store.toggleEnabled(id: skill.id) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if let onRunSkill, skill.isEnabled {
                            Button {
                                dismiss()
                                onRunSkill(skill)
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        if skill.isEnabled {
                            Button {
                                assistant.togglePinnedSkill(skill.id)
                            } label: {
                                Label(
                                    assistant.pinnedSkillIDs.contains(skill.id) ? String(localized: "Unpin") : String(localized: "Pin"),
                                    systemImage: "pin"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if !skill.isBuiltIn {
                            Button("Delete", role: .destructive) {
                                store.deleteSkill(id: skill.id)
                            }
                        }
                    }
                }
            } header: {
                Text("Server Operations Skills · \(filteredSkills.count)")
            } footer: {
                Text("Enabled skills guide the AI assistant during multi-server audits and maintenance. Tap any skill to inspect its runbook or run it immediately.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: Text("Search skills"))
        .navigationTitle("Ops Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImportSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import Skill")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            NavigationStack {
                Form {
                    Section("Import from GitHub or URL") {
                        TextField("https://github.com/user/repo/blob/main/SKILL.md", text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            Task { await performURLImport() }
                        } label: {
                            if isImporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Fetch SKILL.md")
                            }
                        }
                        .disabled(isImporting || importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Section("Or Paste SKILL.md") {
                        TextEditor(text: $importMarkdown)
                            .font(.caption.monospaced())
                            .frame(minHeight: 160)
                        Button("Save Custom Skill") {
                            store.importFromMarkdown(importMarkdown)
                            importMarkdown = ""
                            showImportSheet = false
                        }
                        .disabled(importMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let importError {
                        Section {
                            Text(importError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Import Skill")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showImportSheet = false }
                    }
                }
            }
        }
    }

    private func categoryChip(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func performURLImport() async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            _ = try await store.importFromURL(importURL)
            importURL = ""
            showImportSheet = false
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Skill Detail View

private struct ServerOpsSkillDetailView: View {
    let skill: ServerOpsSkill
    @Bindable var store: ServerOpsSkillStore
    @Bindable var assistant: ServerAssistant
    var onRunSkill: ((ServerOpsSkill) -> Void)?

    private var currentSkill: ServerOpsSkill {
        store.skills.first(where: { $0.id == skill.id }) ?? skill
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: currentSkill.category.systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentSkill.name)
                            .font(.headline)
                        Text(currentSkill.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                Text(currentSkill.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let onRunSkill, currentSkill.isEnabled {
                    Button {
                        onRunSkill(currentSkill)
                    } label: {
                        Label("Run This Skill Now", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section("Status") {
                Toggle("Enabled", isOn: Binding(
                    get: { currentSkill.isEnabled },
                    set: { _ in store.toggleEnabled(id: currentSkill.id) }
                ))
                Toggle("Pin in Chat", isOn: Binding(
                    get: { assistant.pinnedSkillIDs.contains(currentSkill.id) },
                    set: { _ in assistant.togglePinnedSkill(currentSkill.id) }
                ))
                .disabled(!currentSkill.isEnabled)
            }

            Section("Runbook Instructions") {
                Text(currentSkill.instructions)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentSkill.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

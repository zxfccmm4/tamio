//
//  AboutView.swift
//  TamioMobile
//
//  Apple-native About screen modeled after SteveCFDNS:
//  - Interactive app icon header with one-tap version copy
//  - Core capabilities list pushing to rich detail views
//  - Connect links with optically normalized brand icons (X, Telegram, Mail, GitHub)
//  - Special thanks & GitHub contributors
//  - Privacy Policy & License section + interactive Made-With-Love footer
//

import SwiftUI
import UIKit

// MARK: - About Screen

struct AboutView: View {
    @ScaledMetric private var iconColumnWidth: CGFloat = 28
    @State private var loveCount = 0
    @Namespace private var zoomNamespace

    var body: some View {
        Form {
            Section {
                AboutHeaderView()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tamio is a native SSH client and AI-powered server operations hub for iOS, iPadOS, and macOS—combining a GPU-accelerated Ghostty terminal, agentless live telemetry with animated charts, concurrent SFTP, end-to-end encrypted iCloud sync, and an in-app AI Fleet Assistant.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Actively developed on top of missuo/tamio with non-jailbreak iGhostVT mobile terminal ergonomics, Apple Shortcuts, and Live Activities.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Overview")
            }

            Section("Core Capabilities") {
                ForEach(TamioCapability.all) { capability in
                    NavigationLink {
                        AboutCapabilityDetailView(capability: capability, namespace: zoomNamespace)
                    } label: {
                        capabilityRow(capability)
                            .appleZoomSource(id: capability.id, in: zoomNamespace, cornerRadius: 12, appliesCardSurface: false)
                    }
                }
            }

            Section("Connect") {
                ForEach(AboutLinkItem.social) { link in
                    AboutLinkRow(link: link)
                }
            }

            Section("Special Thanks") {
                ForEach(AboutLinkItem.acknowledgements) { link in
                    AboutLinkRow(link: link)
                }
            }

            Section {
                NavigationLink {
                    TamioPrivacyPolicyView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3.weight(.medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                            .frame(width: min(iconColumnWidth, 38), height: min(iconColumnWidth, 38))
                            .accessibilityHidden(true)

                        Text("Privacy Policy")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                    .padding(.vertical, 1)
                }

                NavigationLink {
                    LicenseView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .font(.title3.weight(.medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.indigo)
                            .frame(width: min(iconColumnWidth, 38), height: min(iconColumnWidth, 38))
                            .accessibilityHidden(true)

                        Text("License")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("Legal")
            } footer: {
                Text("Your SSH credentials, private keys, and AI API keys stay strictly in your device Keychain.")
            }

            Section {
                madeByButton
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capabilityRow(_ capability: TamioCapability) -> some View {
        HStack(spacing: 12) {
            Image(systemName: capability.systemImage)
                .font(.title3.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(capability.tint)
                .frame(width: min(iconColumnWidth, 38), height: min(iconColumnWidth, 38))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(capability.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 1)
    }

    private var madeByButton: some View {
        Button {
            loveCount += 1
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.bounce, value: loveCount)
                Text("Made with love by Steve")
                    .foregroundStyle(.tertiary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: loveCount)
    }
}

// MARK: - Header View

private struct AboutHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var logoSize: CGFloat = 84

    @State private var iconTapCount = 0
    @State private var iconWiggling = false
    @State private var copyTrigger = 0
    @State private var copiedVersion = false

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.21"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? shortVersion
    }

    private var versionString: String {
        String(localized: "Version \(shortVersion) (\(buildNumber))")
    }

    var body: some View {
        let clampedLogoSize = min(logoSize, 112)
        let cornerRadius = clampedLogoSize * 0.2237

        VStack(spacing: 6) {
            Button {
                iconTapCount += 1
                guard !reduceMotion else { return }
                withAnimation(.spring(duration: 0.22, bounce: 0.5)) {
                    iconWiggling = true
                }
            } label: {
                Image("TamioLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: clampedLogoSize, height: clampedLogoSize)
                    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                    }
                    .rotationEffect(.degrees(iconWiggling && !reduceMotion ? 8 : 0))
                    .scaleEffect(iconWiggling && !reduceMotion ? 1.04 : 1.0)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: iconTapCount)
            .task(id: iconTapCount) {
                guard iconTapCount > 0, !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.55)) {
                    iconWiggling = false
                }
            }

            Text("Tamio")
                .font(.title2.bold())
                .foregroundStyle(.primary)

            Text("Native SSH Client & AI Fleet Ops")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                copyVersion()
            } label: {
                HStack(spacing: 4) {
                    Text(versionString)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Image(systemName: copiedVersion ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedVersion ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(versionString), \(String(localized: "Copy"))")
            .sensoryFeedback(.success, trigger: copyTrigger)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .task(id: copyTrigger) {
            guard copyTrigger > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                copiedVersion = false
            }
        }
    }

    private func copyVersion() {
        UIPasteboard.general.string = "Tamio \(shortVersion) (\(buildNumber))"
        copyTrigger += 1
        withAnimation(.snappy(duration: 0.2)) {
            copiedVersion = true
        }
    }
}

// MARK: - Feature Icon Badge

private struct AboutFeatureBadge: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.13),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
    }
}

// MARK: - Capabilities Model & Detail View

private struct TamioCapability: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let highlights: [String]
    let systemImage: String
    let tint: Color
    let docsURL: URL?

    static var all: [TamioCapability] {
        [
            TamioCapability(
                id: "terminal",
                title: String(localized: "Ghostty Terminal"),
                subtitle: String(localized: "GPU-accelerated SSH shell with themes & keyboard bar"),
                detail: String(localized: "Powered by the native Ghostty terminal engine with full truecolor, Nerd Fonts, themes, scrollback search, interaction lock, customizable touch keyboard bar, and Live Activities."),
                highlights: [
                    String(localized: "Persistent ZStack tabs with zero-flicker switching & thumbnails"),
                    String(localized: "Apple Shortcuts, iPad multi-window & auto-reconnect"),
                ],
                systemImage: "terminal.fill",
                tint: .indigo,
                docsURL: URL(string: "https://ghostty.org/docs")
            ),
            TamioCapability(
                id: "monitor",
                title: String(localized: "Live Server Monitor"),
                subtitle: String(localized: "Agentless CPU, memory, disk, network, processes & Docker"),
                detail: String(localized: "Reads live telemetry directly over SSH without installing any daemon on your servers—covering CPU rings, memory cache breakdown, animated 6-chart history, per-mount disk I/O, processes, and Docker containers."),
                highlights: [
                    String(localized: "Zero server-side agent installation required"),
                    String(localized: "Animated real-time Charts for CPU, RAM/Swap, Disk, Procs, Net & TCP/UDP"),
                ],
                systemImage: "waveform.path.ecg",
                tint: .green,
                docsURL: URL(string: "https://github.com/zxfccmm4/tamio")
            ),
            TamioCapability(
                id: "assistant",
                title: String(localized: "AI Fleet Assistant"),
                subtitle: String(localized: "Multi-provider AI & 23 MCP tools for batch server ops"),
                detail: String(localized: "Built directly on Tamio's MCP tool engine with Apple Intelligence, OpenAI, Claude, Gemini, DeepSeek, Ollama, and 14 built-in ops skills to audit and manage servers in parallel."),
                highlights: [
                    String(localized: "Every command and host change requires explicit inline approval"),
                    String(localized: "Server passwords and SSH private keys are never sent to AI"),
                ],
                systemImage: "sparkles",
                tint: .purple,
                docsURL: URL(string: "https://github.com/zxfccmm4/tamio")
            ),
            TamioCapability(
                id: "sftp",
                title: String(localized: "SFTP File Manager"),
                subtitle: String(localized: "Dual-pane browser, code editor & transfer queue"),
                detail: String(localized: "Browse remote filesystems alongside local Files documents, edit server configs with syntax highlighting, and queue concurrent uploads and downloads with conflict handling."),
                highlights: [
                    String(localized: "Dual-pane split view on iPad and concurrent transfer queue"),
                    String(localized: "Built-in syntax-highlighted remote file editor"),
                ],
                systemImage: "folder.fill",
                tint: .blue,
                docsURL: URL(string: "https://tamio.sh")
            ),
            TamioCapability(
                id: "security",
                title: String(localized: "Encrypted Sync & Security"),
                subtitle: String(localized: "End-to-end iCloud sync, Keychain & Face ID lock"),
                detail: String(localized: "Credentials are encrypted on device and stored in Apple Keychain. Protect sessions with Face ID / Passcode lock, app-switcher blur, and strict SSH host key verification."),
                highlights: [
                    String(localized: "Zero-knowledge encrypted iCloud sync across Mac, iPhone, and iPad"),
                    String(localized: "Face ID lock and per-host known_hosts verification"),
                ],
                systemImage: "lock.shield.fill",
                tint: .teal,
                docsURL: URL(string: "https://tamio.sh")
            ),
            TamioCapability(
                id: "network",
                title: String(localized: "Port Forward & Ghost Remote"),
                subtitle: String(localized: "Local/remote SSH tunnels & LAN terminal discovery"),
                detail: String(localized: "Create local and remote SSH port forwards on the go, and discover or connect to Ghost Remote sessions over your local network or relay profiles."),
                highlights: [
                    String(localized: "One-tap local and remote SSH tunnel management"),
                    String(localized: "Bonjour LAN discovery and .vtrpsc relay import"),
                ],
                systemImage: "arrow.left.arrow.right.circle.fill",
                tint: .orange,
                docsURL: URL(string: "https://github.com/zxfccmm4/tamio")
            ),
        ]
    }
}

private struct AboutCapabilityDetailView: View {
    let capability: TamioCapability
    let namespace: Namespace.ID
    @ScaledMetric private var emblemSize: CGFloat = 56

    var body: some View {
        let clamped = min(emblemSize, 72)

        Form {
            Section {
                VStack(spacing: 8) {
                    AboutFeatureBadge(systemName: capability.systemImage, tint: capability.tint, size: clamped)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)

                    Text(capability.title)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)

                    Text(capability.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

            Section("Overview") {
                Text(capability.detail)
                    .font(.body)
                    .lineSpacing(3)
            }

            Section("Highlights") {
                ForEach(capability.highlights, id: \.self) { highlight in
                    Label {
                        Text(highlight)
                            .font(.body)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(capability.tint)
                    }
                }
            }

            if let docsURL = capability.docsURL {
                Section("Resources") {
                    AboutLinkRow(
                        link: AboutLinkItem(
                            title: String(localized: "Learn More"),
                            subtitle: docsURL.host(),
                            icon: .symbol("safari.fill", tint: .blue),
                            url: docsURL
                        )
                    )
                }
            }
        }
        .appleGroupedBackground()
        .appleZoomDestination(sourceID: capability.id, in: namespace)
        .navigationTitle(capability.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Link Item & Row

private struct AboutLinkItem: Identifiable {
    enum Icon {
        case asset(String)
        case github
        case symbol(String, tint: Color)
    }

    let title: String
    var subtitle: String? = nil
    let icon: Icon
    let url: URL?

    var id: String { title }

    static var social: [AboutLinkItem] {
        [
            AboutLinkItem(
                title: String(localized: "Follow on X"),
                subtitle: "@st7evechou",
                icon: .asset("symbol.twitter.icon"),
                url: URL(string: "https://twitter.com/st7evechou")
            ),
            AboutLinkItem(
                title: String(localized: "Join Telegram"),
                subtitle: "@st7evee",
                icon: .asset("Telegramicon"),
                url: URL(string: "https://t.me/st7evee")
            ),
            AboutLinkItem(
                title: String(localized: "Send Feedback"),
                subtitle: String(localized: "Send us an email"),
                icon: .asset("Mail"),
                url: URL(string: "mailto:zxfccmm@gmail.com?subject=Feedback%20for%20Tamio")
            ),
            AboutLinkItem(
                title: String(localized: "GitHub Repository"),
                subtitle: "zxfccmm4/tamio",
                icon: .github,
                url: URL(string: "https://github.com/zxfccmm4/tamio")
            ),
        ]
    }

    static var acknowledgements: [AboutLinkItem] {
        [
            AboutLinkItem(
                title: String(localized: "Upstream Repository"),
                subtitle: String(localized: "missuo/tamio — Original Tamio macOS & Foundation project (MIT)"),
                icon: .github,
                url: URL(string: "https://github.com/missuo/tamio")
            ),
            AboutLinkItem(
                title: String(localized: "Contributors"),
                subtitle: "@zxfccmm4 · @mizorewww · @missuo · @Lakr233 · @sarkrui · @SukkaW · @thedavidweng · @delete-cloud · @FahimFBA · @NyaMisty · @FaiChou",
                icon: .symbol("person.2.fill", tint: .blue),
                url: URL(string: "https://github.com/zxfccmm4/tamio/graphs/contributors")
            ),
            AboutLinkItem(
                title: "Ghostty",
                subtitle: String(localized: "Native GPU terminal engine & theme catalog (MIT)"),
                icon: .symbol("terminal.fill", tint: .indigo),
                url: URL(string: "https://ghostty.org")
            ),
            AboutLinkItem(
                title: "libssh2 & NSRemoteShell",
                subtitle: String(localized: "Native SSH2 & SFTP transport layer"),
                icon: .symbol("lock.fill", tint: .green),
                url: URL(string: "https://libssh2.org")
            ),
            AboutLinkItem(
                title: "catussh · Rayon · iGhostVT",
                subtitle: String(localized: "Upstream lineage & mobile terminal UX inspiration"),
                icon: .symbol("sparkles", tint: .purple),
                url: URL(string: "https://github.com/owngoal-dev/iGhostVT")
            ),
            AboutLinkItem(
                title: "SwiftUI & Keychain",
                subtitle: String(localized: "Apple native interface & secure credential storage"),
                icon: .symbol("swift", tint: .orange),
                url: URL(string: "https://developer.apple.com/xcode/swiftui/")
            ),
        ]
    }
}

private struct AboutLinkRow: View {
    let link: AboutLinkItem

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var iconColumnWidth: CGFloat = 28

    var body: some View {
        if let url = link.url {
            Link(destination: url) {
                HStack(spacing: 12) {
                    icon
                        .frame(width: min(iconColumnWidth, 38), height: min(iconColumnWidth, 38))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title)
                            .font(.body)
                            .foregroundStyle(.primary)

                        if let subtitle = link.subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 1)
                .contentShape(.rect)
            }
            .accessibilityAddTraits(.isLink)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch link.icon {
        case .asset(let name):
            normalizedAssetIcon(name)
        case .github:
            Image(colorScheme == .dark ? "github-mark-white" : "github-mark")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.title3.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func normalizedAssetIcon(_ name: String) -> some View {
        if name == "symbol.twitter.icon" {
            let badgeSize: CGFloat = 26
            let cornerRadius = badgeSize * 0.2237
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.12))
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.white)
            }
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
        } else if name == "Mail" {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 28.5, height: 28.5)
        } else {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - Privacy Policy View

private struct TamioPrivacyPolicyView: View {
    private struct CommitmentItem: Identifiable {
        let id: Int
        let icon: String
        let tint: Color
        let text: String
    }

    private var commitments: [CommitmentItem] {
        [
            .init(
                id: 1,
                icon: "key.fill",
                tint: .orange,
                text: String(localized: "All SSH passwords, private keys, passphrases, and AI API keys are stored exclusively in your device Keychain and never leave your control.")
            ),
            .init(
                id: 2,
                icon: "network",
                tint: .blue,
                text: String(localized: "SSH, SFTP, and server monitoring traffic goes directly from your device to your servers with no relay or third-party proxy.")
            ),
            .init(
                id: 3,
                icon: "sparkles",
                tint: .purple,
                text: String(localized: "When you use the AI Assistant with a remote provider, only your prompts and approved tool outputs are sent to the provider you configured—never passwords or private keys.")
            ),
            .init(
                id: 4,
                icon: "icloud.fill",
                tint: .teal,
                text: String(localized: "Optional iCloud Sync encrypts your server inventory end-to-end before storing it in your private Apple iCloud account.")
            ),
            .init(
                id: 5,
                icon: "hand.raised.fill",
                tint: .green,
                text: String(localized: "Tamio collects zero analytics, zero crash tracking, and zero advertising telemetry.")
            ),
        ]
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    AboutFeatureBadge(systemName: "hand.raised.fill", tint: .blue, size: 56)
                        .accessibilityHidden(true)

                    Text("Privacy Policy")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

            Section {
                ForEach(commitments) { item in
                    HStack(alignment: .top, spacing: 12) {
                        AboutFeatureBadge(systemName: item.icon, tint: item.tint, size: 28)
                            .padding(.top, 2)
                            .accessibilityHidden(true)

                        Text(item.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

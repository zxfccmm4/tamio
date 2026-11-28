//
//  WhatsNew.swift
//  TamioDesign
//
//  Apple-native "What's New" welcome sheet shared between iOS/iPadOS and macOS,
//  presenting per-release highlights once after EULA agreement on fresh installs
//  and automatically on every subsequent version update.
//

import SwiftUI

public enum WhatsNewPlatform: Sendable {
    case all
    case macOS
    case iOS

    public var matchesCurrentPlatform: Bool {
        switch self {
        case .all:
            true
        case .macOS:
            #if os(macOS)
                true
            #else
                false
            #endif
        case .iOS:
            #if os(macOS)
                false
            #else
                true
            #endif
        }
    }
}

public struct WhatsNewFeature: Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public let tint: Color
    public let title: String
    public let description: String
    public let platform: WhatsNewPlatform

    public init(
        id: String,
        symbol: String,
        tint: Color,
        title: String,
        description: String,
        platform: WhatsNewPlatform = .all
    ) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.description = description
        self.platform = platform
    }
}

public struct WhatsNewRelease: Identifiable, Sendable {
    public let version: String
    public let releaseNotesURL: URL
    public let features: [WhatsNewFeature]

    public var id: String { version }

    public var platformFeatures: [WhatsNewFeature] {
        features.filter(\.platform.matchesCurrentPlatform)
    }

    public init(version: String, releaseNotesURL: URL, features: [WhatsNewFeature]) {
        self.version = version
        self.releaseNotesURL = releaseNotesURL
        self.features = features
    }
}

public enum WhatsNewCatalog {
    public static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1"
    }

    public static func releaseNotesURL(for version: String = currentAppVersion) -> URL {
        URL(string: "https://github.com/zxfccmm4/tamio/releases/tag/v\(version)")!
    }

    public static func currentRelease(for version: String = currentAppVersion) -> WhatsNewRelease {
        if let matched = releases.first(where: { $0.version == version }) {
            return matched
        }
        let template = releases[0]
        return WhatsNewRelease(
            version: version,
            releaseNotesURL: releaseNotesURL(for: version),
            features: template.features
        )
    }

    public static var releases: [WhatsNewRelease] {
        [
            WhatsNewRelease(
                version: "0.3.1",
                releaseNotesURL: releaseNotesURL(for: "0.3.1"),
                features: [
                    WhatsNewFeature(
                        id: "whats-new-sheet",
                        symbol: "sparkles.rectangle.stack.fill",
                        tint: .blue,
                        title: String(localized: "What’s New on Every Update"),
                        description: String(localized: "A native welcome sheet highlights what changed after each update and on first setup, and can be reopened anytime from About or the app menu.")
                    ),
                    WhatsNewFeature(
                        id: "ios-live-activities-fix",
                        symbol: "platter.filled.top.iphone",
                        tint: .green,
                        title: String(localized: "Dynamic Island, Lock Screen & StandBy"),
                        description: String(localized: "Live Activities now stay in sync across Dynamic Island, Lock Screen, and StandBy with live CPU and memory updates and dimmed night-mode contrast."),
                        platform: .iOS
                    ),
                    WhatsNewFeature(
                        id: "ios-find-bar-fix",
                        symbol: "magnifyingglass.circle.fill",
                        tint: .teal,
                        title: String(localized: "Reliable Terminal Find Bar"),
                        description: String(localized: "Find in SSH terminals now toggles cleanly and includes a dedicated glass close button that dismisses search and the keyboard immediately."),
                        platform: .iOS
                    ),
                    WhatsNewFeature(
                        id: "ai-assistant",
                        symbol: "sparkles",
                        tint: .indigo,
                        title: String(localized: "Redesigned AI Assistant & Copilot"),
                        description: String(localized: "FlowDown-style streaming Markdown, folded Activity Summary with live Trace inspection, inline tool approvals, and quick command injection.")
                    ),
                    WhatsNewFeature(
                        id: "security-risk",
                        symbol: "lock.shield.fill",
                        tint: .green,
                        title: String(localized: "Secret Redaction & Command Risk Grading"),
                        description: String(localized: "Automatically scrubs private keys and tokens before AI calls, grades shell command risk locally, and supports Ask/Agent modes and per-host access rules."),
                        platform: .macOS
                    ),
                    WhatsNewFeature(
                        id: "jump-socks",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: .blue,
                        title: String(localized: "Native Jump Hosts & SOCKS5 Proxies"),
                        description: String(localized: "Chain connections through multi-hop Jump Hosts with per-hop host-key checks, and launch local SOCKS5 (-D) dynamic port forwards.")
                    ),
                    WhatsNewFeature(
                        id: "l10n-mac",
                        symbol: "globe",
                        tint: .orange,
                        title: String(localized: "Complete 5-Language Localization"),
                        description: String(localized: "Full English, Simplified Chinese, Traditional Chinese, Japanese, and Korean support across the app, terminal configuration, and shared modules."),
                        platform: .macOS
                    ),
                ]
            ),
            WhatsNewRelease(
                version: "0.3.0",
                releaseNotesURL: releaseNotesURL(for: "0.3.0"),
                features: [
                    WhatsNewFeature(
                        id: "ai-assistant",
                        symbol: "sparkles",
                        tint: .indigo,
                        title: String(localized: "Redesigned AI Assistant & Copilot"),
                        description: String(localized: "FlowDown-style streaming Markdown, folded Activity Summary with live Trace inspection, inline tool approvals, and quick command injection.")
                    ),
                    WhatsNewFeature(
                        id: "security-risk",
                        symbol: "lock.shield.fill",
                        tint: .green,
                        title: String(localized: "Secret Redaction & Command Risk Grading"),
                        description: String(localized: "Automatically scrubs private keys and tokens before AI calls, grades shell command risk locally, and supports Ask/Agent modes and per-host access rules.")
                    ),
                    WhatsNewFeature(
                        id: "jump-socks",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: .blue,
                        title: String(localized: "Native Jump Hosts & SOCKS5 Proxies"),
                        description: String(localized: "Chain connections through multi-hop Jump Hosts with per-hop host-key checks, and launch local SOCKS5 (-D) dynamic port forwards.")
                    ),
                    WhatsNewFeature(
                        id: "sftp-mac",
                        symbol: "folder.badge.gearshape",
                        tint: .teal,
                        title: String(localized: "Safer SFTP, Session sudo & External Editors"),
                        description: String(localized: "Atomic writes with edit conflict detection, on-demand sudo SFTP, open remote folders in VS Code/Cursor/Zed, plus PuTTY .ppk and multi-client host import."),
                        platform: .macOS
                    ),
                    WhatsNewFeature(
                        id: "sftp-ios",
                        symbol: "folder.badge.gearshape",
                        tint: .teal,
                        title: String(localized: "Safer SFTP, Session sudo & .ppk Import"),
                        description: String(localized: "Atomic writes with edit conflict detection, session-only sudo for remote files, automatic PuTTY .ppk key conversion, and terminal folder sync."),
                        platform: .iOS
                    ),
                    WhatsNewFeature(
                        id: "l10n-ios",
                        symbol: "globe",
                        tint: .orange,
                        title: String(localized: "5 Languages & Upgraded Live Activities"),
                        description: String(localized: "Full English, Simplified/Traditional Chinese, Japanese, and Korean localization, plus Dynamic Island, Lock Screen, and StandBy session status."),
                        platform: .iOS
                    ),
                    WhatsNewFeature(
                        id: "l10n-mac",
                        symbol: "globe",
                        tint: .orange,
                        title: String(localized: "Complete 5-Language Localization"),
                        description: String(localized: "Full English, Simplified Chinese, Traditional Chinese, Japanese, and Korean support across the app, terminal configuration, and shared modules."),
                        platform: .macOS
                    ),
                ]
            ),
        ]
    }
}

/// Tracks which version's What's New sheet has been shown on this device.
/// Stored in local `UserDefaults` (never synced via iCloud) so each Mac,
/// iPhone, and iPad introduces updates independently.
public enum WhatsNewStore {
    public static let lastSeenVersionKey = "sb.moe.tamio.lastSeenWhatsNewVersion"

    public static var lastSeenVersion: String? {
        UserDefaults.standard.string(forKey: lastSeenVersionKey)
    }

    public static func shouldPresent(for version: String = WhatsNewCatalog.currentAppVersion) -> Bool {
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_WHATS_NEW"] != nil {
                return true
            }
        #endif
        guard !version.isEmpty else { return false }
        return lastSeenVersion != version
    }

    public static func markSeen(version: String = WhatsNewCatalog.currentAppVersion) {
        guard !version.isEmpty else { return }
        UserDefaults.standard.set(version, forKey: lastSeenVersionKey)
    }
}

// MARK: - Apple-Native What's New Sheet

public struct WhatsNewSheet<Icon: View>: View {
    public let release: WhatsNewRelease
    public let showsCloseButton: Bool
    public let onContinue: () -> Void
    private let icon: () -> Icon

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    public init(
        release: WhatsNewRelease = WhatsNewCatalog.currentRelease(),
        showsCloseButton: Bool = false,
        onContinue: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.release = release
        self.showsCloseButton = showsCloseButton
        self.onContinue = onContinue
        self.icon = icon
    }

    public var body: some View {
        #if os(iOS)
            iosBody
        #else
            macOSBody
        #endif
    }

    #if os(iOS)
        private var iosBody: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 14) {
                            icon()
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 64 * 0.2237, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 64 * 0.2237, style: .continuous)
                                        .strokeBorder(
                                            Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                            lineWidth: 0.5
                                        )
                                }
                                .shadow(
                                    color: Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.14),
                                    radius: 12,
                                    x: 0,
                                    y: 5
                                )

                            Text(String(localized: "What’s New in Tamio"))
                                .font(.largeTitle.bold())
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(String(localized: "Version \(release.version)"))
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.rxAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color.rxAccentFill, in: Capsule())
                        }
                        .padding(.top, showsCloseButton ? 8 : 34)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)

                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(Array(release.platformFeatures.enumerated()), id: \.element.id) { index, feature in
                                featureRow(feature, iconFontSize: 28, iconBox: 40)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 12)
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86).delay(0.05 * Double(index + 1)),
                                        value: appeared
                                    )
                            }
                        }
                        .frame(maxWidth: 440, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .toolbar(showsCloseButton ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if showsCloseButton {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                onContinue()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.body.weight(.semibold))
                            }
                            .accessibilityLabel(String(localized: "Done"))
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    iosBottomDock
                }
                .onAppear { triggerAppearance() }
            }
        }

        private var iosBottomDock: some View {
            VStack(spacing: 12) {
                Link(destination: release.releaseNotesURL) {
                    HStack(spacing: 4) {
                        Text(String(localized: "View Full Release Notes"))
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.rxAccent)
                }

                iosContinueButton
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider().opacity(0.45)
            }
        }

        @ViewBuilder
        private var iosContinueButton: some View {
            let label = Text(String(localized: "Continue"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 34)

            if #available(iOS 26.0, *) {
                Button(action: onContinue) {
                    label
                }
                .buttonStyle(.glassProminent)
                .tint(Color.rxAccentSolid)
            } else {
                Button(action: onContinue) {
                    label
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.rxAccentSolid)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    #else
        private var macOSBody: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 10) {
                            icon()
                                .frame(width: 56, height: 56)

                            Text(String(localized: "What’s New in Tamio"))
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.rxInk)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(String(localized: "Version \(release.version)"))
                                .font(.rxCaption.monospacedDigit())
                                .foregroundStyle(.rxAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Color.rxAccentFill, in: Capsule())
                        }
                        .padding(.top, 28)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 6)

                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(release.platformFeatures.enumerated()), id: \.element.id) { index, feature in
                                featureRow(feature, iconFontSize: 24, iconBox: 36)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 10)
                                    .animation(
                                        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86).delay(0.05 * Double(index + 1)),
                                        value: appeared
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                    }
                    .padding(.bottom, 24)
                }

                Hairline()

                HStack(spacing: RX.Space.s3) {
                    Link(destination: release.releaseNotesURL) {
                        HStack(spacing: 4) {
                            Text(String(localized: "View Full Release Notes"))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.rxBody)
                        .foregroundStyle(.rxAccent)
                    }

                    Spacer()

                    Button(String(localized: "Continue"), action: onContinue)
                        .buttonStyle(.rxPrimary)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(width: 480, height: 580)
            .onExitCommand {
                onContinue()
            }
            .onAppear { triggerAppearance() }
        }
    #endif

    private func featureRow(_ feature: WhatsNewFeature, iconFontSize: CGFloat, iconBox: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: feature.symbol)
                .font(.system(size: iconFontSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(feature.tint)
                .frame(width: iconBox, height: iconBox, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    #if os(iOS)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    #else
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.rxInk)
                    #endif
                    .fixedSize(horizontal: false, vertical: true)

                Text(feature.description)
                    #if os(iOS)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    #else
                        .font(.system(size: 12.5))
                        .foregroundStyle(.rxInkSecondary)
                    #endif
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggerAppearance() {
        guard !appeared else { return }
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                appeared = true
            }
        }
    }
}

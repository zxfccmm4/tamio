//
//  AgreementView.swift
//  TamioMobile
//
//  Apple-native License Agreement sheet centered around the full, expanded EULA:
//  - Compact branded TamioLogo header so the agreement starts immediately above the fold
//  - Full EULA parsed from the bundled resource and reflowed into clean paragraphs
//    (eliminating jagged 80-column line breaks while preserving every legal term)
//  - Distinct visual cards for MIT License / Copyright and Disclaimer / SSH Risk Notice
//  - Sticky frosted action dock with haptic confirmation
//

import SwiftUI
import TamioModule

struct AgreementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var document = ParsedEULA.empty

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compactHeader
                        .padding(.top, 10)

                    if document.isLoaded {
                        if !document.copyrightLines.isEmpty || !document.licenseParagraphs.isEmpty {
                            licenseCard
                        }

                        if !document.disclaimerParagraphs.isEmpty {
                            disclaimerCard
                        }

                        if !document.riskParagraphs.isEmpty {
                            sshRiskCard
                        }

                        if let closing = document.closingNote {
                            Text(closing)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 2)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .appleGroupedBackground()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                bottomActionDock
            }
            .task {
                if !document.isLoaded {
                    let raw = await LicenseTextView.load(resource: "EULA")
                    document = ParsedEULA.parse(raw)
                }
            }
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                        appeared = true
                    }
                }
            }
        }
    }

    // MARK: - Compact Branded Header

    private var compactHeader: some View {
        let iconSize: CGFloat = 52
        let cornerRadius = iconSize * 0.2237

        return HStack(spacing: 14) {
            Image("TamioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            lineWidth: 0.5
                        )
                }
                .shadow(
                    color: Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14),
                    radius: 10,
                    x: 0,
                    y: 4
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("License Agreement")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text("End User License Agreement")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Text("v\(shortVersion)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
    }

    // MARK: - Section 1: MIT License & Copyright

    private var licenseCard: some View {
        agreementCard(
            icon: "doc.text.fill",
            tint: .blue,
            title: "MIT License & Copyright"
        ) {
            if !document.copyrightLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(document.copyrightLines, id: \.self) { line in
                        Text(line)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            ForEach(document.licenseParagraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Section 2: Warranty Disclaimer

    private var disclaimerCard: some View {
        agreementCard(
            icon: "exclamationmark.shield.fill",
            tint: .orange,
            title: "Warranty Disclaimer"
        ) {
            ForEach(document.disclaimerParagraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Section 3: SSH Host Risk Notice

    private var sshRiskCard: some View {
        agreementCard(
            icon: "server.rack",
            tint: .indigo,
            title: "SSH Connection & Host Risk Notice"
        ) {
            ForEach(document.riskParagraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Shared Card Chrome

    private func agreementCard<Content: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppleFeatureBadge(systemImage: icon, tint: tint, size: 30)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    // MARK: - Sticky Bottom Action Dock

    private var bottomActionDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("By continuing, you agree to the terms of the License Agreement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                HapticsPreference.impact()
                TamioStore.shared.licenseAgreed = true
                dismiss()
            } label: {
                Text("Agree & Continue")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .appleProminentButton()
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - EULA Parser (Reflows Hard-Wrapped Text into Clean Readable Sections)

private struct ParsedEULA {
    let isLoaded: Bool
    let copyrightLines: [String]
    let licenseParagraphs: [String]
    let disclaimerParagraphs: [String]
    let riskParagraphs: [String]
    let closingNote: String?

    static let empty = ParsedEULA(
        isLoaded: false,
        copyrightLines: [],
        licenseParagraphs: [],
        disclaimerParagraphs: [],
        riskParagraphs: [],
        closingNote: nil
    )

    static func parse(_ raw: String) -> ParsedEULA {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Split major sections separated by `====...` lines
        let majorBlocks = normalized
            .components(separatedBy: "\n")
            .reduce(into: [[String]]()) { groups, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 8 && trimmed.allSatisfy({ $0 == "=" || $0 == "-" }) {
                    groups.append([])
                } else {
                    if groups.isEmpty { groups.append([]) }
                    groups[groups.count - 1].append(line)
                }
            }
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !majorBlocks.isEmpty else {
            return ParsedEULA(
                isLoaded: true,
                copyrightLines: [],
                licenseParagraphs: [raw.trimmingCharacters(in: .whitespacesAndNewlines)],
                disclaimerParagraphs: [],
                riskParagraphs: [],
                closingNote: nil
            )
        }

        var copyrightLines: [String] = []
        var licenseParagraphs: [String] = []
        var disclaimerParagraphs: [String] = []
        var riskParagraphs: [String] = []
        var closingNote: String?

        // First block: MIT license & warranty disclaimer
        let firstParagraphs = splitParagraphs(majorBlocks[0])
        for block in firstParagraphs {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // Skip header boilerplate ("Tamio Application", "Please scroll down...")
            if lines.count == 1,
               lines[0].caseInsensitiveCompare("Tamio Application") == .orderedSame
               || lines[0].lowercased().hasPrefix("please scroll down")
            {
                continue
            }

            if lines.allSatisfy({ $0.lowercased().hasPrefix("copyright ") }) {
                copyrightLines.append(contentsOf: lines)
            } else {
                let reflowed = lines.joined(separator: " ")
                if reflowed.hasPrefix("THE SOFTWARE IS PROVIDED") {
                    disclaimerParagraphs.append(reflowed)
                } else {
                    licenseParagraphs.append(reflowed)
                }
            }
        }

        // Second block (if present): SSH host risk notice
        if majorBlocks.count >= 2 {
            riskParagraphs = splitParagraphs(majorBlocks[1]).map(reflow)
        }

        // Third+ block (if present): closing reiteration
        if majorBlocks.count >= 3 {
            let trailing = majorBlocks.dropFirst(2)
                .flatMap { splitParagraphs($0).map(reflow) }
                .joined(separator: " ")
            if !trailing.isEmpty {
                closingNote = trailing
            }
        }

        return ParsedEULA(
            isLoaded: true,
            copyrightLines: copyrightLines,
            licenseParagraphs: licenseParagraphs,
            disclaimerParagraphs: disclaimerParagraphs,
            riskParagraphs: riskParagraphs,
            closingNote: closingNote
        )
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func reflow(_ paragraph: String) -> String {
        paragraph
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

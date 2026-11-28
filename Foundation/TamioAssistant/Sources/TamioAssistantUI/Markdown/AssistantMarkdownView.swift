//
//  AssistantMarkdownView.swift
//  TamioAssistantUI
//
//  Cross-platform wrapper around `Lakr233/MarkdownView`'s `MarkdownStreamView`
//  (NSView on macOS, UIView on iOS) with FlowDown typography tuning, streaming
//  fade-in, macOS tiled drawing for long outputs, and SSH/Snippet actions in
//  code block headers via `CodeBlockActionProvider`.
//

import Foundation
import MarkdownParser
import MarkdownView
import SwiftUI
import TamioDesign

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Code Block Actions

public struct AssistantMarkdownCodeActions: Sendable {
    public var onInsertShellCommand: (@MainActor @Sendable (String) -> Void)?
    public var onRunShellCommand: (@MainActor @Sendable (String) -> Void)?
    public var onSaveSnippet: (@MainActor @Sendable (String, String?) -> Void)?

    public init(
        onInsertShellCommand: (@MainActor @Sendable (String) -> Void)? = nil,
        onRunShellCommand: (@MainActor @Sendable (String) -> Void)? = nil,
        onSaveSnippet: (@MainActor @Sendable (String, String?) -> Void)? = nil
    ) {
        self.onInsertShellCommand = onInsertShellCommand
        self.onRunShellCommand = onRunShellCommand
        self.onSaveSnippet = onSaveSnippet
    }

    public static let none = AssistantMarkdownCodeActions()

    public var hasAnyAction: Bool {
        onInsertShellCommand != nil || onRunShellCommand != nil || onSaveSnippet != nil
    }

    public static func isShellLanguage(_ language: String?) -> Bool {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return true }
        let token = raw.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," }).first.map(String.init) ?? raw
        return ["sh", "bash", "zsh", "shell", "console", "fish", "ash", "dash", "ksh", "posix", "terminal"].contains(token)
    }
}

@MainActor
final class AssistantCodeBlockActionAdapter: CodeBlockActionProvider {
    var actions: AssistantMarkdownCodeActions

    init(actions: AssistantMarkdownCodeActions) {
        self.actions = actions
    }

    func codeBlockActions(forLanguage language: String?) -> [CodeBlockAction] {
        var buttons: [CodeBlockAction] = []
        if AssistantMarkdownCodeActions.isShellLanguage(language) {
            if let insert = actions.onInsertShellCommand {
                buttons.append(
                    CodeBlockAction(
                        title: String(localized: "Insert into Terminal"),
                        systemImage: "text.insert"
                    ) { block in
                        let cleaned = Self.stripPromptPrefixes(block.content)
                        guard !cleaned.isEmpty else { return }
                        insert(cleaned)
                    }
                )
            }
            if let run = actions.onRunShellCommand {
                buttons.append(
                    CodeBlockAction(
                        title: String(localized: "Run in SSH"),
                        systemImage: "play.fill"
                    ) { block in
                        let cleaned = Self.stripPromptPrefixes(block.content)
                        guard !cleaned.isEmpty else { return }
                        run(cleaned)
                    }
                )
            }
        }
        if let save = actions.onSaveSnippet {
            buttons.append(
                CodeBlockAction(
                    title: String(localized: "Save as Snippet"),
                    systemImage: "plus.square.on.square"
                ) { block in
                    let trimmed = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    save(trimmed, block.language)
                }
            )
        }
        return buttons
    }

    /// Strips leading interactive shell prompts (`$ ` or `# `) when every non-empty
    /// line starts with one, so copied examples run cleanly in SSH.
    private static func stripPromptPrefixes(_ raw: String) -> String {
        let lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return "" }
        let allPrompted = nonEmpty.allSatisfy { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("$ ") || t.hasPrefix("# ")
        }
        if allPrompted {
            return lines.map { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("$ ") || t.hasPrefix("# ") {
                    return String(t.dropFirst(2))
                }
                return line
            }.joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Theme Builder (FlowDown ChatMarkdownView Proportions)

public enum AssistantMarkdownTheme {
    @MainActor
    public static func make(compact: Bool, colorScheme: ColorScheme) -> MarkdownTheme {
        var theme = MarkdownTheme()
        let isDark = colorScheme == .dark

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let bodySize: CGFloat = compact ? 12.5 : 13.5
        theme.align(to: bodySize)
        theme.fonts.largeTitle = NSFont.systemFont(ofSize: bodySize + 3.5, weight: .bold)
        theme.fonts.title = NSFont.systemFont(ofSize: bodySize + 1.5, weight: .semibold)
        theme.fonts.code = NSFont.monospacedSystemFont(ofSize: compact ? 11.5 : 12.0, weight: .regular)
        theme.fonts.codeInline = NSFont.monospacedSystemFont(ofSize: bodySize - 0.5, weight: .regular)

        let accent = isDark
            ? NSColor(srgbRed: 0.52, green: 0.51, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.29, green: 0.29, blue: 0.78, alpha: 1.0)
        theme.colors.body = NSColor.labelColor
        theme.colors.highlight = accent
        theme.colors.emphasis = accent
        theme.colors.selectionBackground = accent.withAlphaComponent(0.22)
        theme.colors.code = NSColor.labelColor
        theme.colors.codeBackground = isDark
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.055)
        theme.colors.codeBlockBackground = isDark
            ? NSColor.white.withAlphaComponent(0.075)
            : NSColor.black.withAlphaComponent(0.04)
        theme.colors.codeBlockBarBackground = isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.035)
        theme.table.headerBackgroundColor = isDark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.045)
        #elseif canImport(UIKit)
        let preferred = UIFont.preferredFont(forTextStyle: compact ? .subheadline : .body).pointSize
        let bodySize = compact ? min(preferred, 14.5) : preferred
        theme.align(to: bodySize)
        theme.fonts.largeTitle = UIFont.systemFont(ofSize: bodySize + 3.5, weight: .bold)
        theme.fonts.title = UIFont.systemFont(ofSize: bodySize + 1.5, weight: .semibold)
        theme.fonts.code = UIFont.monospacedSystemFont(ofSize: max(11.5, bodySize * 0.85), weight: .regular)
        theme.fonts.codeInline = UIFont.monospacedSystemFont(ofSize: max(12.0, bodySize * 0.92), weight: .regular)

        let accent = isDark
            ? UIColor(red: 0.52, green: 0.51, blue: 1.0, alpha: 1.0)
            : UIColor(red: 0.29, green: 0.29, blue: 0.78, alpha: 1.0)
        theme.colors.body = UIColor.label
        theme.colors.highlight = accent
        theme.colors.emphasis = accent
        theme.colors.selectionBackground = accent.withAlphaComponent(0.22)
        theme.colors.code = UIColor.label
        theme.colors.codeBackground = isDark
            ? UIColor.white.withAlphaComponent(0.11)
            : UIColor.black.withAlphaComponent(0.055)
        theme.colors.codeBlockBackground = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.04)
        theme.colors.codeBlockBarBackground = isDark
            ? UIColor.white.withAlphaComponent(0.065)
            : UIColor.black.withAlphaComponent(0.035)
        theme.table.headerBackgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.secondarySystemBackground
        #endif

        // FlowDown ChatMarkdownView breathing room: comfortable paragraph gaps, tight list items.
        theme.spacings.paragraph = compact ? 10 : 14
        theme.spacings.headingBefore = compact ? 10 : 14
        theme.spacings.list = compact ? 4 : 5
        theme.spacings.general = compact ? 6 : 8
        theme.spacings.final = 0
        theme.table.cornerRadius = 8
        return theme
    }
}

// MARK: - Completed Content Cache

@MainActor
private final class AssistantMarkdownContentCache {
    static let shared = AssistantMarkdownContentCache()

    private struct Key: Hashable {
        let text: String
        let compact: Bool
        let isDark: Bool
    }

    private var storage: [Key: MarkdownContent] = [:]
    private var order: [Key] = []
    private let limit = 160

    func content(for text: String, compact: Bool, colorScheme: ColorScheme, theme: MarkdownTheme) -> MarkdownContent {
        let key = Key(text: text, compact: compact, isDark: colorScheme == .dark)
        if let hit = storage[key] {
            return hit
        }
        let built = MarkdownContent(markdown: text, theme: theme, isStreaming: false)
        storage[key] = built
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        return built
    }
}

// MARK: - SwiftUI Entry Point

public struct AssistantMarkdownView: View {
    public let text: String
    public let streamIdentity: AnyHashable
    public let isStreaming: Bool
    public let compact: Bool
    public let codeActions: AssistantMarkdownCodeActions

    @Environment(\.colorScheme) private var colorScheme

    public init(
        text: String,
        streamIdentity: AnyHashable = "markdown",
        isStreaming: Bool = false,
        compact: Bool = false,
        codeActions: AssistantMarkdownCodeActions = .none
    ) {
        self.text = text
        self.streamIdentity = streamIdentity
        self.isStreaming = isStreaming
        self.compact = compact
        self.codeActions = codeActions
    }

    public var body: some View {
        let theme = AssistantMarkdownTheme.make(compact: compact, colorScheme: colorScheme)
        AssistantMarkdownRepresentable(
            text: text,
            streamIdentity: streamIdentity,
            isStreaming: isStreaming,
            compact: compact,
            colorScheme: colorScheme,
            theme: theme,
            codeActions: codeActions
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Platform Representable Coordinator

@MainActor
final class AssistantMarkdownCoordinator {
    var actionAdapter = AssistantCodeBlockActionAdapter(actions: .none)
    var lastIdentity: AnyHashable?
    var lastText: String = ""
    var lastIsStreaming: Bool = false
    var lastTheme: MarkdownTheme?
    var lastParsedText: String = ""
    var lastParseResult: MarkdownParser.ParseResult?
    var cachedWidth: CGFloat = 0

    func configure(_ view: MarkdownStreamView, theme: MarkdownTheme, codeActions: AssistantMarkdownCodeActions) {
        view.theme = theme
        view.contextViewFadeDuration = 0.35
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        #if canImport(UIKit)
        view.textLabelView.tiledDrawing = .init()
        #endif

        actionAdapter.actions = codeActions
        view.codeBlockActionProvider = codeActions.hasAnyAction ? actionAdapter : nil
        view.linkHandler = { payload, _, _ in
            let url: URL?
            switch payload {
            case .url(let u): url = u
            case .string(let s): url = URL(string: s)
            }
            guard let url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { return }
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        }
    }

    func update(
        _ view: MarkdownStreamView,
        text: String,
        identity: AnyHashable,
        isStreaming: Bool,
        compact: Bool,
        colorScheme: ColorScheme,
        theme: MarkdownTheme,
        codeActions: AssistantMarkdownCodeActions
    ) {
        actionAdapter.actions = codeActions
        let desiredProvider: CodeBlockActionProvider? = codeActions.hasAnyAction ? actionAdapter : nil
        if view.codeBlockActionProvider !== desiredProvider {
            view.codeBlockActionProvider = desiredProvider
        }

        let identityChanged = lastIdentity != identity
        if identityChanged {
            view.streamIdentity = identity
        }
        view.isStreaming = isStreaming

        let themeChanged = lastTheme != theme
        let textChanged = lastText != text
        let streamingChanged = lastIsStreaming != isStreaming
        guard identityChanged || themeChanged || textChanged || streamingChanged else { return }

        lastIdentity = identity
        lastText = text
        lastIsStreaming = isStreaming

        if !isStreaming {
            let content = AssistantMarkdownContentCache.shared.content(
                for: text,
                compact: compact,
                colorScheme: colorScheme,
                theme: theme
            )
            lastParsedText = text
            lastParseResult = nil
            lastTheme = theme
            view.setContentImmediately(content, theme: theme)
            return
        }

        let parsedText = MarkdownParser.StreamingTail(closing: text).applied(to: text)
        let reuseParse = !identityChanged && lastParsedText == parsedText ? lastParseResult : nil
        if reuseParse != nil, !themeChanged, !streamingChanged {
            return
        }
        let result = reuseParse ?? MarkdownParser().parse(parsedText)
        let content = MarkdownContent(parserResult: result, theme: theme)
        lastParsedText = parsedText
        lastParseResult = result

        if !identityChanged, !themeChanged, lastTheme != nil {
            view.setContent(content)
        } else {
            view.setContentImmediately(content, theme: theme)
        }
        lastTheme = theme
    }

    func sizeThatFits(_ proposal: ProposedViewSize, for view: MarkdownStreamView) -> CGSize? {
        if proposal.width == 0 {
            return .zero
        }
        let fittingWidth: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            fittingWidth = proposed
            cachedWidth = proposed
        } else if cachedWidth > 0 {
            fittingWidth = cachedWidth
        } else if view.bounds.width > 0 {
            fittingWidth = view.bounds.width
        } else {
            return nil
        }
        let size = view.boundingSize(for: fittingWidth)
        return CGSize(width: fittingWidth, height: ceil(size.height))
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private struct AssistantMarkdownRepresentable: NSViewRepresentable {
    let text: String
    let streamIdentity: AnyHashable
    let isStreaming: Bool
    let compact: Bool
    let colorScheme: ColorScheme
    let theme: MarkdownTheme
    let codeActions: AssistantMarkdownCodeActions

    func makeCoordinator() -> AssistantMarkdownCoordinator {
        AssistantMarkdownCoordinator()
    }

    func makeNSView(context: Context) -> MarkdownStreamView {
        let view = MarkdownStreamView()
        context.coordinator.configure(view, theme: theme, codeActions: codeActions)
        return view
    }

    func updateNSView(_ nsView: MarkdownStreamView, context: Context) {
        context.coordinator.update(
            nsView,
            text: text,
            identity: streamIdentity,
            isStreaming: isStreaming,
            compact: compact,
            colorScheme: colorScheme,
            theme: theme,
            codeActions: codeActions
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownStreamView, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(proposal, for: nsView)
    }
}
#elseif canImport(UIKit)
private struct AssistantMarkdownRepresentable: UIViewRepresentable {
    let text: String
    let streamIdentity: AnyHashable
    let isStreaming: Bool
    let compact: Bool
    let colorScheme: ColorScheme
    let theme: MarkdownTheme
    let codeActions: AssistantMarkdownCodeActions

    func makeCoordinator() -> AssistantMarkdownCoordinator {
        AssistantMarkdownCoordinator()
    }

    func makeUIView(context: Context) -> MarkdownStreamView {
        let view = MarkdownStreamView()
        context.coordinator.configure(view, theme: theme, codeActions: codeActions)
        return view
    }

    func updateUIView(_ uiView: MarkdownStreamView, context: Context) {
        context.coordinator.update(
            uiView,
            text: text,
            identity: streamIdentity,
            isStreaming: isStreaming,
            compact: compact,
            colorScheme: colorScheme,
            theme: theme,
            codeActions: codeActions
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownStreamView, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(proposal, for: uiView)
    }
}
#endif

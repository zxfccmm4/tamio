//
//  QuickSettingBarView.swift
//  TamioAssistantUI
//
//  FlowDown `QuickSettingBar` + animated Send/Stop morphing button:
//  - Attachment `+` trigger (file picker / terminal snapshot)
//  - Tools dropdown menu (master on/off, Ask vs Agent mode, capability
//    group checkboxes, and FlowDown Inline Activity Steps toggle)
//  - Optional Target Server Scope pill & Ops Skills pill
//  - Animated Send / Stop button
//

import SwiftUI
import TamioAssistant

public struct AssistantSendStopButton: View {
    public let isStreaming: Bool
    public let canSend: Bool
    public let compact: Bool
    public let onSend: () -> Void
    public let onStop: () -> Void

    @State private var pulsing = false

    public init(
        isStreaming: Bool,
        canSend: Bool,
        compact: Bool = false,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isStreaming = isStreaming
        self.canSend = canSend
        self.compact = compact
        self.onSend = onSend
        self.onStop = onStop
    }

    private var diameter: CGFloat { compact ? 28 : 32 }

    public var body: some View {
        Button {
            if isStreaming {
                onStop()
            } else if canSend {
                onSend()
            }
        } label: {
            ZStack {
                if isStreaming {
                    Circle()
                        .stroke(Color.red.opacity(0.32), lineWidth: 2)
                        .frame(width: diameter + 4, height: diameter + 4)
                        .scaleEffect(pulsing ? 1.12 : 0.96)
                        .opacity(pulsing ? 0.35 : 0.9)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                                pulsing = true
                            }
                        }
                        .onDisappear { pulsing = false }
                }

                Circle()
                    .fill(isStreaming ? Color.red : (canSend ? Color.accentColor : Color.primary.opacity(0.08)))
                    .frame(width: diameter, height: diameter)

                if isStreaming {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: compact ? 9 : 10, height: compact ? 9 : 10)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: compact ? 12 : 13.5, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: diameter + 4, height: diameter + 4)
            .animation(.snappy(duration: 0.2), value: isStreaming)
            .animation(.snappy(duration: 0.16), value: canSend)
        }
        .buttonStyle(.plain)
        .disabled(!isStreaming && !canSend)
        .accessibilityLabel(isStreaming ? String(localized: "Stop Generating") : String(localized: "Send Message"))
    }
}

public struct QuickSettingBarView: View {
    public let assistant: ServerAssistant
    public let conversationID: UUID
    public let isStreaming: Bool
    public let canSend: Bool
    public let compact: Bool
    public let scopeLabel: String?
    public let isScopeFiltered: Bool
    public let onTapScope: (() -> Void)?
    public let onTapSkills: (() -> Void)?
    public let onAttachFile: (() -> Void)?
    public let onAttachTerminalSnapshot: (() -> Void)?
    public let showDismissKeyboard: Bool
    public let onDismissKeyboard: (() -> Void)?
    public let onSend: () -> Void
    public let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        assistant: ServerAssistant,
        conversationID: UUID,
        isStreaming: Bool,
        canSend: Bool,
        compact: Bool = false,
        scopeLabel: String? = nil,
        isScopeFiltered: Bool = false,
        onTapScope: (() -> Void)? = nil,
        onTapSkills: (() -> Void)? = nil,
        onAttachFile: (() -> Void)? = nil,
        onAttachTerminalSnapshot: (() -> Void)? = nil,
        showDismissKeyboard: Bool = false,
        onDismissKeyboard: (() -> Void)? = nil,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.assistant = assistant
        self.conversationID = conversationID
        self.isStreaming = isStreaming
        self.canSend = canSend
        self.compact = compact
        self.scopeLabel = scopeLabel
        self.isScopeFiltered = isScopeFiltered
        self.onTapScope = onTapScope
        self.onTapSkills = onTapSkills
        self.onAttachFile = onAttachFile
        self.onAttachTerminalSnapshot = onAttachTerminalSnapshot
        self.showDismissKeyboard = showDismissKeyboard
        self.onDismissKeyboard = onDismissKeyboard
        self.onSend = onSend
        self.onStop = onStop
    }

    private var toolsOn: Bool {
        assistant.toolsEnabled(for: conversationID) && !assistant.enabledToolGroups.isEmpty
    }

    private var interactionMode: AssistantInteractionMode {
        assistant.interactionMode(for: conversationID)
    }

    private var pillBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055)
    }

    public var body: some View {
        HStack(spacing: compact ? 6 : 7) {
            // Attachment (+) menu / button
            if onAttachFile != nil || onAttachTerminalSnapshot != nil {
                if let onAttachFile, let onAttachTerminalSnapshot {
                    Menu {
                        Button(action: onAttachTerminalSnapshot) {
                            Label(String(localized: "Attach Terminal Snapshot"), systemImage: "terminal")
                        }
                        Button(action: onAttachFile) {
                            Label(String(localized: "Attach File or Image…"), systemImage: "paperclip")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: compact ? 25 : 28, height: compact ? 25 : 28)
                            .background(pillBackground, in: Circle())
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    #endif
                    .accessibilityLabel(String(localized: "Add Attachment"))
                } else if let onAttachFile {
                    Button(action: onAttachFile) {
                        Image(systemName: "plus")
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: compact ? 25 : 28, height: compact ? 25 : 28)
                            .background(pillBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Attach File"))
                } else if let onAttachTerminalSnapshot {
                    Button(action: onAttachTerminalSnapshot) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: compact ? 25 : 28, height: compact ? 25 : 28)
                            .background(pillBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Attach Terminal Snapshot"))
                    .accessibilityLabel(String(localized: "Attach Terminal Snapshot"))
                }
            }

            // FlowDown Tools & Mode Menu Pill
            Menu {
                Section(String(localized: "Mode")) {
                    Button {
                        assistant.setInteractionMode(.agent, for: conversationID)
                    } label: {
                        Label(
                            String(localized: "Agent (Tools & Commands)"),
                            systemImage: interactionMode == .agent ? "checkmark" : "bolt.shield"
                        )
                    }
                    Button {
                        assistant.setInteractionMode(.ask, for: conversationID)
                    } label: {
                        Label(
                            String(localized: "Ask (Read-Only)"),
                            systemImage: interactionMode == .ask ? "checkmark" : "bubble.left"
                        )
                    }
                }

                if interactionMode == .agent {
                    Section(String(localized: "Tools")) {
                        Button {
                            assistant.setToolsEnabled(!assistant.toolsEnabled(for: conversationID), for: conversationID)
                        } label: {
                            Label(
                                assistant.toolsEnabled(for: conversationID)
                                    ? String(localized: "Disable All Tools")
                                    : String(localized: "Enable Tools"),
                                systemImage: assistant.toolsEnabled(for: conversationID) ? "checkmark.circle.fill" : "circle"
                            )
                        }

                        ForEach(AssistantToolGroup.allCases, id: \.self) { group in
                            let enabled = assistant.enabledToolGroups.contains(group)
                            Button {
                                assistant.toggleToolGroup(group, in: conversationID)
                            } label: {
                                Label(
                                    group.displayName,
                                    systemImage: enabled ? "checkmark" : group.systemImage
                                )
                            }
                        }
                    }
                }

                Divider()

                Button {
                    assistant.inlineActivityStepsEnabled.toggle()
                } label: {
                    Label(
                        String(localized: "Show Activity Steps Inline"),
                        systemImage: assistant.inlineActivityStepsEnabled ? "checkmark" : "list.bullet.indent"
                    )
                }
            } label: {
                let activeTools = interactionMode == .agent && toolsOn
                HStack(spacing: 4) {
                    Image(systemName: interactionMode == .ask ? "bubble.left" : "wrench.and.screwdriver")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    Text(
                        interactionMode == .ask
                            ? String(localized: "Ask")
                            : (activeTools
                                ? String(localized: "Tools (\(assistant.enabledToolGroups.count))")
                                : String(localized: "Tools Off"))
                    )
                    .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(activeTools ? Color.accentColor : .secondary)
                .padding(.horizontal, compact ? 8 : 9)
                .padding(.vertical, compact ? 5 : 6)
                .background(activeTools ? Color.accentColor.opacity(0.14) : pillBackground, in: Capsule())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif

            // Target Server Scope Pill
            if let onTapScope, let scopeLabel {
                Button(action: onTapScope) {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        Text(scopeLabel)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(isScopeFiltered ? Color.accentColor : .secondary)
                    .padding(.horizontal, compact ? 8 : 9)
                    .padding(.vertical, compact ? 5 : 6)
                    .background(isScopeFiltered ? Color.accentColor.opacity(0.14) : pillBackground, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Pinned Ops Skills Pill
            if let onTapSkills {
                let pinnedCount = assistant.pinnedSkillIDs.count
                Button(action: onTapSkills) {
                    HStack(spacing: 4) {
                        Image(systemName: pinnedCount > 0 ? "wand.and.stars.inverse" : "wand.and.stars")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        if pinnedCount > 0 {
                            Text("\(pinnedCount)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(pinnedCount > 0 ? Color.accentColor : .secondary)
                    .padding(.horizontal, compact ? 8 : 9)
                    .padding(.vertical, compact ? 5 : 6)
                    .background(pinnedCount > 0 ? Color.accentColor.opacity(0.14) : pillBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Ops Skills"))
            }

            if showDismissKeyboard, let onDismissKeyboard {
                Button(action: onDismissKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(pillBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Hide Keyboard"))
            }

            Spacer(minLength: 4)

            AssistantSendStopButton(
                isStreaming: isStreaming,
                canSend: canSend,
                compact: compact,
                onSend: onSend,
                onStop: onStop
            )
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.bottom, compact ? 8 : 9)
    }
}

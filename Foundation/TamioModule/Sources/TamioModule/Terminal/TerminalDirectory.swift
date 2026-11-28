//
//  TerminalDirectory.swift
//  TamioModule
//
//  Two-way folder synchronization between SSH terminals and Files (SFTP):
//  - Terminal → Files: shells report their folder with OSC 7 at each prompt.
//  - Files → Terminal (opt-in, default off): shells also emit OSC 133 prompt
//    readiness markers so Files only injects ` cd '...'` when the terminal is
//    confirmed idle at an empty prompt.
//

import Combine
import Foundation

public enum FilesSyncPreference {
    public static let terminalFollowsFilesKey = "sb.moe.tamio.files.terminalFollowsFiles"

    public static var terminalFollowsFiles: Bool {
        get { UserDefaults.standard.bool(forKey: terminalFollowsFilesKey) }
        set { UserDefaults.standard.set(newValue, forKey: terminalFollowsFilesKey) }
    }
}

/// Tracks the latest folder each server's terminals reported, and dispatches
/// opt-in reverse navigation back to an idle terminal prompt.
@MainActor
public final class TerminalDirectories: ObservableObject {
    public static let shared = TerminalDirectories()

    public struct Report: Equatable, Sendable {
        public let path: String
        /// Counts the reports, so a folder reported again after a move away
        /// is a change too.
        public let serial: Int
    }

    @Published public private(set) var latest: [RDMachine.ID: Report] = [:]
    private var serial = 0

    private struct TerminalHook {
        let token: UUID
        let isIdlePrompt: () -> Bool
        let changeDirectory: (String) -> Void
    }

    private var terminalHooks: [RDMachine.ID: [TerminalHook]] = [:]

    func report(_ path: String, for machine: RDMachine.ID) {
        guard latest[machine]?.path != path else { return }
        serial += 1
        latest[machine] = Report(path: path, serial: serial)
    }

    func registerTerminal(
        token: UUID,
        for machine: RDMachine.ID,
        isIdlePrompt: @escaping () -> Bool,
        changeDirectory: @escaping (String) -> Void
    ) {
        var list = terminalHooks[machine] ?? []
        list.removeAll { $0.token == token }
        list.append(TerminalHook(token: token, isIdlePrompt: isIdlePrompt, changeDirectory: changeDirectory))
        terminalHooks[machine] = list
    }

    func unregisterTerminal(token: UUID, for machine: RDMachine.ID) {
        guard var list = terminalHooks[machine] else { return }
        list.removeAll { $0.token == token }
        terminalHooks[machine] = list.isEmpty ? nil : list
    }

    /// Invoked when the user navigates in Files (SFTP). When the opt-in
    /// "Terminal follows Files" setting is enabled, sends a history-clean `cd`
    /// to the most recently registered idle terminal for that server.
    public func notifyFilesNavigated(to path: String, on machine: RDMachine.ID) {
        guard FilesSyncPreference.terminalFollowsFiles else { return }
        guard latest[machine]?.path != path else { return }
        guard let hooks = terminalHooks[machine],
              let target = hooks.last(where: { $0.isIdlePrompt() })
        else { return }
        target.changeDirectory(path)
    }

    /// Single-quotes a POSIX path safely for `cd`, prefixing with a space so
    /// shells configured with `ignorespace`/`HIST_IGNORE_SPACE` omit it from history.
    nonisolated public static func shellChangeDirectoryCommand(for path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return " cd '\(escaped)'\r"
    }
}

/// Picks the folder a shell reports out of what it prints, across the
/// pieces the output arrives in.
struct WorkingDirectoryReader {
    private static let start = "\u{1B}]7;"
    /// Longer than any path a report would carry: past it, a report that
    /// never ended is given up.
    private static let limit = 4096
    private var pending = ""

    /// The folder last reported in `text`, if any.
    mutating func read(_ text: String) -> String? {
        let text = pending + text
        pending = ""
        var found: String?
        var rest = text[...]
        while let open = rest.range(of: Self.start) {
            let body = rest[open.upperBound...]
            // BEL ends it, or ESC \.
            guard let close = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else {
                if body.count < Self.limit { pending = String(rest[open.lowerBound...]) }
                return found
            }
            if let path = Self.path(in: String(body[..<close])) { found = path }
            rest = body[close...].dropFirst()
        }
        // The start of a report cut off at the end of this piece.
        if let escape = rest.lastIndex(of: "\u{1B}"), Self.start.hasPrefix(rest[escape...]) {
            pending = String(rest[escape...])
        }
        return found
    }

    /// The path in `file://host/path`; shells that encode it percent-encode
    /// it, and the hook Tamio types does not.
    static func path(in url: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        let afterHost = url[scheme.upperBound...]
        guard let slash = afterHost.firstIndex(of: "/") else { return nil }
        let raw = String(afterHost[slash...])
        return raw.removingPercentEncoding ?? raw
    }
}

/// Tracks OSC 133 shell-integration prompt lifecycle markers across chunked output
/// so Files only syncs back to the terminal when the prompt is ready and empty.
struct PromptStateReader {
    private static let start = "\u{1B}]133;"
    private static let limit = 64
    private var pending = ""

    /// Returns updated idle-prompt readiness when a 133 marker is seen (`true` on `B`, `false` on `C`), or nil.
    mutating func read(_ text: String) -> Bool? {
        let combined = pending + text
        pending = ""
        var state: Bool?
        var rest = combined[...]
        while let open = rest.range(of: Self.start) {
            let body = rest[open.upperBound...]
            guard let close = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else {
                if body.count < Self.limit { pending = String(rest[open.lowerBound...]) }
                return state
            }
            let code = body[..<close].first
            if code == "B" {
                state = true
            } else if code == "C" || code == "A" {
                state = false
            }
            rest = body[close...].dropFirst()
        }
        if let escape = rest.lastIndex(of: "\u{1B}"), Self.start.hasPrefix(rest[escape...]) {
            pending = String(rest[escape...])
        }
        return state
    }
}

public enum ShellIntegration {
    /// Typed once the shell is open: has bash, zsh or fish report the folder
    /// (OSC 7) and prompt readiness (OSC 133) at every prompt. It leads with a
    /// space, which keeps it out of the history where the shell is set to
    /// (bash's ignorespace, zsh's HIST_IGNORE_SPACE). It works only for the
    /// session it is typed in and writes nothing on the server.
    public static let hook = #" test -n "$FISH_VERSION" && eval 'function __tamio_cwd --on-event fish_prompt; printf "\e]7;file://%s\a\e]133;B\a" $PWD; end; function __tamio_preexec --on-event fish_preexec; printf "\e]133;C\a"; end' || eval '__tamio_cwd() { printf "\033]7;file://%s\007\033]133;B\007" "$PWD"; }; __tamio_preexec() { printf "\033]133;C\007"; }; if [ -n "$ZSH_VERSION" ]; then precmd_functions+=(__tamio_cwd); preexec_functions+=(__tamio_preexec); else PROMPT_COMMAND="__tamio_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; trap '\''case "$BASH_COMMAND" in __tamio_cwd*) ;; *) __tamio_preexec ;; esac'\'' DEBUG; fi'"#
}

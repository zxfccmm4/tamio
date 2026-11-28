//
//  ExternalEditorLauncher.swift
//  Tamio (macOS)
//
//  Opens the current remote SFTP folder in an installed external editor
//  (VS Code, VS Code Insiders, Cursor, or Zed) through the editor's SSH remote
//  URL scheme. Resolves matching ~/.ssh/config host aliases first and refuses
//  hosts backed only by a Tamio-internal jump chain that external ssh cannot use.
//

import AppKit
import Foundation
import TamioModule

enum ExternalRemoteEditor: String, CaseIterable, Identifiable, Sendable {
    case none
    case vscode
    case vscodeInsiders
    case cursor
    case zed

    static let preferenceKey = "sb.moe.tamio.files.externalEditor"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Off")
        case .vscode: "Visual Studio Code"
        case .vscodeInsiders: "VS Code Insiders"
        case .cursor: "Cursor"
        case .zed: "Zed"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: nil
        case .vscode: "com.microsoft.VSCode"
        case .vscodeInsiders: "com.microsoft.VSCodeInsiders"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        }
    }

    var isInstalled: Bool {
        guard let bundleIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static var installedOptions: [ExternalRemoteEditor] {
        allCases.filter(\.isInstalled)
    }

    static var configured: ExternalRemoteEditor {
        guard let raw = UserDefaults.standard.string(forKey: preferenceKey),
              let editor = ExternalRemoteEditor(rawValue: raw),
              editor != .none,
              editor.isInstalled
        else { return .none }
        return editor
    }
}

enum ExternalEditorLauncher {
    /// Opens `remotePath` on `machine` in `editor`. Returns an error description if refused or failed.
    @MainActor
    static func open(machine: RDMachine, remotePath: String, in editor: ExternalRemoteEditor) -> String? {
        guard editor != .none else { return nil }
        guard editor.isInstalled else {
            return String(localized: "\(editor.title) is not installed on this Mac.")
        }

        let identity = TamioStore.shared.associatedIdentity(for: machine)
        let user = machine.loginUsername(with: identity)
        let port = Int(machine.remotePort) ?? 22
        let alias = matchingSSHConfigAlias(hostName: machine.remoteAddress, user: user, port: port)

        // If the server relies on a Tamio-internal jump chain or ProxyCommand not represented
        // in ~/.ssh/config, the external editor's ssh client cannot follow it.
        if alias == nil, !machine.jumpHostIDs.isEmpty || !machine.proxyCommand.isEmpty {
            return String(localized: "\(machine.name) uses a Tamio jump host or ProxyCommand that \(editor.title)'s ssh cannot read. Add a matching Host alias in ~/.ssh/config first.")
        }

        let target: String
        if let alias {
            target = alias
        } else if port != 22 {
            target = "\(user)@\(machine.remoteAddress):\(port)"
        } else {
            target = "\(user)@\(machine.remoteAddress)"
        }

        let cleanPath = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target

        let urlString: String
        switch editor {
        case .none:
            return nil
        case .vscode:
            urlString = "vscode://vscode-remote/ssh-remote+\(encodedTarget)\(encodedPath)"
        case .vscodeInsiders:
            urlString = "vscode-insiders://vscode-remote/ssh-remote+\(encodedTarget)\(encodedPath)"
        case .cursor:
            urlString = "cursor://vscode-remote/ssh-remote+\(encodedTarget)\(encodedPath)"
        case .zed:
            urlString = "zed://ssh/\(encodedTarget)\(encodedPath)"
        }

        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            return String(localized: "Could not open \(remotePath) in \(editor.title).")
        }
        return nil
    }

    /// Scans `~/.ssh/config` for a concrete `Host` alias matching exact `(hostName, user, port)`.
    private static func matchingSSHConfigAlias(hostName: String, user: String, port: Int) -> String? {
        let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        var currentAliases: [String] = []
        var blockHostName: String?
        var blockUser: String?
        var blockPort: Int?

        func checkBlock() -> String? {
            guard !currentAliases.isEmpty else { return nil }
            let resolvedHost = blockHostName ?? currentAliases[0]
            let resolvedPort = blockPort ?? 22
            guard resolvedHost.caseInsensitiveCompare(hostName) == .orderedSame,
                  resolvedPort == port
            else { return nil }
            if let blockUser, blockUser != user { return nil }
            return currentAliases.first { !$0.contains("*") && !$0.contains("?") }
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "host":
                if let matched = checkBlock() { return matched }
                currentAliases = val.split(whereSeparator: \.isWhitespace).map(String.init)
                blockHostName = nil
                blockUser = nil
                blockPort = nil
            case "hostname":
                blockHostName = val
            case "user":
                blockUser = val
            case "port":
                blockPort = Int(val)
            default:
                break
            }
        }
        return checkBlock()
    }
}

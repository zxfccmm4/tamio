//
//  SecretRedactor.swift
//  TamioModule
//
//  Redacts credentials, private keys, tokens and secret assignments from
//  terminal output and command stdout before text is sent to an AI model or
//  recorded in activity logs. Pure Swift, shared by macOS and iOS.
//

import Foundation

public enum SecretRedactor {
    public static let enabledKey = "sb.moe.tamio.ai.redactSecrets"

    /// Default-on toggle shared across in-app AI assistants and MCP command output.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public struct Result: Equatable, Sendable {
        public let text: String
        public let redactionCount: Int

        public var didRedact: Bool { redactionCount > 0 }

        public init(text: String, redactionCount: Int) {
            self.text = text
            self.redactionCount = redactionCount
        }
    }

    /// Redacts sensitive material when the user setting is enabled (default).
    public static func redactIfEnabled(_ input: String) -> Result {
        guard isEnabled else { return Result(text: input, redactionCount: 0) }
        return redact(input)
    }

    /// Always redacts sensitive material from `input`, returning the scrubbed text
    /// and how many items were replaced.
    public static func redact(_ input: String) -> Result {
        guard !input.isEmpty else { return Result(text: input, redactionCount: 0) }
        var text = input
        var count = 0

        // 1. Complete PEM / OpenSSH private key blocks.
        count += replace(in: &text, pattern: Patterns.pemPrivateKeyBlock, with: "[REDACTED PRIVATE KEY]")

        // 2. Truncated private key blocks whose END marker was clipped by viewport/output caps.
        count += replace(in: &text, pattern: Patterns.truncatedPrivateKeyBlock, with: "[REDACTED PRIVATE KEY]")

        // 3. PuTTY PPK private key payload lines.
        count += replace(in: &text, pattern: Patterns.puttyPrivateLines, with: "Private-Lines: [REDACTED]")

        // 4. URL-embedded credentials: scheme://user:pass@host -> scheme://user:[REDACTED]@host.
        count += replaceCredentialURLs(in: &text)

        // 5. HTTP Authorization / X-Api-Key headers.
        count += replaceGroup(in: &text, pattern: Patterns.httpAuthHeader, valueGroup: 2, placeholder: "[REDACTED]")

        // 6. Well-known API / service / JWT token formats.
        count += replace(in: &text, pattern: Patterns.knownTokens, with: "[REDACTED TOKEN]")

        // 7. Shell / dotenv / INI key=value secret assignments.
        count += replaceSecretAssignments(in: &text, pattern: Patterns.shellAssignment)

        // 8. JSON / YAML key: value secret assignments.
        count += replaceSecretAssignments(in: &text, pattern: Patterns.colonAssignment)

        return Result(text: text, redactionCount: count)
    }

    // MARK: - Replacement Helpers

    private static func replace(in text: inout String, pattern: NSRegularExpression, with replacement: String) -> Int {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let mutable = NSMutableString(string: text)
        var replaced = 0
        for match in matches.reversed() {
            let existing = ns.substring(with: match.range)
            if isPlaceholder(existing) { continue }
            mutable.replaceCharacters(in: match.range, with: replacement)
            replaced += 1
        }
        text = mutable as String
        return replaced
    }

    private static func replaceCredentialURLs(in text: inout String) -> Int {
        let ns = text as NSString
        let matches = Patterns.urlCredentials.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let mutable = NSMutableString(string: text)
        var replaced = 0
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let passwordRange = match.range(at: 3)
            guard passwordRange.location != NSNotFound else { continue }
            let secret = ns.substring(with: passwordRange)
            if isPlaceholder(secret) { continue }
            mutable.replaceCharacters(in: passwordRange, with: "[REDACTED]")
            replaced += 1
        }
        text = mutable as String
        return replaced
    }

    private static func replaceGroup(
        in text: inout String,
        pattern: NSRegularExpression,
        valueGroup: Int,
        placeholder: String
    ) -> Int {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let mutable = NSMutableString(string: text)
        var replaced = 0
        for match in matches.reversed() {
            guard match.numberOfRanges > valueGroup else { continue }
            let range = match.range(at: valueGroup)
            guard range.location != NSNotFound else { continue }
            let secret = ns.substring(with: range)
            if isPlaceholder(secret) { continue }
            mutable.replaceCharacters(in: range, with: placeholder)
            replaced += 1
        }
        text = mutable as String
        return replaced
    }

    private static func replaceSecretAssignments(in text: inout String, pattern: NSRegularExpression) -> Int {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let mutable = NSMutableString(string: text)
        var replaced = 0
        for match in matches.reversed() {
            // Capture groups 3 (double-quoted), 4 (single-quoted), or 5 (bare).
            let valueRange = (3 ... 5)
                .filter { $0 < match.numberOfRanges }
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound && $0.length > 0 }
            guard let valueRange else { continue }
            let secret = ns.substring(with: valueRange)
            if isPlaceholder(secret) { continue }
            mutable.replaceCharacters(in: valueRange, with: "[REDACTED]")
            replaced += 1
        }
        text = mutable as String
        return replaced
    }

    private static func isPlaceholder(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.contains("[REDACTED") { return true }
        if trimmed.hasPrefix("$") || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) { return true }
        if trimmed.hasPrefix("{{") && trimmed.hasSuffix("}}") { return true }
        if trimmed.allSatisfy({ $0 == "*" || $0 == "•" || $0 == "x" || $0 == "X" }) { return true }
        let lower = trimmed.lowercased()
        if ["true", "false", "null", "nil", "none", "empty", "yes", "no", "undefined", "changeme", "placeholder"].contains(lower) {
            return true
        }
        return false
    }

    // MARK: - Compiled Patterns

    private enum Patterns {
        private static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }

        static let pemPrivateKeyBlock = compile(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        )

        static let truncatedPrivateKeyBlock = compile(
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:\r?\n[^\r\n]*){1,64}"#
        )

        static let puttyPrivateLines = compile(
            #"Private-Lines:\s*\d+\r?\n(?:[A-Za-z0-9+/=]{16,}\r?\n?)+"#
        )

        static let urlCredentials = compile(
            #"\b([a-zA-Z][a-zA-Z0-9+.-]{1,15}://)([^:@/\s]{1,128}):([^@/\s]{1,256})@"#
        )

        static let httpAuthHeader = compile(
            #"\b((?:Proxy-)?Authorization\s*:\s*(?:Bearer|Basic|Token|ApiKey)\s+|X-Api-Key\s*:\s*)([A-Za-z0-9._~+/=-]{8,})"#,
            options: [.caseInsensitive]
        )

        static let knownTokens = compile(
            #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|npm_[A-Za-z0-9]{20,}|pypi-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|\d{8,12}:AA[A-Za-z0-9_-]{33})\b"#
        )

        static let shellAssignment = compile(
            #"(^|[\s;,])((?:export\s+)?[A-Za-z0-9_.-]*(?:PASSWORD|PASSWD|PASSPHRASE|SECRET|API_?KEY|ACCESS_?KEY|AUTH_?TOKEN|PRIVATE_?KEY|CLIENT_?SECRET|BEARER_?TOKEN|WEBHOOK_?SECRET|SESSION_?TOKEN|REFRESH_?TOKEN|BOT_?TOKEN|TOKEN)[A-Za-z0-9_.-]*\s*=\s*)(?:"([^"\r\n]{4,})"|'([^'\r\n]{4,})'|([^\s"'#;,]{4,}))"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        )

        static let colonAssignment = compile(
            #"(^|[\s,{])(["']?[A-Za-z0-9_.-]*(?:password|passwd|passphrase|secret|api_?key|access_?key|auth_?token|private_?key|client_?secret|token)["']?\s*:\s*)(?:"([^"\r\n]{4,})"|'([^'\r\n]{4,})'|([^\s"'#,}\]]{6,}))"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        )
    }
}

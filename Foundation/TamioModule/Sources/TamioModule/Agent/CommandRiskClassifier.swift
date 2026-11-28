//
//  CommandRiskClassifier.swift
//  TamioModule
//
//  Lightweight local risk classifier for shell commands and MCP tool actions.
//  Splits chained shell pipelines and takes the highest risk level across all
//  segments so approval dialogs and in-app AI cards highlight dangerous actions.
//

import Foundation

public enum CommandRiskLevel: String, Codable, Comparable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case modify
    case destructive

    private var rank: Int {
        switch self {
        case .readOnly: 0
        case .modify: 1
        case .destructive: 2
        }
    }

    public static func < (lhs: CommandRiskLevel, rhs: CommandRiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    public var localizedLabel: String {
        switch self {
        case .readOnly: String(localized: "Read-only")
        case .modify: String(localized: "Modify")
        case .destructive: String(localized: "High Risk")
        }
    }
}

public struct CommandRiskAssessment: Equatable, Sendable {
    public let level: CommandRiskLevel
    public let reasons: [String]

    public var isDestructive: Bool { level == .destructive }

    public init(level: CommandRiskLevel, reasons: [String] = []) {
        self.level = level
        self.reasons = reasons
    }
}

public enum CommandRiskClassifier {
    /// Classifies an MCP tool invocation into readOnly / modify / destructive.
    public static func classifyTool(_ tool: String, detail: String, sudo: Bool = false) -> CommandRiskAssessment {
        if tool.hasPrefix("remove_") {
            return CommandRiskAssessment(level: .destructive, reasons: [String(localized: "Removes saved item")])
        }
        switch tool {
        case "run_command", "start_command", "run_snippet":
            return classify(command: detail, sudo: sudo)
        case "add_host", "update_host", "add_identity", "add_snippet", "update_snippet",
             "add_port_forward", "start_port_forward", "stop_port_forward", "stop_command":
            return CommandRiskAssessment(level: .modify, reasons: [])
        default:
            return CommandRiskAssessment(level: .readOnly, reasons: [])
        }
    }

    /// Classifies a shell command string by splitting chains/pipelines and taking
    /// the highest risk found across every segment.
    public static func classify(command raw: String, sudo: Bool = false) -> CommandRiskAssessment {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandRiskAssessment(level: .readOnly, reasons: [])
        }

        var highest: CommandRiskLevel = .readOnly
        var reasons: [String] = []
        func raise(_ level: CommandRiskLevel, _ reason: String? = nil) {
            if level > highest { highest = level }
            if let reason, !reasons.contains(reason) { reasons.append(reason) }
        }

        if sudo {
            reasons.append(String(localized: "Runs with sudo"))
        }

        // Whole-command high-risk patterns (pipes to shell, SQL drops, critical config edits).
        if matches(trimmed, pattern: #"\b(?:curl|wget)\b[^|\n]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|dash|ksh|python[23]?)\b"#) {
            raise(.destructive, String(localized: "Pipes remote script directly into an interpreter"))
        }
        if matches(trimmed, pattern: #"(?i)\b(?:drop\s+(?:database|table|schema)|truncate\s+table)\b"#) {
            raise(.destructive, String(localized: "Drops or truncates database data"))
        }
        if matches(trimmed, pattern: #"(?:>>?|tee\s+(?:-a\s+)?)\s*/(?:etc|boot|dev)/"#) {
            raise(.destructive, String(localized: "Writes directly to system configuration or device"))
        }
        if matches(trimmed, pattern: #"\b(?:sed\s+-i|perl\s+-pi|chmod|chown|mv|cp|rm|truncate|cat\s*>)\b[^\n]*(?:/etc/ssh/sshd_config|/etc/sudoers|/etc/fstab|/etc/shadow|/etc/passwd)"#) {
            raise(.destructive, String(localized: "Modifies critical system authentication or boot files"))
        }

        let segments = splitSegments(trimmed)
        for segment in segments {
            let assessment = classifySegment(segment)
            if assessment.level > highest {
                highest = assessment.level
            }
            for reason in assessment.reasons where !reasons.contains(reason) {
                reasons.append(reason)
            }
        }

        // If sudo was requested alongside a modifying command, note privilege escalation clearly.
        if sudo, highest == .readOnly {
            // Pure read-only inspection under sudo (e.g. sudo journalctl) stays readOnly with the sudo note.
        }

        return CommandRiskAssessment(level: highest, reasons: reasons)
    }

    // MARK: - Segment Analysis

    private static func classifySegment(_ rawSegment: String) -> CommandRiskAssessment {
        let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty, !segment.hasPrefix("#") else {
            return CommandRiskAssessment(level: .readOnly)
        }

        let hasRedirection = containsOutputRedirection(segment)
        var tokens = tokenize(segment)
        if tokens.isEmpty { return CommandRiskAssessment(level: .readOnly) }

        var usedSudo = false
        // Strip leading env assignments (FOO=bar) and wrappers (sudo, env, command, nice, timeout, nohup).
        while let first = tokens.first {
            if isEnvAssignment(first) {
                tokens.removeFirst()
                continue
            }
            let base = basename(first)
            if base == "sudo" {
                usedSudo = true
                tokens.removeFirst()
                // Skip sudo flags and option values (-u root, -g grp, -p prompt, etc.).
                while let flag = tokens.first, flag.hasPrefix("-") {
                    tokens.removeFirst()
                    if ["-u", "-g", "-p", "-C", "-h", "-r", "-t", "-T"].contains(flag), !tokens.isEmpty {
                        tokens.removeFirst()
                    }
                    if flag == "--" { break }
                }
                continue
            }
            if base == "env" || base == "command" || base == "nohup" || base == "time" {
                tokens.removeFirst()
                while let flag = tokens.first, flag.hasPrefix("-") { tokens.removeFirst() }
                continue
            }
            if base == "timeout" || base == "nice" {
                tokens.removeFirst()
                while let flag = tokens.first, flag.hasPrefix("-") {
                    tokens.removeFirst()
                    if ["-s", "-k", "-n"].contains(flag), !tokens.isEmpty { tokens.removeFirst() }
                }
                if base == "timeout", !tokens.isEmpty { tokens.removeFirst() } // duration arg
                continue
            }
            break
        }

        guard let head = tokens.first else {
            return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly)
        }

        let cmd = basename(head).lowercased()
        let args = Array(tokens.dropFirst())
        let joinedArgs = args.joined(separator: " ")

        var reasons: [String] = usedSudo ? [String(localized: "Runs with sudo")] : []

        // 1. Destructive commands.
        if cmd == "rm" || cmd == "unlink" || cmd == "shred" {
            let hasRecursive = args.contains { isShortFlag($0, containing: "r") || isShortFlag($0, containing: "R") || $0 == "--recursive" }
            let hasForce = args.contains { isShortFlag($0, containing: "f") || $0 == "--force" }
            let touchesSystemPath = args.contains { isSensitivePath($0) }
            if cmd == "shred" || (hasRecursive && hasForce) || touchesSystemPath {
                reasons.append(String(localized: "Deletes files recursively or in system paths"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            reasons.append(String(localized: "Deletes files"))
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if ["dd", "mkfs", "fdisk", "sfdisk", "parted", "wipefs", "gdisk", "lvremove", "vgremove", "pvremove"].contains(cmd)
            || cmd.hasPrefix("mkfs.")
        {
            reasons.append(String(localized: "Raw disk or filesystem write (\(cmd))"))
            return CommandRiskAssessment(level: .destructive, reasons: reasons)
        }

        if ["shutdown", "reboot", "poweroff", "halt", "telinit"].contains(cmd)
            || (cmd == "init" && (args.first == "0" || args.first == "6"))
        {
            reasons.append(String(localized: "Reboots or powers off the server"))
            return CommandRiskAssessment(level: .destructive, reasons: reasons)
        }

        if (cmd == "zfs" || cmd == "zpool") && args.first == "destroy" {
            reasons.append(String(localized: "Destroys ZFS pool or dataset"))
            return CommandRiskAssessment(level: .destructive, reasons: reasons)
        }

        if cmd == "iptables" || cmd == "ip6tables" {
            if args.contains(where: { $0 == "-F" || $0 == "--flush" || $0 == "-X" || $0 == "--delete-chain" || $0 == "-P" }) {
                reasons.append(String(localized: "Flushes or resets firewall rules"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if args.contains(where: { $0 == "-L" || $0 == "--list" || $0 == "-S" || $0 == "--list-rules" }) {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            reasons.append(String(localized: "Changes firewall rules"))
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "ufw" {
            if args.first == "disable" || args.first == "reset" {
                reasons.append(String(localized: "Disables or resets UFW firewall"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if args.first == "status" {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "nft" {
            if args.first == "flush" || args.first == "delete" {
                reasons.append(String(localized: "Flushes or deletes nftables rules"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if args.first == "list" {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "chmod" || cmd == "chown" {
            let recursive = args.contains { isShortFlag($0, containing: "R") || $0 == "--recursive" }
            if recursive && args.contains(where: { isSensitivePath($0) }) {
                reasons.append(String(localized: "Recursively changes permissions/ownership on system directory"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "systemctl" {
            let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
            if ["poweroff", "reboot", "halt", "kexec", "rescue", "emergency"].contains(sub) {
                reasons.append(String(localized: "System power state change (\(sub))"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if ["stop", "disable", "mask"].contains(sub) && joinedArgs.range(of: #"\b(ssh|sshd|systemd-networkd|NetworkManager|networking|tailscaled)\b"#, options: .regularExpression) != nil {
                reasons.append(String(localized: "Stops or disables critical connectivity service"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if ["status", "is-active", "is-enabled", "is-failed", "list-units", "list-unit-files", "list-timers", "list-sockets", "cat", "show", "list-dependencies"].contains(sub) {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "docker" || cmd == "podman" {
            let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
            if sub == "system" && args.contains("prune") && args.contains(where: { isShortFlag($0, containing: "a") || $0 == "--all" || $0 == "--volumes" }) {
                reasons.append(String(localized: "Prunes all unused container images or volumes"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if sub == "rm" || sub == "rmi" {
                if args.contains(where: { isShortFlag($0, containing: "f") || $0 == "--force" }) {
                    reasons.append(String(localized: "Force-removes containers or images"))
                    return CommandRiskAssessment(level: .destructive, reasons: reasons)
                }
                return CommandRiskAssessment(level: .modify, reasons: reasons)
            }
            if ["ps", "images", "logs", "inspect", "stats", "info", "version", "top", "port", "events", "network", "volume"].contains(sub) {
                if (sub == "network" || sub == "volume") && !args.contains(where: { ["ls", "list", "inspect"].contains($0) }) {
                    return CommandRiskAssessment(level: .modify, reasons: reasons)
                }
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            if sub == "compose" {
                let composeSub = args.dropFirst().first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
                if composeSub == "down" && args.contains(where: { $0 == "-v" || $0 == "--volumes" }) {
                    reasons.append(String(localized: "Tears down Docker Compose stack and removes volumes"))
                    return CommandRiskAssessment(level: .destructive, reasons: reasons)
                }
                if ["ps", "logs", "config", "images", "top", "ls", "version"].contains(composeSub) {
                    return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
                }
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "kubectl" {
            let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
            if sub == "delete" || sub == "drain" {
                reasons.append(String(localized: "Deletes Kubernetes resources or drains node"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if ["get", "describe", "logs", "top", "explain", "version", "cluster-info", "config"].contains(sub) {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "kill" || cmd == "pkill" || cmd == "killall" {
            if args.contains("-9") || args.contains("-KILL") || args.contains("1") {
                reasons.append(String(localized: "Force-terminates processes"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        if cmd == "git" {
            let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
            if (sub == "reset" && args.contains("--hard")) || (sub == "clean" && args.contains(where: { isShortFlag($0, containing: "f") })) || (sub == "push" && args.contains(where: { $0 == "-f" || $0 == "--force" })) {
                reasons.append(String(localized: "Destructive git operation (\(sub))"))
                return CommandRiskAssessment(level: .destructive, reasons: reasons)
            }
            if ["status", "log", "diff", "branch", "show", "rev-parse", "tag", "remote", "describe"].contains(sub) && !args.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "--delete" }) {
                return CommandRiskAssessment(level: hasRedirection ? .modify : .readOnly, reasons: reasons)
            }
            return CommandRiskAssessment(level: .modify, reasons: reasons)
        }

        // 2. Known read-only inspection commands (when not redirecting to files).
        if !hasRedirection && isReadOnlyCommand(cmd, args: args) {
            return CommandRiskAssessment(level: .readOnly, reasons: reasons)
        }

        return CommandRiskAssessment(level: .modify, reasons: reasons)
    }

    private static func isReadOnlyCommand(_ cmd: String, args: [String]) -> Bool {
        if simpleReadOnlyCommands.contains(cmd) { return true }
        switch cmd {
        case "find":
            return !args.contains(where: { $0 == "-delete" || $0 == "-exec" || $0 == "-execdir" || $0 == "-ok" })
        case "sed":
            return !args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "--in-place" })
        case "ip":
            let sub = args.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
            return ["a", "addr", "address", "r", "route", "l", "link", "n", "neigh", "s", "stats"].contains(sub)
                && !args.contains(where: { ["add", "del", "delete", "set", "flush", "replace", "change"].contains($0) })
        case "nginx", "sshd", "apachectl", "httpd", "caddy":
            return args.contains("-t") || args.contains("-T") || args.contains("-v") || args.contains("-V") || args.first == "validate"
        case "crontab":
            return args.contains("-l") && !args.contains("-r") && !args.contains("-e")
        case "curl":
            let mutating = args.contains { ["-X", "--request", "-d", "--data", "--data-raw", "--data-binary", "-F", "--form", "-T", "--upload-file", "-o", "--output", "-O", "--remote-name"].contains($0) }
            return !mutating
        case "service":
            return args.last?.lowercased() == "status" || args.contains("--status-all")
        default:
            return false
        }
    }

    private static let simpleReadOnlyCommands: Set<String> = [
        "ls", "ll", "la", "dir", "tree", "pwd", "cd",
        "cat", "head", "tail", "less", "more", "nl", "tac",
        "grep", "egrep", "fgrep", "rg", "awk", "cut", "sort", "uniq", "wc", "tr", "diff", "cmp", "jq", "yq", "xargs",
        "stat", "file", "readlink", "realpath", "basename", "dirname", "md5sum", "sha256sum", "shasum", "cksum",
        "du", "df", "free", "vmstat", "iostat", "mpstat", "sar", "uptime", "uname", "hostname", "hostnamectl", "timedatectl",
        "whoami", "id", "groups", "who", "w", "last", "lastlog", "date", "cal",
        "ps", "pgrep", "pidof", "top", "htop", "lsof", "lscpu", "lsblk", "lsusb", "lspci", "lsmod", "blkid", "mount",
        "ss", "netstat", "ifconfig", "arp", "ping", "ping6", "dig", "nslookup", "host", "traceroute", "tracepath", "mtr",
        "journalctl", "dmesg", "env", "printenv", "which", "whereis", "type", "test", "[", "[[", "true", "false", "echo", "printf",
    ]

    // MARK: - Tokenizing & Splitting

    private static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(command)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if escaped {
                current.append(c)
                escaped = false
                i += 1
                continue
            }
            if c == "\\", !inSingle {
                escaped = true
                current.append(c)
                i += 1
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                current.append(c)
                i += 1
                continue
            }
            if c == "\"", !inSingle {
                inDouble.toggle()
                current.append(c)
                i += 1
                continue
            }
            if !inSingle, !inDouble {
                if c == "\n" || c == ";" {
                    segments.append(current)
                    current = ""
                    i += 1
                    continue
                }
                if c == "|" || c == "&" {
                    if i + 1 < chars.count, chars[i + 1] == c {
                        segments.append(current)
                        current = ""
                        i += 2
                        continue
                    }
                    if c == "|" {
                        segments.append(current)
                        current = ""
                        i += 1
                        continue
                    }
                }
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { segments.append(current) }

        // Also inspect inner subshell substitutions $(...) and `...` as additional segments.
        var expanded = segments
        if let regex = try? NSRegularExpression(pattern: #"\$\(([^()]+)\)|`([^`]+)`"#) {
            let ns = command as NSString
            for match in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
                for g in 1 ... 2 where g < match.numberOfRanges {
                    let r = match.range(at: g)
                    if r.location != NSNotFound, r.length > 0 {
                        expanded.append(ns.substring(with: r))
                    }
                }
            }
        }
        return expanded
    }

    private static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for c in segment {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if c == "\\", !inSingle {
                escaped = true
                continue
            }
            if c == "'", !inDouble {
                inSingle.toggle()
                continue
            }
            if c == "\"", !inSingle {
                inDouble.toggle()
                continue
            }
            if !inSingle, !inDouble, c.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(c)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func containsOutputRedirection(_ segment: String) -> Bool {
        // Ignore stderr-to-stdout merges (2>&1) and /dev/null sinks.
        let cleaned = segment
            .replacingOccurrences(of: #"\b2>&1\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:\d?>|>>)\s*/dev/null"#, with: "", options: .regularExpression)
        var inSingle = false
        var inDouble = false
        for c in cleaned {
            if c == "'", !inDouble { inSingle.toggle(); continue }
            if c == "\"", !inSingle { inDouble.toggle(); continue }
            if !inSingle, !inDouble, c == ">" { return true }
        }
        return false
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func isShortFlag(_ token: String, containing ch: Character) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token.dropFirst().contains(ch)
    }

    private static func isSensitivePath(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if normalized == "/" || normalized == "/*" || normalized == "~" || normalized == "~/" { return true }
        let prefixes = ["/etc", "/var", "/usr", "/boot", "/bin", "/sbin", "/lib", "/root", "/home", "/sys", "/proc", "/dev"]
        return prefixes.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

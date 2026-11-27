//
//  RDMachine.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/8.
//

import Foundation

public struct RDMachine: Codable, Identifiable, Equatable, Sendable {
    public init(id: UUID = UUID(),
                remoteAddress: String = "",
                remotePort: String = "",
                name: String = "",
                group: String = "",
                lastConnection: Date = .init(),
                lastBanner: String = "",
                comment: String = "",
                associatedIdentity: String? = nil,
                attachment: [String: String] = [:])
    {
        self.id = id
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.name = name
        self.group = group
        self.lastConnection = lastConnection
        self.lastBanner = lastBanner
        self.comment = comment
        self.associatedIdentity = associatedIdentity
        self.attachment = attachment
    }

    public var id = UUID()

    // generic authenticate filed required for ssh
    public var remoteAddress: String
    public var remotePort: String

    // application required
    public var name: String
    public var group: String
    public var lastConnection: Date
    public var lastBanner: String
    public var comment: String
    public var associatedIdentity: String?

    // reserved for future use
    public var attachment: [String: String]

    /// Where Files opens on this server; empty for the user's home folder.
    public var fileTransferLoginPath: String {
        get {
            attachment["sftp.login.path", default: ""]
        }
        set {
            attachment["sftp.login.path"] = newValue
        }
    }

    /// Files opens in the home folder of the user it signs in as. "/" was
    /// the default once and was saved with servers nobody chose it for, so
    /// it means the home folder too.
    public var startsInHomeFolder: Bool {
        let path = fileTransferLoginPath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty || path == "/"
    }

    /// The user to sign in as. The identity only says how (password or key).
    public var username: String {
        get { attachment["username"] ?? "" }
        set { attachment["username"] = newValue.isEmpty ? nil : newValue }
    }

    /// The user a server signs in as when none is set.
    public static let defaultUsername = "root"

    /// The server's user; for a server saved before servers had one, the user
    /// its identity was made for; else root.
    public func loginUsername(with identity: RDIdentity?) -> String {
        if !username.isEmpty { return username }
        if let legacy = identity?.username, !legacy.isEmpty { return legacy }
        return Self.defaultUsername
    }

    /// Free-form labels ("prod", "tokyo") for search and filtering.
    public var tags: [String] {
        get {
            (attachment["tags"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            let joined = newValue
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ") }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            attachment["tags"] = joined.isEmpty ? nil : joined
        }
    }

    /// A snippet typed into the terminal once it has signed in.
    public var startupSnippet: RDSnippet.ID? {
        get { attachment["startup.snippet"].flatMap(UUID.init(uuidString:)) }
        set { attachment["startup.snippet"] = newValue?.uuidString }
    }

    /// A command whose stdin and stdout carry the connection, instead of a
    /// direct TCP connection: `cloudflared access ssh --hostname %h`. `%h` is
    /// the address and `%p` the port, as OpenSSH writes them. Empty connects
    /// directly.
    public var proxyCommand: String {
        get { attachment["proxy.command"] ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            attachment["proxy.command"] = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The terminal has the shell report its folder, so Files can follow
    /// it: see `ShellIntegration`. Off unless the user turns it on.
    public var shellIntegration: Bool {
        get { attachment["shell.integration"] == "1" }
        set { attachment["shell.integration"] = newValue ? "1" : nil }
    }

    /// The server signs in with no password or key: the connection itself is
    /// its credential, as with Tailscale SSH, so the protocol's "none" request
    /// is enough. Its identity, if it still has one, goes unused.
    public var signsInWithoutCredentials: Bool {
        get { attachment["auth"] == "none" }
        set { attachment["auth"] = newValue ? "none" : nil }
    }

    // MARK: - Notes & VPS Renewal Reminder

    public enum RenewalCycle: String, Codable, CaseIterable, Identifiable, Sendable {
        case monthly
        case quarterly
        case semiannual
        case yearly
        case custom

        public var id: String { rawValue }

        public var localizedTitle: String {
            switch self {
            case .monthly: String(localized: "Monthly")
            case .quarterly: String(localized: "Quarterly")
            case .semiannual: String(localized: "Semi-Annual")
            case .yearly: String(localized: "Yearly")
            case .custom: String(localized: "Custom")
            }
        }

        public func nextDate(from date: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
            case .quarterly: calendar.date(byAdding: .month, value: 3, to: date)
            case .semiannual: calendar.date(byAdding: .month, value: 6, to: date)
            case .yearly: calendar.date(byAdding: .year, value: 1, to: date)
            case .custom: nil
            }
        }
    }

    public enum RenewalUrgency: Equatable, Sendable {
        case expired
        case urgent
        case soon
        case normal
    }

    public var trimmedComment: String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var renewalEnabled: Bool {
        get { attachment["vps.renewal.enabled"] == "1" }
        set { attachment["vps.renewal.enabled"] = newValue ? "1" : nil }
    }

    public var renewalDate: Date? {
        get {
            guard let raw = attachment["vps.renewal.date"], !raw.isEmpty else { return nil }
            return Self.renewalDateFormatter.date(from: raw)
        }
        set {
            if let newValue {
                attachment["vps.renewal.date"] = Self.renewalDateFormatter.string(from: newValue)
            } else {
                attachment["vps.renewal.date"] = nil
            }
        }
    }

    public var renewalCycle: RenewalCycle {
        get { attachment["vps.renewal.cycle"].flatMap(RenewalCycle.init(rawValue:)) ?? .monthly }
        set { attachment["vps.renewal.cycle"] = newValue.rawValue }
    }

    public var renewalPrice: String {
        get { attachment["vps.renewal.price"] ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            attachment["vps.renewal.price"] = trimmed.isEmpty ? nil : trimmed
        }
    }

    public var renewalRemindDays: Int {
        get {
            if let raw = attachment["vps.renewal.remindDays"], let val = Int(raw), val > 0 {
                return val
            }
            return 7
        }
        set {
            attachment["vps.renewal.remindDays"] = String(max(1, newValue))
        }
    }

    /// Whole calendar days from today until the VPS renewal date. Negative means expired.
    public func daysUntilRenewal(from reference: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard renewalEnabled, let target = renewalDate else { return nil }
        let startToday = calendar.startOfDay(for: reference)
        let startTarget = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: startToday, to: startTarget).day
    }

    public func renewalUrgency(from reference: Date = Date()) -> RenewalUrgency? {
        guard let days = daysUntilRenewal(from: reference) else { return nil }
        if days < 0 { return .expired }
        if days <= max(3, renewalRemindDays) { return .urgent }
        if days <= 30 { return .soon }
        return .normal
    }

    public func renewalBadgeText(from reference: Date = Date()) -> String? {
        guard let days = daysUntilRenewal(from: reference) else { return nil }
        if days < 0 {
            return String(localized: "Expired \(abs(days))d")
        } else if days == 0 {
            return String(localized: "Due today")
        } else {
            return String(localized: "Renews in \(days)d")
        }
    }

    /// Advances the renewal date by one billing cycle from the later of today or the current renewal date.
    public mutating func advanceRenewalCycle(from reference: Date = Date()) {
        guard let current = renewalDate else { return }
        let base = max(current, reference)
        if let next = renewalCycle.nextDate(from: base) {
            renewalDate = next
        }
    }

    private static var renewalDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // convince

    public func isQualifiedForSearch(text: String) -> Bool {
        let searchText = text.lowercased()
        if remoteAddress.description.lowercased().contains(searchText) { return true }
        if remotePort.description.lowercased().contains(searchText) { return true }
        if name.description.lowercased().contains(searchText) { return true }
        if group.description.lowercased().contains(searchText) { return true }
        if lastBanner.description.lowercased().contains(searchText) { return true }
        if comment.description.lowercased().contains(searchText) { return true }
        if tags.contains(where: { $0.lowercased().contains(searchText) }) { return true }
        if proxyCommand.lowercased().contains(searchText) { return true }
        return false
    }

    public func shortDescription(withComment: Bool = true) -> String {
        var build = name + " "
        let identity = associatedIdentity.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.identityGroup[$0] }
        let user = loginUsername(with: identity)
        if !user.isEmpty {
            build += user + "@"
        }
        build += remoteAddress
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if withComment, !comment.isEmpty {
            build += " (" + comment + ")"
        }
        return build
    }

    public func isNotPlaceholder() -> Bool {
        remoteAddress.count > 0 && remotePort.count > 0
    }

    public func getCommand(insertLeadingSSH: Bool = true) -> String {
        var build = ""
        let leading = insertLeadingSSH ? "ssh " : ""
        let identity = associatedIdentity.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.identityGroup[$0] }
        let user = loginUsername(with: identity)
        if !user.isEmpty {
            build = leading + "\(user)@\(remoteAddress)"
        }
        if build.isEmpty {
            build = leading + "\(remoteAddress)"
        }
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if !proxyCommand.isEmpty {
            build += " -o ProxyCommand=\"" + proxyCommand.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return build
    }
}

extension RDMachine: RDGroupItem, RDGroupSectionedItem {
    public init() { self.init(id: UUID()) }
}

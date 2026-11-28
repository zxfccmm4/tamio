//
//  ThirdPartyHostImporter.swift
//  TamioModule
//
//  Imports saved SSH hosts from common third-party SSH clients so users
//  migrating to Tamio don't have to re-enter hosts by hand:
//  - Xshell (`.xsh` INI files)
//  - FinalShell (JSON host configs)
//  - WindTerm (`.sessions` JSON arrays)
//  - Termius (exported JSON / CSV)
//  - Generic CSV (`name,host,port,username,group,tags,comment`)
//

import Foundation

public enum ThirdPartyImportFormat: String, CaseIterable, Identifiable, Sendable {
    case auto
    case xshell
    case finalShell
    case windTerm
    case termius
    case csv

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .auto: String(localized: "Auto-detect")
        case .xshell: "Xshell (.xsh)"
        case .finalShell: "FinalShell (JSON)"
        case .windTerm: "WindTerm (.sessions)"
        case .termius: "Termius (JSON)"
        case .csv: "CSV"
        }
    }
}

public struct ImportedHostRecord: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var group: String
    public var tags: [String]
    public var comment: String
    public var sourceFormat: ThirdPartyImportFormat

    public init(
        name: String,
        address: String,
        port: Int = 22,
        username: String = RDMachine.defaultUsername,
        group: String = "",
        tags: [String] = [],
        comment: String = "",
        sourceFormat: ThirdPartyImportFormat
    ) {
        self.name = name.isEmpty ? address : name
        self.address = address
        self.port = (1 ... 65535).contains(port) ? port : 22
        self.username = username.isEmpty ? RDMachine.defaultUsername : username
        self.group = group
        self.tags = tags
        self.comment = comment
        self.sourceFormat = sourceFormat
    }

    public func toMachine() -> RDMachine {
        var machine = RDMachine(
            remoteAddress: address,
            remotePort: String(port),
            name: name.isEmpty ? address : name,
            group: group,
            lastConnection: Date(timeIntervalSince1970: 0),
            comment: comment
        )
        machine.username = username
        machine.tags = tags
        return machine
    }
}

public enum ThirdPartyHostImporter {
    public struct ParseResult: Equatable, Sendable {
        public let format: ThirdPartyImportFormat
        public let hosts: [ImportedHostRecord]
        public let warnings: [String]
    }

    /// Parses one file (or directory of `.xsh` / `.json` files) into host candidates.
    public static func parse(urls: [URL], format: ThirdPartyImportFormat = .auto) -> ParseResult {
        var hosts: [ImportedHostRecord] = []
        var warnings: [String] = []
        var detected: ThirdPartyImportFormat = format

        var expanded: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let child as URL in enumerator {
                        let ext = child.pathExtension.lowercased()
                        if ["xsh", "json", "sessions", "csv"].contains(ext) {
                            expanded.append(child)
                        }
                    }
                }
            } else {
                expanded.append(url)
            }
        }

        for url in expanded {
            guard let data = try? Data(contentsOf: url) else {
                warnings.append("Could not read \(url.lastPathComponent).")
                continue
            }
            let parsed = parse(data: data, fileName: url.lastPathComponent, format: format)
            if detected == .auto, !parsed.hosts.isEmpty { detected = parsed.format }
            hosts.append(contentsOf: parsed.hosts)
            warnings.append(contentsOf: parsed.warnings)
        }
        return ParseResult(format: detected, hosts: deduplicate(hosts), warnings: warnings)
    }

    /// Parses raw bytes from an exported file.
    public static func parse(data: Data, fileName: String = "", format: ThirdPartyImportFormat = .auto) -> ParseResult {
        let text = decodeText(data)
        let ext = (fileName as NSString).pathExtension.lowercased()

        if format == .xshell || (format == .auto && (ext == "xsh" || text.contains("[CONNECTION]") && text.contains("Host="))) {
            return parseXshell(text, fallbackName: (fileName as NSString).deletingPathExtension)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
                switch format {
                case .windTerm:
                    return parseWindTerm(json)
                case .finalShell:
                    return parseFinalShell(json)
                case .termius:
                    return parseTermius(json)
                case .auto:
                    if let wind = tryWindTerm(json), !wind.hosts.isEmpty { return wind }
                    if let termius = tryTermius(json), !termius.hosts.isEmpty { return termius }
                    if let fs = tryFinalShell(json), !fs.hosts.isEmpty { return fs }
                    return ParseResult(format: .auto, hosts: [], warnings: ["Unrecognized JSON host export structure."])
                default:
                    break
                }
            }
        }

        if format == .csv || (format == .auto && (ext == "csv" || text.contains(","))) {
            return parseCSV(text)
        }

        return ParseResult(format: format, hosts: [], warnings: ["Could not detect a supported host export format."])
    }

    // MARK: - Xshell (.xsh INI)

    private static func parseXshell(_ text: String, fallbackName: String) -> ParseResult {
        var section = ""
        var host = ""
        var port = 22
        var user = RDMachine.defaultUsername
        var description = ""
        var protocolName = "SSH"

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).uppercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch (section, key.lowercased()) {
            case ("CONNECTION", "host"):
                host = val
            case ("CONNECTION", "port"):
                if let p = Int(val) { port = p }
            case ("CONNECTION", "protocol"):
                protocolName = val.uppercased()
            case ("CONNECTION:AUTHENTICATION", "username"):
                if !val.isEmpty { user = val }
            case ("SESSIONINFO", "description"):
                description = val
            default:
                break
            }
        }

        guard !host.isEmpty else {
            return ParseResult(format: .xshell, hosts: [], warnings: ["No Host= entry found in \(fallbackName.isEmpty ? "Xshell file" : fallbackName)."])
        }
        guard protocolName.isEmpty || protocolName.contains("SSH") else {
            return ParseResult(format: .xshell, hosts: [], warnings: ["Skipped non-SSH Xshell session (\(protocolName))."])
        }
        let record = ImportedHostRecord(
            name: fallbackName.isEmpty ? host : fallbackName,
            address: host,
            port: port,
            username: user,
            group: "Xshell",
            comment: description,
            sourceFormat: .xshell
        )
        return ParseResult(format: .xshell, hosts: [record], warnings: [])
    }

    // MARK: - WindTerm (.sessions JSON)

    private static func tryWindTerm(_ json: Any) -> ParseResult? {
        guard let arr = json as? [[String: Any]],
              arr.contains(where: { $0["session.target"] != nil || $0["session.protocol"] != nil })
        else { return nil }
        return parseWindTerm(json)
    }

    private static func parseWindTerm(_ json: Any) -> ParseResult {
        guard let arr = json as? [[String: Any]] else {
            return ParseResult(format: .windTerm, hosts: [], warnings: ["WindTerm export must be a JSON array."])
        }
        var records: [ImportedHostRecord] = []
        for item in arr {
            let proto = (item["session.protocol"] as? String)?.lowercased() ?? "ssh"
            guard proto.isEmpty || proto == "ssh" else { continue }
            guard let target = (item["session.target"] as? String)?.trimmingCharacters(in: .whitespaces), !target.isEmpty else { continue }
            let (parsedUser, parsedHost) = splitUserAtHost(target)
            let user = (item["session.user"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parsedUser ?? RDMachine.defaultUsername
            let port = intValue(item["session.port"]) ?? 22
            let label = (item["session.label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let group = (item["session.group"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let desc = (item["session.description"] as? String) ?? ""
            records.append(ImportedHostRecord(
                name: label.isEmpty ? parsedHost : label,
                address: parsedHost,
                port: port,
                username: user,
                group: group,
                comment: desc,
                sourceFormat: .windTerm
            ))
        }
        return ParseResult(format: .windTerm, hosts: records, warnings: [])
    }

    // MARK: - Termius JSON

    private static func tryTermius(_ json: Any) -> ParseResult? {
        guard let dict = json as? [String: Any], dict["hosts"] is [[String: Any]] else { return nil }
        return parseTermius(json)
    }

    private static func parseTermius(_ json: Any) -> ParseResult {
        guard let dict = json as? [String: Any], let hostItems = dict["hosts"] as? [[String: Any]] else {
            return ParseResult(format: .termius, hosts: [], warnings: ["Expected a Termius JSON object containing a \"hosts\" array."])
        }
        var groupNames: [String: String] = [:]
        if let groups = dict["groups"] as? [[String: Any]] {
            for g in groups {
                if let id = stringValue(g["id"]), let label = (g["label"] as? String) ?? (g["name"] as? String) {
                    groupNames[id] = label
                }
            }
        }
        var records: [ImportedHostRecord] = []
        for item in hostItems {
            guard let address = ((item["address"] as? String) ?? (item["hostname"] as? String))?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { continue }
            let label = (item["label"] as? String) ?? (item["name"] as? String) ?? address
            let port = intValue(item["port"]) ?? 22
            let user = (item["username"] as? String) ?? (item["user"] as? String) ?? RDMachine.defaultUsername
            let groupID = stringValue(item["group"]) ?? stringValue(item["group_id"])
            let group = groupID.flatMap { groupNames[$0] } ?? (item["group_name"] as? String) ?? ""
            let tags = (item["tags"] as? [String]) ?? []
            let comment = (item["comment"] as? String) ?? (item["notes"] as? String) ?? ""
            records.append(ImportedHostRecord(
                name: label,
                address: address,
                port: port,
                username: user,
                group: group,
                tags: tags,
                comment: comment,
                sourceFormat: .termius
            ))
        }
        return ParseResult(format: .termius, hosts: records, warnings: [])
    }

    // MARK: - FinalShell JSON

    private static func tryFinalShell(_ json: Any) -> ParseResult? {
        if let dict = json as? [String: Any], dict["host"] is String { return parseFinalShell(json) }
        if let arr = json as? [[String: Any]], arr.contains(where: { $0["host"] is String || $0["user_name"] != nil }) {
            return parseFinalShell(json)
        }
        return nil
    }

    private static func parseFinalShell(_ json: Any) -> ParseResult {
        let items: [[String: Any]]
        if let dict = json as? [String: Any] {
            if let nested = dict["connections"] as? [[String: Any]] {
                items = nested
            } else {
                items = [dict]
            }
        } else if let arr = json as? [[String: Any]] {
            items = arr
        } else {
            return ParseResult(format: .finalShell, hosts: [], warnings: ["Invalid FinalShell JSON."])
        }

        var records: [ImportedHostRecord] = []
        for item in items {
            guard let host = ((item["host"] as? String) ?? (item["ip"] as? String))?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { continue }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? host
            let port = intValue(item["port"]) ?? 22
            let user = (item["user_name"] as? String) ?? (item["username"] as? String) ?? (item["user"] as? String) ?? RDMachine.defaultUsername
            let group = (item["group"] as? String) ?? (item["folder"] as? String) ?? ""
            let comment = (item["description"] as? String) ?? (item["remark"] as? String) ?? ""
            records.append(ImportedHostRecord(
                name: name,
                address: host,
                port: port,
                username: user,
                group: group,
                comment: comment,
                sourceFormat: .finalShell
            ))
        }
        return ParseResult(format: .finalShell, hosts: records, warnings: [])
    }

    // MARK: - CSV

    private static func parseCSV(_ text: String) -> ParseResult {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let headerLine = lines.first else {
            return ParseResult(format: .csv, hosts: [], warnings: ["CSV file is empty."])
        }
        let headers = parseCSVRow(headerLine).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard let hostIdx = headers.firstIndex(where: { ["host", "hostname", "address", "ip", "server"].contains($0) }) else {
            return ParseResult(format: .csv, hosts: [], warnings: ["CSV header must include a host/address/ip column."])
        }
        let nameIdx = headers.firstIndex(where: { ["name", "label", "alias", "title"].contains($0) })
        let portIdx = headers.firstIndex(where: { $0 == "port" })
        let userIdx = headers.firstIndex(where: { ["user", "username", "login"].contains($0) })
        let groupIdx = headers.firstIndex(where: { ["group", "folder", "category"].contains($0) })
        let tagsIdx = headers.firstIndex(where: { $0 == "tags" })
        let commentIdx = headers.firstIndex(where: { ["comment", "notes", "description", "remark"].contains($0) })

        var records: [ImportedHostRecord] = []
        for line in lines.dropFirst() {
            let cols = parseCSVRow(line)
            guard hostIdx < cols.count else { continue }
            let address = cols[hostIdx].trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { continue }
            let name = nameIdx.flatMap { $0 < cols.count ? cols[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? address
            let port = portIdx.flatMap { $0 < cols.count ? Int(cols[$0].trimmingCharacters(in: .whitespaces)) : nil } ?? 22
            let user = userIdx.flatMap { $0 < cols.count ? cols[$0].trimmingCharacters(in: .whitespaces) : nil } ?? RDMachine.defaultUsername
            let group = groupIdx.flatMap { $0 < cols.count ? cols[$0].trimmingCharacters(in: .whitespaces) : nil } ?? ""
            let tagsRaw = tagsIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? ""
            let tags = tagsRaw.split(whereSeparator: { $0 == ";" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let comment = commentIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? ""
            records.append(ImportedHostRecord(
                name: name,
                address: address,
                port: port,
                username: user,
                group: group,
                tags: tags,
                comment: comment,
                sourceFormat: .csv
            ))
        }
        return ParseResult(format: .csv, hosts: records, warnings: [])
    }

    // MARK: - Helpers

    private static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func splitUserAtHost(_ value: String) -> (String?, String) {
        if let at = value.lastIndex(of: "@") {
            let user = String(value[..<at])
            let host = String(value[value.index(after: at)...])
            return (user.isEmpty ? nil : user, host)
        }
        return (nil, value)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? Int { return String(n) }
        return nil
    }

    private static func parseCSVRow(_ line: String) -> [String] {
        var cols: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                cols.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        cols.append(current)
        return cols
    }

    private static func deduplicate(_ list: [ImportedHostRecord]) -> [ImportedHostRecord] {
        var seen = Set<String>()
        return list.filter { item in
            let key = "\(item.username)@\(item.address.lowercased()):\(item.port)#\(item.name.lowercased())"
            return seen.insert(key).inserted
        }
    }
}

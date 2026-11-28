//
//  AssistantToolArgumentOrder.swift
//  TamioAssistant
//
//  FlowDown `ModelToolArgumentOrder` pattern:
//  Preserves the key declaration order from the raw JSON object the model sent,
//  layered after any tool-specified schema order, because `JSONSerialization`
//  decodes dictionaries without preserving key order.
//

import Foundation

public nonisolated enum AssistantToolArgumentOrder {
    /// Tool schema order first, then any remaining keys in wire JSON order.
    public static func order(schema: [String], arguments json: String) -> [String] {
        var seen = Set(schema)
        return schema + keys(in: json).filter { seen.insert($0).inserted }
    }

    /// Extracts top-level keys of a JSON object in appearance order.
    public static func keys(in json: String) -> [String] {
        var scanner = Scanner(Array(json.utf8))
        guard scanner.take(UInt8(ascii: "{")) else { return [] }
        var result: [String] = []
        if scanner.take(UInt8(ascii: "}")) { return [] }
        repeat {
            guard let key = scanner.string(),
                  scanner.take(UInt8(ascii: ":")),
                  scanner.skipValue()
            else {
                return result
            }
            if !result.contains(key) {
                result.append(key)
            }
        } while scanner.take(UInt8(ascii: ","))
        return scanner.take(UInt8(ascii: "}")) ? result : result
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func take(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func string() -> String? {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            guard skipString() else { return nil }
            let slice = Data(bytes[start ..< index])
            return (try? JSONDecoder().decode(String.self, from: slice))
        }

        mutating func skipValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            var depth = 0
            while index < bytes.count {
                let b = bytes[index]
                switch b {
                case UInt8(ascii: "\""):
                    guard skipString() else { return false }
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    index += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { return true }
                    depth -= 1
                    index += 1
                case UInt8(ascii: ","):
                    if depth == 0 { return true }
                    index += 1
                default:
                    index += 1
                }
            }
            return depth == 0
        }

        private mutating func skipString() -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return true
                default:
                    index += 1
                }
            }
            return false
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D
            {
                index += 1
            }
        }
    }
}

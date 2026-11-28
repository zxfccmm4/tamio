//
//  PuTTYKeyConverter.swift
//  TamioModule
//
//  Converts PuTTY `.ppk` (v2 and v3) private key files — both unencrypted and
//  AES-256-CBC passphrase-protected (SHA-1 KDF for v2, RFC 9106 Argon2 for v3) —
//  into standard OpenSSH PEM private keys (`-----BEGIN OPENSSH PRIVATE KEY-----`)
//  and `authorized_keys` public keys for RSA, ECDSA, and Ed25519 keys.
//

import CommonCrypto
import CryptoKit
import Foundation

public enum PuTTYKeyError: LocalizedError, Equatable, Sendable {
    case notAPuTTYKey
    case unsupportedVersion(Int)
    case unsupportedAlgorithm(String)
    case unsupportedEncryption(String)
    case passphraseRequired
    case wrongPassphraseOrCorrupt
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notAPuTTYKey:
            String(localized: "This file is not a PuTTY (.ppk) private key.")
        case let .unsupportedVersion(v):
            String(localized: "Unsupported PuTTY key version (\(v)). Versions 2 and 3 are supported.")
        case let .unsupportedAlgorithm(alg):
            String(localized: "Unsupported SSH key algorithm: \(alg).")
        case let .unsupportedEncryption(enc):
            String(localized: "Unsupported PuTTY key encryption: \(enc).")
        case .passphraseRequired:
            String(localized: "This PuTTY key is encrypted. Enter its passphrase to import it.")
        case .wrongPassphraseOrCorrupt:
            String(localized: "Incorrect passphrase or corrupted PuTTY key file.")
        case let .malformed(reason):
            String(localized: "Malformed PuTTY key: \(reason)")
        }
    }
}

public enum PuTTYKeyConverter {
    public struct ConvertedKey: Equatable, Sendable {
        public let privateKey: String
        public let publicKey: String
        public let comment: String
        public let algorithm: String
    }

    public static func isPuTTYKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("PuTTY-User-Key-File-2:") || trimmed.hasPrefix("PuTTY-User-Key-File-3:")
    }

    /// Converts a PuTTY `.ppk` v2/v3 text payload into an unencrypted OpenSSH PEM key pair.
    public static func convert(_ text: String, passphrase: String = "") throws -> ConvertedKey {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw PuTTYKeyError.notAPuTTYKey
        }

        let version: Int
        let algorithm: String
        if first.hasPrefix("PuTTY-User-Key-File-2:") {
            version = 2
            algorithm = first.dropFirst("PuTTY-User-Key-File-2:".count).trimmingCharacters(in: .whitespaces)
        } else if first.hasPrefix("PuTTY-User-Key-File-3:") {
            version = 3
            algorithm = first.dropFirst("PuTTY-User-Key-File-3:".count).trimmingCharacters(in: .whitespaces)
        } else {
            throw PuTTYKeyError.notAPuTTYKey
        }

        guard ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(algorithm) else {
            throw PuTTYKeyError.unsupportedAlgorithm(algorithm)
        }

        var headers: [String: String] = [:]
        var publicBase64 = ""
        var privateBase64 = ""
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            idx += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "Public-Lines", let count = Int(val) {
                    guard idx + count <= lines.count else { throw PuTTYKeyError.malformed(String(localized: "Public-Lines truncated")) }
                    publicBase64 = lines[idx ..< (idx + count)].joined()
                    idx += count
                } else if key == "Private-Lines", let count = Int(val) {
                    guard idx + count <= lines.count else { throw PuTTYKeyError.malformed(String(localized: "Private-Lines truncated")) }
                    privateBase64 = lines[idx ..< (idx + count)].joined()
                    idx += count
                } else {
                    headers[key] = val
                }
            }
        }

        guard let encryption = headers["Encryption"] else {
            throw PuTTYKeyError.malformed(String(localized: "Missing Encryption header"))
        }
        let comment = headers["Comment"] ?? ""
        guard let publicBlob = Data(base64Encoded: publicBase64),
              let rawPrivateBlob = Data(base64Encoded: privateBase64)
        else {
            throw PuTTYKeyError.malformed(String(localized: "Invalid Base64 key body"))
        }

        let privateBlob: Data
        let macKey: Data

        switch encryption {
        case "none":
            privateBlob = rawPrivateBlob
            macKey = version == 2
                ? Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8)))
                : Data()
        case "aes256-cbc":
            guard !passphrase.isEmpty else { throw PuTTYKeyError.passphraseRequired }
            if version == 2 {
                let k1 = Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 0]) + Data(passphrase.utf8)))
                let k2 = Data(Insecure.SHA1.hash(data: Data([0, 0, 0, 1]) + Data(passphrase.utf8)))
                let aesKey = (k1 + k2).prefix(32)
                let iv = Data(repeating: 0, count: 16)
                privateBlob = try decryptAES256CBC(ciphertext: rawPrivateBlob, key: Data(aesKey), iv: iv)
                macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8) + Data(passphrase.utf8)))
            } else {
                let kdfName = headers["Key-Derivation"] ?? "Argon2id"
                let variant: Argon2.Variant
                switch kdfName {
                case "Argon2id": variant = .argon2id
                case "Argon2i": variant = .argon2i
                case "Argon2d": variant = .argon2d
                default: throw PuTTYKeyError.malformed(String(localized: "Unsupported Key-Derivation \(kdfName)"))
                }
                guard let memoryKiB = Int(headers["Argon2-Memory"] ?? ""),
                      let passes = Int(headers["Argon2-Passes"] ?? ""),
                      let parallelism = Int(headers["Argon2-Parallelism"] ?? ""),
                      let saltHex = headers["Argon2-Salt"],
                      let salt = Data(hexString: saltHex)
                else {
                    throw PuTTYKeyError.malformed(String(localized: "Missing Argon2 parameters"))
                }
                let derived = Argon2.derive(
                    variant: variant,
                    password: Data(passphrase.utf8),
                    salt: salt,
                    memoryKiB: memoryKiB,
                    iterations: passes,
                    parallelism: parallelism,
                    outputLength: 80
                )
                let aesKey = Data(derived[0 ..< 32])
                let iv = Data(derived[32 ..< 48])
                macKey = Data(derived[48 ..< 80])
                privateBlob = try decryptAES256CBC(ciphertext: rawPrivateBlob, key: aesKey, iv: iv)
            }
        default:
            throw PuTTYKeyError.unsupportedEncryption(encryption)
        }

        // Verify Private-MAC when present so wrong passphrases are rejected immediately.
        if let expectedMacHex = headers["Private-MAC"]?.lowercased() {
            var macInput = Data()
            macInput.appendSSHString(algorithm)
            macInput.appendSSHString(encryption)
            macInput.appendSSHString(comment)
            macInput.appendSSHString(publicBlob)
            macInput.appendSSHString(privateBlob)

            let computedHex: String
            if version == 2 {
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: macInput, using: SymmetricKey(data: macKey))
                computedHex = mac.map { String(format: "%02x", $0) }.joined()
            } else {
                let mac = HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: macKey))
                computedHex = mac.map { String(format: "%02x", $0) }.joined()
            }
            guard computedHex == expectedMacHex else {
                throw PuTTYKeyError.wrongPassphraseOrCorrupt
            }
        }

        let openSSHPrivate = try buildOpenSSHPrivateKey(
            algorithm: algorithm,
            publicBlob: publicBlob,
            privateBlob: privateBlob,
            comment: comment
        )
        let openSSHPublic = "\(algorithm) \(publicBlob.base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)")
        return ConvertedKey(
            privateKey: openSSHPrivate,
            publicKey: openSSHPublic,
            comment: comment,
            algorithm: algorithm
        )
    }

    // MARK: - OpenSSH PEM Encoding

    private static func buildOpenSSHPrivateKey(
        algorithm: String,
        publicBlob: Data,
        privateBlob: Data,
        comment: String
    ) throws -> String {
        var pubReader = SSHWireReader(publicBlob)
        var privReader = SSHWireReader(privateBlob)

        let pubAlg = try pubReader.readStringUTF8()
        guard pubAlg == algorithm else {
            throw PuTTYKeyError.malformed(String(localized: "Public key algorithm mismatch (\(pubAlg) != \(algorithm))"))
        }

        let check = UInt32.random(in: .min ... .max)
        var secret = Data()
        secret.appendUInt32(check)
        secret.appendUInt32(check)
        secret.appendSSHString(algorithm)

        switch algorithm {
        case "ssh-ed25519":
            let pubKey = try pubReader.readString()
            let seed = try privReader.readString()
            guard pubKey.count == 32, seed.count == 32 else {
                throw PuTTYKeyError.malformed(String(localized: "Invalid Ed25519 key lengths"))
            }
            secret.appendSSHString(pubKey)
            secret.appendSSHString(seed + pubKey)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try pubReader.readString()
            let point = try pubReader.readString()
            let scalar = try privReader.readString()
            secret.appendSSHString(curve)
            secret.appendSSHString(point)
            secret.appendSSHString(scalar)

        case "ssh-rsa":
            // PuTTY public: e, n. PuTTY private: d, p, q, iqmp.
            // OpenSSH private order: n, e, d, iqmp, p, q.
            let e = try pubReader.readString()
            let n = try pubReader.readString()
            let d = try privReader.readString()
            let p = try privReader.readString()
            let q = try privReader.readString()
            let iqmp = try privReader.readString()
            secret.appendSSHString(n)
            secret.appendSSHString(e)
            secret.appendSSHString(d)
            secret.appendSSHString(iqmp)
            secret.appendSSHString(p)
            secret.appendSSHString(q)

        default:
            throw PuTTYKeyError.unsupportedAlgorithm(algorithm)
        }

        secret.appendSSHString(comment)
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }

        var body = Data("openssh-key-v1".utf8)
        body.append(0)
        body.appendSSHString("none")
        body.appendSSHString("none")
        body.appendSSHString(Data())
        body.appendUInt32(1)
        body.appendSSHString(publicBlob)
        body.appendSSHString(secret)

        let base64 = body.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            return String(base64[start ..< end])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + wrapped + ["-----END OPENSSH PRIVATE KEY-----"])
            .joined(separator: "\n") + "\n"
    }

    // MARK: - AES-256-CBC (CommonCrypto, no padding)

    private static func decryptAES256CBC(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard ciphertext.count % kCCBlockSizeAES128 == 0, key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw PuTTYKeyError.wrongPassphraseOrCorrupt
        }
        var out = Data(count: ciphertext.count)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, ciphertext.count,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PuTTYKeyError.wrongPassphraseOrCorrupt
        }
        return out.prefix(outLen)
    }
}

// MARK: - SSH Wire Reader / Writer

private struct SSHWireReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw PuTTYKeyError.malformed(String(localized: "Unexpected EOF")) }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readString() throws -> Data {
        let len = Int(try readUInt32())
        guard len >= 0, offset + len <= data.count else { throw PuTTYKeyError.malformed(String(localized: "Invalid SSH string length")) }
        let slice = data.subdata(in: offset ..< (offset + len))
        offset += len
        return slice
    }

    mutating func readStringUTF8() throws -> String {
        let bytes = try readString()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw PuTTYKeyError.malformed(String(localized: "Non-UTF8 SSH string"))
        }
        return str
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2)
            guard let byte = UInt8(clean[i ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            i = next
        }
        self = bytes
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func appendSSHString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }

    mutating func appendSSHString(_ value: String) {
        appendSSHString(Data(value.utf8))
    }
}

// MARK: - RFC 9106 Argon2 (for PPK v3 encrypted keys) + RFC 7693 BLAKE2b

private enum Argon2 {
    enum Variant: UInt32 {
        case argon2d = 0
        case argon2i = 1
        case argon2id = 2
    }

    private struct Block {
        var v = [UInt64](repeating: 0, count: 128)
    }

    static func derive(
        variant: Variant,
        password: Data,
        salt: Data,
        memoryKiB: Int,
        iterations: Int,
        parallelism: Int,
        outputLength: Int
    ) -> Data {
        let lanes = max(1, parallelism)
        let passes = max(1, iterations)
        let mPrime = max(8 * lanes, (memoryKiB / (4 * lanes)) * (4 * lanes))
        let q = mPrime / lanes
        let segmentLength = q / 4

        var h0Input = Data()
        appendLE32(&h0Input, UInt32(lanes))
        appendLE32(&h0Input, UInt32(outputLength))
        appendLE32(&h0Input, UInt32(memoryKiB))
        appendLE32(&h0Input, UInt32(passes))
        appendLE32(&h0Input, 0x13) // Argon2 v1.3
        appendLE32(&h0Input, variant.rawValue)
        appendLE32(&h0Input, UInt32(password.count))
        h0Input.append(password)
        appendLE32(&h0Input, UInt32(salt.count))
        h0Input.append(salt)
        appendLE32(&h0Input, 0) // secret
        appendLE32(&h0Input, 0) // associated data
        let h0 = Blake2b.hash(h0Input, outputLength: 64)

        var memory = [Block](repeating: Block(), count: mPrime)

        for lane in 0 ..< lanes {
            for blockIndex in 0 ..< 2 {
                var seed = h0
                appendLE32(&seed, UInt32(blockIndex))
                appendLE32(&seed, UInt32(lane))
                let bytes = hashPrime(seed, outputLength: 1024)
                memory[lane * q + blockIndex] = bytesToBlock(bytes)
            }
        }

        for pass in 0 ..< passes {
            for slice in 0 ..< 4 {
                let dataIndependent = (variant == .argon2i) || (variant == .argon2id && pass == 0 && slice < 2)
                for lane in 0 ..< lanes {
                    var addressBlock = Block()
                    var inputBlock = Block()
                    var zeroBlock = Block()
                    if dataIndependent {
                        inputBlock.v[0] = UInt64(pass)
                        inputBlock.v[1] = UInt64(lane)
                        inputBlock.v[2] = UInt64(slice)
                        inputBlock.v[3] = UInt64(mPrime)
                        inputBlock.v[4] = UInt64(passes)
                        inputBlock.v[5] = UInt64(variant.rawValue)
                    }

                    let startIndex = (pass == 0 && slice == 0) ? 2 : 0
                    for index in startIndex ..< segmentLength {
                        let curOffset = slice * segmentLength + index
                        let prevOffset = (curOffset == 0) ? (q - 1) : (curOffset - 1)
                        let curPos = lane * q + curOffset
                        let prevPos = lane * q + prevOffset

                        let j1: UInt64
                        let j2: UInt64
                        if dataIndependent {
                            if index % 128 == 0 {
                                inputBlock.v[6] += 1
                                addressBlock = compress(zeroBlock, compress(zeroBlock, inputBlock))
                            }
                            let word = addressBlock.v[index % 128]
                            j1 = word & 0xFFFF_FFFF
                            j2 = word >> 32
                        } else {
                            let word = memory[prevPos].v[0]
                            j1 = word & 0xFFFF_FFFF
                            j2 = word >> 32
                        }

                        var refLane = Int(j2 % UInt64(lanes))
                        if pass == 0 && slice == 0 { refLane = lane }

                        let refAreaSize: Int
                        if pass == 0 {
                            if slice == 0 {
                                refAreaSize = index - 1
                            } else if refLane == lane {
                                refAreaSize = slice * segmentLength + index - 1
                            } else {
                                refAreaSize = slice * segmentLength + (index == 0 ? -1 : 0)
                            }
                        } else {
                            if refLane == lane {
                                refAreaSize = q - segmentLength + index - 1
                            } else {
                                refAreaSize = q - segmentLength + (index == 0 ? -1 : 0)
                            }
                        }

                        var relPos = j1
                        relPos = (relPos &* relPos) >> 32
                        relPos = UInt64(refAreaSize) - 1 - ((UInt64(refAreaSize) &* relPos) >> 32)
                        let startPos = (pass != 0 && slice != 3) ? ((slice + 1) * segmentLength) : 0
                        let refIndex = (startPos + Int(relPos)) % q
                        let refPos = refLane * q + refIndex

                        let nextBlock = compress(memory[prevPos], memory[refPos])
                        if pass == 0 {
                            memory[curPos] = nextBlock
                        } else {
                            for k in 0 ..< 128 {
                                memory[curPos].v[k] ^= nextBlock.v[k]
                            }
                        }
                    }
                }
            }
        }

        var finalBlock = memory[q - 1]
        for lane in 1 ..< lanes {
            let last = memory[lane * q + (q - 1)]
            for k in 0 ..< 128 {
                finalBlock.v[k] ^= last.v[k]
            }
        }
        return hashPrime(blockToBytes(finalBlock), outputLength: outputLength)
    }

    private static func hashPrime(_ input: Data, outputLength: Int) -> Data {
        var prefixed = Data()
        appendLE32(&prefixed, UInt32(outputLength))
        prefixed.append(input)
        if outputLength <= 64 {
            return Blake2b.hash(prefixed, outputLength: outputLength)
        }
        let r = ((outputLength + 31) / 32) - 2
        var out = Data(capacity: outputLength)
        var v = Blake2b.hash(prefixed, outputLength: 64)
        out.append(v.prefix(32))
        for _ in 1 ..< r {
            v = Blake2b.hash(v, outputLength: 64)
            out.append(v.prefix(32))
        }
        let rem = outputLength - 32 * r
        out.append(Blake2b.hash(v, outputLength: rem))
        return out
    }

    private static func compress(_ x: Block, _ y: Block) -> Block {
        var r = Block()
        for i in 0 ..< 128 { r.v[i] = x.v[i] ^ y.v[i] }
        var z = r
        // Row-wise Blake2b round function P
        for i in 0 ..< 8 {
            let b = i * 16
            permute(
                &z.v,
                b + 0, b + 1, b + 2, b + 3,
                b + 4, b + 5, b + 6, b + 7,
                b + 8, b + 9, b + 10, b + 11,
                b + 12, b + 13, b + 14, b + 15
            )
        }
        // Column-wise Blake2b round function P
        for i in 0 ..< 8 {
            let b = i * 2
            permute(
                &z.v,
                b + 0, b + 1, b + 16, b + 17,
                b + 32, b + 33, b + 48, b + 49,
                b + 64, b + 65, b + 80, b + 81,
                b + 96, b + 97, b + 112, b + 113
            )
        }
        for i in 0 ..< 128 { z.v[i] ^= r.v[i] }
        return z
    }

    private static func gb(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        let aLo = v[a] & 0xFFFF_FFFF
        let bLo = v[b] & 0xFFFF_FFFF
        v[a] = v[a] &+ v[b] &+ (2 &* aLo &* bLo)
        v[d] = rotr(v[d] ^ v[a], 32)
        let cLo = v[c] & 0xFFFF_FFFF
        let dLo = v[d] & 0xFFFF_FFFF
        v[c] = v[c] &+ v[d] &+ (2 &* cLo &* dLo)
        v[b] = rotr(v[b] ^ v[c], 24)
        let aLo2 = v[a] & 0xFFFF_FFFF
        let bLo2 = v[b] & 0xFFFF_FFFF
        v[a] = v[a] &+ v[b] &+ (2 &* aLo2 &* bLo2)
        v[d] = rotr(v[d] ^ v[a], 16)
        let cLo2 = v[c] & 0xFFFF_FFFF
        let dLo2 = v[d] & 0xFFFF_FFFF
        v[c] = v[c] &+ v[d] &+ (2 &* cLo2 &* dLo2)
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    private static func permute(
        _ v: inout [UInt64],
        _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
        _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
        _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int,
        _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int
    ) {
        gb(&v, i0, i4, i8, i12)
        gb(&v, i1, i5, i9, i13)
        gb(&v, i2, i6, i10, i14)
        gb(&v, i3, i7, i11, i15)
        gb(&v, i0, i5, i10, i15)
        gb(&v, i1, i6, i11, i12)
        gb(&v, i2, i7, i8, i13)
        gb(&v, i3, i4, i9, i14)
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: Swift.withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    private static func bytesToBlock(_ bytes: Data) -> Block {
        var block = Block()
        bytes.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt64.self)
            for i in 0 ..< min(128, ptr.count) {
                block.v[i] = UInt64(littleEndian: ptr[i])
            }
        }
        return block
    }

    private static func blockToBytes(_ block: Block) -> Data {
        var out = Data(capacity: 1024)
        for word in block.v {
            out.append(contentsOf: Swift.withUnsafeBytes(of: word.littleEndian, Array.init))
        }
        return out
    }
}

private enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    static func hash(_ data: Data, outputLength: Int) -> Data {
        let outLen = max(1, min(64, outputLength))
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLen)

        let bytes = Array(data)
        var offset = 0
        var counter: UInt64 = 0

        if bytes.isEmpty {
            compress(&h, block: [UInt8](repeating: 0, count: 128), counter: 0, final: true)
        } else {
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let isFinal = remaining <= 128
                let take = min(128, remaining)
                var block = [UInt8](repeating: 0, count: 128)
                for i in 0 ..< take { block[i] = bytes[offset + i] }
                counter &+= UInt64(take)
                compress(&h, block: block, counter: counter, final: isFinal)
                offset += take
            }
        }

        var out = Data(capacity: 64)
        for word in h {
            out.append(contentsOf: Swift.withUnsafeBytes(of: word.littleEndian, Array.init))
        }
        return Data(out.prefix(outLen))
    }

    private static func compress(_ h: inout [UInt64], block: [UInt8], counter: UInt64, final: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0 ..< 16 {
            let b = i * 8
            var word: UInt64 = 0
            for j in 0 ..< 8 { word |= UInt64(block[b + j]) << (UInt64(j) * 8) }
            m[i] = word
        }
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0 ..< 8 {
            v[i] = h[i]
            v[i + 8] = iv[i]
        }
        v[12] ^= counter
        if final { v[14] = ~v[14] }

        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 63)
        }

        for r in 0 ..< 12 {
            let s = sigma[r]
            g(0, 4, 8, 12, m[s[0]], m[s[1]])
            g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]])
            g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]])
            g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]])
            g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0 ..< 8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }
}

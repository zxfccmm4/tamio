//
//  PuTTYKeyConverterTests.swift
//  TamioModuleTests
//

import CryptoKit
import Foundation
@testable import TamioModule
import XCTest

final class PuTTYKeyConverterTests: XCTestCase {
    private func makeUnencryptedEd25519PPK(version: Int, comment: String = "test-ed25519") -> (ppk: String, expectedPubPrefix: String) {
        let seed = Data((0 ..< 32).map { UInt8($0) })
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pubBytes = key.publicKey.rawRepresentation

        func sshStr(_ data: Data) -> Data {
            var out = Data()
            var len = UInt32(data.count).bigEndian
            out.append(contentsOf: withUnsafeBytes(of: &len, Array.init))
            out.append(data)
            return out
        }

        let pubBlob = sshStr(Data("ssh-ed25519".utf8)) + sshStr(pubBytes)
        let privBlob = sshStr(seed)

        let macInput = sshStr(Data("ssh-ed25519".utf8))
            + sshStr(Data("none".utf8))
            + sshStr(Data(comment.utf8))
            + sshStr(pubBlob)
            + sshStr(privBlob)

        let macHex: String
        if version == 2 {
            let macKey = Data(Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8)))
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: macInput, using: SymmetricKey(data: macKey))
            macHex = mac.map { String(format: "%02x", $0) }.joined()
        } else {
            let mac = HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: Data()))
            macHex = mac.map { String(format: "%02x", $0) }.joined()
        }

        let ppk = """
        PuTTY-User-Key-File-\(version): ssh-ed25519
        Encryption: none
        Comment: \(comment)
        Public-Lines: 1
        \(pubBlob.base64EncodedString())
        Private-Lines: 1
        \(privBlob.base64EncodedString())
        Private-MAC: \(macHex)
        """
        return (ppk, "ssh-ed25519 \(pubBlob.base64EncodedString())")
    }

    func testConvertsUnencryptedPPKv2Andv3Ed25519() throws {
        for version in [2, 3] {
            let (ppk, pubPrefix) = makeUnencryptedEd25519PPK(version: version)
            XCTAssertTrue(PuTTYKeyConverter.isPuTTYKey(ppk))
            let converted = try PuTTYKeyConverter.convert(ppk)
            XCTAssertEqual(converted.algorithm, "ssh-ed25519")
            XCTAssertTrue(converted.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
            XCTAssertTrue(converted.privateKey.contains("-----END OPENSSH PRIVATE KEY-----"))
            XCTAssertTrue(converted.publicKey.hasPrefix(pubPrefix))
        }
    }

    func testRejectsCorruptedMAC() {
        let (ppk, _) = makeUnencryptedEd25519PPK(version: 3)
        let tampered = ppk.replacingOccurrences(of: "Comment: test-ed25519", with: "Comment: tampered")
        XCTAssertThrowsError(try PuTTYKeyConverter.convert(tampered)) { error in
            XCTAssertEqual(error as? PuTTYKeyError, .wrongPassphraseOrCorrupt)
        }
    }
}

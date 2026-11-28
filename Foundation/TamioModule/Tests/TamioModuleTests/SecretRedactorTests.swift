//
//  SecretRedactorTests.swift
//  TamioModuleTests
//

import Foundation
@testable import TamioModule
import XCTest

final class SecretRedactorTests: XCTestCase {
    func testRedactsPEMPrivateKeyBlock() {
        let sample = """
        $ cat ~/.ssh/id_ed25519
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBfakekeybytes0123456789abcdefghijklmnopqrstuvwxyz==
        -----END OPENSSH PRIVATE KEY-----
        done
        """
        let result = SecretRedactor.redact(sample)
        XCTAssertTrue(result.didRedact)
        XCTAssertTrue(result.text.contains("[REDACTED PRIVATE KEY]"))
        XCTAssertFalse(result.text.contains("b3BlbnNzaC"))
        XCTAssertTrue(result.text.contains("done"))
    }

    func testRedactsTruncatedPrivateKeyBlock() {
        let sample = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7M
        clipped-by-screen-limit
        """
        let result = SecretRedactor.redact(sample)
        XCTAssertTrue(result.didRedact)
        XCTAssertTrue(result.text.contains("[REDACTED PRIVATE KEY]"))
        XCTAssertFalse(result.text.contains("MIIEowIBAA"))
    }

    func testRedactsURLCredentialsAndPreservesPlainURLs() {
        let sample = """
        DATABASE_URL=postgres://admin:s3cr3tPass!@db.internal:5432/prod
        Homepage: https://tamio.sh:443/docs
        """
        let result = SecretRedactor.redact(sample)
        XCTAssertTrue(result.text.contains("postgres://admin:[REDACTED]@db.internal:5432/prod"))
        XCTAssertTrue(result.text.contains("https://tamio.sh:443/docs"))
    }

    func testRedactsAuthorizationHeadersAndKnownTokens() {
        let sample = """
        Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        GITHUB=ghp_1234567890abcdefghijklmnopqrstuvwx
        OPENAI=sk-proj-1234567890abcdefghijklmnopqrstuvwx
        AWS=AKIAIOSFODNN7EXAMPLE
        """
        let result = SecretRedactor.redact(sample)
        XCTAssertGreaterThanOrEqual(result.redactionCount, 4)
        XCTAssertFalse(result.text.contains("ghp_123456"))
        XCTAssertFalse(result.text.contains("sk-proj-123456"))
        XCTAssertFalse(result.text.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(result.text.contains("dozjgNryP4J3"))
    }

    func testRedactsShellAndJSONSecretAssignmentsWithoutOverRedactingPlaceholders() {
        let sample = """
        export DB_PASSWORD="super-secret-value"
        API_TOKEN=live_token_99887766
        "client_secret": "my-oauth-secret-123"
        PASSWORD=$ENV_PASSWORD
        AUTH_TOKEN=<insert-token>
        password_enabled: true
        commit 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b
        """
        let result = SecretRedactor.redact(sample)
        XCTAssertFalse(result.text.contains("super-secret-value"))
        XCTAssertFalse(result.text.contains("live_token_99887766"))
        XCTAssertFalse(result.text.contains("my-oauth-secret-123"))
        XCTAssertTrue(result.text.contains("PASSWORD=$ENV_PASSWORD"))
        XCTAssertTrue(result.text.contains("AUTH_TOKEN=<insert-token>"))
        XCTAssertTrue(result.text.contains("password_enabled: true"))
        XCTAssertTrue(result.text.contains("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"))
    }
}

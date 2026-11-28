//
//  FileTransferContext+Editing.swift
//  TamioModule
//
//  Reading a remote file as text and writing it back atomically, with SHA-256
//  conflict detection before overwrite and POSIX permission preservation.
//

import CryptoKit
import Foundation
import NSRemoteShell

/// Snapshot of a remote UTF-8 file captured when opened in the editor.
public struct RemoteTextDocument: Equatable, Sendable {
    public let path: String
    public let text: String
    public let sha256: Data
    public let size: Int64?
    public let modifiedAt: Date?
    public let permissions: UInt?

    public init(
        path: String,
        text: String,
        sha256: Data,
        size: Int64?,
        modifiedAt: Date?,
        permissions: UInt?
    ) {
        self.path = path
        self.text = text
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }

    public static func sha256Digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

public enum RemoteTextFileError: LocalizedError, Equatable {
    case notConnected
    case tooLarge(bytes: Int64, limit: Int64)
    case notText
    case remoteModified(currentModifiedAt: Date?, currentSize: Int64?)
    case transfer(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to the server.")
        case let .tooLarge(bytes, limit):
            let formatter = ByteCountFormatter()
            return String(localized: "This file is \(formatter.string(fromByteCount: bytes)); files up to \(formatter.string(fromByteCount: limit)) open in the editor. Download it instead.")
        case .notText:
            return String(localized: "This file isn't UTF-8 text, so it can't be edited here. Download it instead.")
        case .remoteModified:
            return String(localized: "This file changed on the server after you opened it. Reload the remote version or overwrite it anyway.")
        case let .transfer(message):
            return message
        }
    }
}

public extension FileTransferContext {
    /// Files larger than this are downloaded rather than opened in the editor.
    static let editableSizeLimit: Int64 = 4 * 1024 * 1024

    /// Reads a remote file as UTF-8 text alongside its hash, metadata and permissions.
    func readTextDocument(at remotePath: String) async throws -> RemoteTextDocument {
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
        nonisolated(unsafe) let shell = shell
        let info: (size: Int64?, modifiedAt: Date?, permissions: UInt?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let file = shell.requestFileInfo(at: remotePath)
                let perms: UInt? = file.map { UInt($0.permissions & 0o7777) }
                continuation.resume(returning: (file?.size?.int64Value, file?.modificationDate, perms))
            }
        }
        if let size = info.size, size > Self.editableSizeLimit {
            throw RemoteTextFileError.tooLarge(bytes: size, limit: Self.editableSizeLimit)
        }
        let succeeded = await Self.background {
            shell.requestDownload(fromFileAndWait: remotePath, toLocalPath: local.path) { _, _, _ in
            } withContinuationHandler: {
                true
            }
        }
        guard succeeded else {
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? String(localized: "Couldn't read \(remotePath)."))
        }
        let data = try Data(contentsOf: local)
        guard Int64(data.count) <= Self.editableSizeLimit else {
            throw RemoteTextFileError.tooLarge(bytes: Int64(data.count), limit: Self.editableSizeLimit)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw RemoteTextFileError.notText
        }
        return RemoteTextDocument(
            path: remotePath,
            text: text,
            sha256: RemoteTextDocument.sha256Digest(of: data),
            size: info.size ?? Int64(data.count),
            modifiedAt: info.modifiedAt,
            permissions: info.permissions
        )
    }

    /// Reads a remote file as UTF-8 text.
    func readText(at remotePath: String) async throws -> String {
        try await readTextDocument(at: remotePath).text
    }

    /// Writes `text` atomically to `remotePath` (staging to a sibling temp file,
    /// preserving original permissions, and renaming into place). When `expected`
    /// is supplied and `force` is false, verifies the remote file has not changed
    /// since it was loaded and throws `.remoteModified` if a conflict is detected.
    @discardableResult
    func writeTextDocument(
        _ text: String,
        to remotePath: String,
        expected: RemoteTextDocument? = nil,
        force: Bool = false
    ) async throws -> RemoteTextDocument {
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let remote = URL(fileURLWithPath: remotePath)
        let directory = remote.deletingLastPathComponent().path
        let payload = Data(text.utf8)
        let local = folder.appendingPathComponent(remote.lastPathComponent)
        try payload.write(to: local)

        nonisolated(unsafe) let shell = shell

        // 1. Inspect current remote state for permission preservation and conflict detection.
        let currentInfo: (exists: Bool, size: Int64?, modifiedAt: Date?, permissions: UInt?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let file = shell.requestFileInfo(at: remotePath) {
                    continuation.resume(returning: (true, file.size?.int64Value, file.modificationDate, UInt(file.permissions & 0o7777)))
                } else {
                    continuation.resume(returning: (false, nil, nil, nil))
                }
            }
        }

        if !force, let expected, currentInfo.exists {
            let metadataChanged = (currentInfo.size != expected.size)
                || (currentInfo.modifiedAt != expected.modifiedAt)
            if metadataChanged {
                // Verify by SHA-256 before reporting a conflict so coarse mtime rounding never false-triggers.
                let verifyLocal = folder.appendingPathComponent("verify-\(UUID().uuidString)")
                let downloaded = await Self.background {
                    shell.requestDownload(fromFileAndWait: remotePath, toLocalPath: verifyLocal.path) { _, _, _ in
                    } withContinuationHandler: {
                        true
                    }
                }
                if downloaded, let remoteData = try? Data(contentsOf: verifyLocal) {
                    if RemoteTextDocument.sha256Digest(of: remoteData) != expected.sha256 {
                        throw RemoteTextFileError.remoteModified(
                            currentModifiedAt: currentInfo.modifiedAt,
                            currentSize: currentInfo.size ?? Int64(remoteData.count)
                        )
                    }
                } else {
                    throw RemoteTextFileError.remoteModified(
                        currentModifiedAt: currentInfo.modifiedAt,
                        currentSize: currentInfo.size
                    )
                }
            }
        }

        let targetPermissions = currentInfo.permissions ?? expected?.permissions

        // 2. Stage to a sibling temporary file, preserve permissions, then atomically rename into place.
        let tempName = ".tamio-tmp-\(UUID().uuidString.prefix(12))"
        let tempRemotePath = (directory as NSString).appendingPathComponent(tempName)

        let staged = await Self.background {
            let uploaded = shell.requestUpload(forFileAndWait: local.path, toDirectory: directory, named: tempName) { _, _, _ in
            } withContinuationHandler: {
                true
            }
            guard uploaded else {
                _ = shell.requestDelete(forFileAndWait: tempRemotePath, withProgressBlock: { _ in }, withContinuationHandler: { true })
                return false
            }
            if let mode = targetPermissions, mode != 0 {
                _ = shell.requestSetPermissionsAndWait(mode, atPath: tempRemotePath)
            }
            if shell.requestRenameFileAndWait(tempRemotePath, withNewPath: remotePath) {
                return true
            }
            // Fallback for non-POSIX SFTP v3 servers that refuse rename-over-existing:
            // overwrite directly only after staging failed rename, cleaning up temp file.
            _ = shell.requestDelete(forFileAndWait: tempRemotePath, withProgressBlock: { _ in }, withContinuationHandler: { true })
            let direct = shell.requestUpload(forFileAndWait: local.path, toDirectory: directory, named: remote.lastPathComponent) { _, _, _ in
            } withContinuationHandler: {
                true
            }
            if direct, let mode = targetPermissions, mode != 0 {
                _ = shell.requestSetPermissionsAndWait(mode, atPath: remotePath)
            }
            return direct
        }

        guard staged else {
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? String(localized: "Couldn't save \(remotePath)."))
        }

        let refreshedInfo: (size: Int64?, modifiedAt: Date?, permissions: UInt?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let file = shell.requestFileInfo(at: remotePath)
                continuation.resume(returning: (file?.size?.int64Value, file?.modificationDate, file.map { UInt($0.permissions & 0o7777) }))
            }
        }

        return RemoteTextDocument(
            path: remotePath,
            text: text,
            sha256: RemoteTextDocument.sha256Digest(of: payload),
            size: refreshedInfo.size ?? Int64(payload.count),
            modifiedAt: refreshedInfo.modifiedAt,
            permissions: refreshedInfo.permissions ?? targetPermissions
        )
    }

    /// Replaces a remote file's contents with `text` (UTF-8) atomically while preserving permissions.
    func writeText(_ text: String, to remotePath: String) async throws {
        _ = try await writeTextDocument(text, to: remotePath, expected: nil, force: true)
    }

    private static func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TamioEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs a blocking shell call off the main thread.
    private static func background(_ work: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

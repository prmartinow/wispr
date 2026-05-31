import Foundation
import Darwin

/// Helpers for transcript/audio artifacts that should only be readable by this user.
enum PrivateFiles {
    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    static func lockDownIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o600)
    }

    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        ensureDirectory(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let ok = FileManager.default.createFile(
            atPath: tmp.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        guard ok else { throw CocoaError(.fileWriteUnknown) }
        chmod(tmp.path, 0o600)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        chmod(url.path, 0o600)
    }
}

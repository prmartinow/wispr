import Foundation
import os

/// Lightweight logger: writes to the unified log (Console.app) *and* a tail-able file at
/// ~/Library/Logs/wispr/wispr.log so issues (hotkey registration, permissions, request
/// timing/errors) are diagnosable after the fact — even when launched via `open`.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/wispr", isDirectory: true)
        PrivateFiles.ensureDirectory(dir)
        let file = dir.appendingPathComponent("wispr.log")
        PrivateFiles.lockDownIfPresent(file)
        return file
    }()

    private static let oslog = os.Logger(subsystem: "xyz.p12w.wispr", category: "app")
    private static let queue = DispatchQueue(label: "xyz.p12w.wispr.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        oslog.log("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? PrivateFiles.write(Data(line.utf8), to: fileURL)
            }
            chmod(fileURL.path, 0o600)
        }
    }
}

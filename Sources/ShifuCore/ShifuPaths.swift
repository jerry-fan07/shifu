import Foundation

/// Storage layout (design.md §9). Everything lives under one folder,
/// overridable via SHIFU_HOME for tests and the perf harness.
public enum ShifuPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["SHIFU_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Shifu", isDirectory: true)
    }

    public static var database: URL { home.appendingPathComponent("shifu.db") }
    public static var vault: URL { home.appendingPathComponent("vault", isDirectory: true) }
    public static var digests: URL { home.appendingPathComponent("digests", isDirectory: true) }
    public static var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    /// Control file: presence with a future unix-seconds expiry means capture is paused (§8).
    public static var pauseFile: URL { home.appendingPathComponent("pause_until") }
    /// Control file: presence means Work Mode is on (§4.4).
    public static var workModeFile: URL { home.appendingPathComponent("work_mode") }

    public static func ensureHomeExists() throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]   // owner-only (§8)
        )
    }
}

/// Identity of a control file, not merely its existence.
///
/// Control files are toggled by creating and deleting them, and the directory
/// watchers that observe them are edge-triggered while their handlers sample
/// state *when they run*. An off→on that completes between two handler runs is
/// therefore invisible to a `fileExists` check — the file is already back.
/// Comparing identity instead catches it: the new file has a different inode
/// and birth time, so a genuinely new session is distinguishable from no change.
///
/// Both fields are needed. Inodes are recycled, so a fresh file can land on the
/// number the old one just freed; birth times disambiguate those.
public struct ControlFileToken: Equatable, Sendable {
    public let inode: UInt64
    public let createdAt: Int64   // nanoseconds since the epoch

    /// nil when the file doesn't exist — i.e. the control file is "off".
    public init?(at url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        createdAt = Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_birthtimespec.tv_nsec)
    }
}

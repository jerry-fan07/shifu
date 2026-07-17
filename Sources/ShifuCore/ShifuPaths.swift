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
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
}

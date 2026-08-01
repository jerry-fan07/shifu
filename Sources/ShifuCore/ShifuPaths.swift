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
    /// Control file: presence means Focus Mode is on (§4.4).
    public static var focusModeFile: URL { home.appendingPathComponent("focus_mode") }
    /// What `focusModeFile` was called before Focus Mode was called that.
    /// Read once at startup by `FocusModeFile.adoptLegacyName`, never written.
    public static var legacyFocusModeFile: URL { home.appendingPathComponent("work_mode") }

    /// Locates a helper executable (shifu-analyzer, shifud, …). Helpers ship
    /// as siblings of the running binary — Contents/MacOS in the app bundle,
    /// the build directory in development — so the sibling is checked first.
    /// Resolved from the executable path rather than Bundle.main because
    /// shifud is launched by launchd from inside the bundle, where Bundle.main
    /// is ambiguous. Dev installs that scatter binaries into ~/Shifu/bin
    /// (install-daemon.sh) are the fallback. Nil when neither location has an
    /// executable file — callers already treat a missing helper as
    /// graceful degradation, never an error.
    public static func helper(_ name: String) -> URL? {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        let devBin = home
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(name)
        return [sibling, devBin].first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

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

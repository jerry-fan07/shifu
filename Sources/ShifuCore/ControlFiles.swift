import Foundation

/// The pause control file (design.md §8), read and written in one place.
///
/// There is no IPC in Shifu: `shifu pause`, the app's pause button and the
/// daemon's watcher agree only because they agree on this file's format —
/// a unix-**seconds** expiry as ASCII digits, where an expiry in the past
/// reads as "not paused" so a stale file can never wedge capture off.
///
/// That format used to be parsed three times (`shifu-cli`, `PauseController`,
/// `LedgerStore`), which meant changing it broke two callers silently. One
/// implementation is the fix; the tests cover every caller at once.
///
/// Every entry point takes an optional `home` so the file can be pointed
/// somewhere else without touching the process environment — `SHIFU_HOME` is
/// global state, and tests that mutate it can only ever run one at a time.
public enum PauseFile {
    static func file(in home: URL?) -> URL {
        home.map { $0.appendingPathComponent("pause_until") } ?? ShifuPaths.pauseFile
    }

    /// When capture resumes, or nil when it is not paused. An expiry at or
    /// before `now` is not a pause.
    public static func expiry(now: Date = Date(), home: URL? = nil) -> Date? {
        guard let raw = try? String(contentsOf: file(in: home), encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              // A file holding "inf", "nan" or an overflowing literal parses to
              // a non-finite Double, and a pause that never expires is exactly
              // the wedged-off state the "past expiry" rule exists to prevent.
              seconds.isFinite
        else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date > now ? date : nil
    }

    public static func isPaused(now: Date = Date(), home: URL? = nil) -> Bool {
        expiry(now: now, home: home) != nil
    }

    /// Writes the expiry. Whole seconds, so the file stays the ASCII integer
    /// every reader expects.
    public static func pause(until: Date, home: URL? = nil) throws {
        if home == nil { try ShifuPaths.ensureHomeExists() }
        try String(Int(until.timeIntervalSince1970))
            .write(to: file(in: home), atomically: true, encoding: .utf8)
    }

    public static func resume(home: URL? = nil) {
        try? FileManager.default.removeItem(at: file(in: home))
    }

    /// The CLI's duration vocabulary (`shifu pause 30m`). Nil for anything
    /// else, so the caller can print the usage line rather than guess.
    public static func duration(_ spec: String, now: Date = Date(),
                                calendar: Calendar = .current) -> TimeInterval? {
        switch spec {
        case "30m": return 1_800
        case "1h": return 3_600
        case "2h": return 7_200
        case "tomorrow":
            return calendar.startOfDay(for: now.addingTimeInterval(86_400))
                .timeIntervalSince(now)
        default: return nil
        }
    }
}

/// The Focus Mode control file (design.md §4.4). Presence alone is the state;
/// contents are ignored, which is why the daemon watches *identity*
/// (`ControlFileToken`) rather than mtime — see that type for why.
public enum FocusModeFile {
    static func file(in home: URL?) -> URL {
        home.map { $0.appendingPathComponent("focus_mode") } ?? ShifuPaths.focusModeFile
    }

    static func legacyFile(in home: URL?) -> URL {
        home.map { $0.appendingPathComponent("work_mode") } ?? ShifuPaths.legacyFocusModeFile
    }

    /// Carries a pre-rename `work_mode` file over to `focus_mode`.
    ///
    /// Moved rather than recreated, because `rename(2)` keeps the inode and
    /// birth time: Focus Mode left on across an upgrade keeps the same
    /// `ControlFileToken`, so the daemon reads it as the session it already
    /// has rather than ending one and starting another under the user.
    ///
    /// Every entry point calls this before it reads, so it does not matter
    /// which of the three — daemon, app, CLI — runs first after the upgrade.
    /// Idempotent, and after the first run it costs one `stat` on a path that
    /// no longer exists.
    public static func adoptLegacyName(home: URL? = nil) {
        let manager = FileManager.default
        let legacy = legacyFile(in: home)
        guard manager.fileExists(atPath: legacy.path) else { return }
        // Both names present means an older binary has been toggling the old
        // one alongside a newer binary on the new one. The new name is the
        // live state; the stale file is dropped rather than allowed to win.
        if manager.fileExists(atPath: file(in: home).path) {
            try? manager.removeItem(at: legacy)
        } else {
            try? manager.moveItem(at: legacy, to: file(in: home))
        }
    }

    public static func isOn(home: URL? = nil) -> Bool {
        adoptLegacyName(home: home)
        return FileManager.default.fileExists(atPath: file(in: home).path)
    }

    /// When the switch was flipped on, or nil when Focus Mode is off.
    ///
    /// The control file's *birth time* is the session start — the file is
    /// created by the flip and nothing rewrites it, so this is the same moment
    /// the daemon stamps into `focus_mode_sessions.started_at` when it notices,
    /// minus the noticing. Read from the file rather than from that row on
    /// purpose: the row appears a filesystem event later, and doesn't appear at
    /// all when the daemon isn't running — a stopwatch that needs a healthy
    /// daemon to start is a stopwatch that stays at zero exactly when the user
    /// is watching it.
    ///
    /// Survives the `work_mode` rename for the reason `adoptLegacyName`
    /// documents: `rename(2)` keeps the birth time, so a session left on across
    /// an upgrade keeps its start too.
    public static func startedAt(home: URL? = nil) -> Date? {
        adoptLegacyName(home: home)
        guard let token = ControlFileToken(at: file(in: home)) else { return nil }
        return Date(timeIntervalSince1970: Double(token.createdAt) / 1_000_000_000)
    }

    public static func turnOn(home: URL? = nil) throws {
        if home == nil { try ShifuPaths.ensureHomeExists() }
        adoptLegacyName(home: home)
        try Data().write(to: file(in: home))
    }

    public static func turnOff(home: URL? = nil) {
        adoptLegacyName(home: home)
        try? FileManager.default.removeItem(at: file(in: home))
    }
}

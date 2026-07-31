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
        home.map { $0.appendingPathComponent("work_mode") } ?? ShifuPaths.focusModeFile
    }

    public static func isOn(home: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: file(in: home).path)
    }

    public static func turnOn(home: URL? = nil) throws {
        if home == nil { try ShifuPaths.ensureHomeExists() }
        try Data().write(to: file(in: home))
    }

    public static func turnOff(home: URL? = nil) {
        try? FileManager.default.removeItem(at: file(in: home))
    }
}

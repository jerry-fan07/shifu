import Foundation

/// The two clocks Focus Mode runs (design.md §4.4).
///
/// A focus contract you can't see the length of is a contract you have to
/// guess at, so the switch carries a stopwatch — and beside it the other half
/// of the same question: *how long has it been since the last one*. Both are
/// read from facts that already exist (the control file's birth time, the last
/// closed session's end), never from a counter this process has to keep
/// running — so the reading survives a relaunch, and an app that was closed
/// for the whole session still opens showing the right number.
///
/// Pure arithmetic over three moments, like `FocusReport`: no clock of its own,
/// no database, so both clocks can be checked in a test.
public enum FocusClock {
    /// What the two clocks read at one instant.
    public struct Reading: Equatable, Sendable {
        /// How long the running session has been going, or nil when Focus
        /// Mode is off.
        public var elapsed: TimeInterval?
        /// The gap around this reading — and it means two different things on
        /// purpose, because "since the previous session" does:
        ///
        /// - While Focus Mode is **on**, it is the time that passed *before*
        ///   this session started. Frozen: counting from the last session's
        ///   end through the running one would be a number that grows while
        ///   you focus, which is exactly backwards.
        /// - While Focus Mode is **off**, it is the time since the last
        ///   session ended, and it runs.
        ///
        /// Nil when there is no earlier session to be away from.
        public var away: TimeInterval?

        public var isRunning: Bool { elapsed != nil }

        public init(elapsed: TimeInterval? = nil, away: TimeInterval? = nil) {
            self.elapsed = elapsed
            self.away = away
        }
    }

    /// Both clocks at `now`.
    ///
    /// - Parameters:
    ///   - startedAt: when the running session began, or nil when Focus Mode
    ///     is off — `FocusModeFile.startedAt()`.
    ///   - previousEnd: when the last session before this reading ended, or
    ///     nil for none — `FocusModeSessions.previousEnd(before:)`.
    ///
    /// Every interval is clamped at zero: a control file with a birth time in
    /// the future (a clock that stepped back, a restored backup) should read
    /// as a session that has just started, never as a negative stopwatch.
    public static func reading(
        now: Date, startedAt: Date?, previousEnd: Date?
    ) -> Reading {
        guard let startedAt else {
            return Reading(elapsed: nil, away: previousEnd.map { gap(from: $0, to: now) })
        }
        return Reading(
            elapsed: gap(from: startedAt, to: now),
            away: previousEnd.map { gap(from: $0, to: startedAt) })
    }

    private static func gap(from: Date, to: Date) -> TimeInterval {
        max(0, to.timeIntervalSince(from))
    }

    /// A running session, as a stopwatch: `0:07`, `12:04`, `1:02:11`.
    ///
    /// Deliberately not the ledger's `3s` / `12m` / `1h 5m` vocabulary. That
    /// one is for durations already in the books; this one ticks, and a clock
    /// that ticks should look like a clock — the seconds are what say the
    /// reading is live without anything else having to.
    public static func stopwatch(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3_600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// A gap, in the coarsest unit that still says something: `48s`, `34m`,
    /// `3h 20m`, `2d`.
    ///
    /// Days rather than the ledger's hours at the top end, because this figure
    /// is routinely a day or more old — "last focus 74h 12m ago" is a number
    /// nobody reads as "the day before yesterday", and minutes stopped
    /// mattering long before that.
    public static func since(_ gap: TimeInterval) -> String {
        let seconds = Int(max(0, gap))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d"
    }
}

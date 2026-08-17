import Foundation

/// The seam between the announcement policy and whatever delivers it
/// (design.md §4.5).
///
/// Delivery is **poll-only, coordinated through the database** — the same
/// no-IPC rule the rest of Shifu runs on (ARCHITECTURE.md §1). Nothing is
/// handed to the system to fire later, and that is a decision rather than a
/// shortcut: `UNUserNotificationCenter`'s pending queue would be a second state
/// store the CLI cannot reach, so `shifu due done` could not silence a banner
/// already scheduled, and a notice delivered while the app was closed could not
/// stamp the row that stops it being delivered again. Both failures are the one
/// the tests care most about — a reminder that repeats.
///
/// The cost of that choice, stated plainly because it is real: nothing arrives
/// while Shifu is not running. Reminders resume, in order and each still only
/// once, on the next launch.
public enum DeadlineReminders {
    /// What the user has asked for, read fresh on every poll so a change in
    /// Settings takes effect on the next tick rather than the next launch.
    public struct Preferences: Equatable, Sendable {
        public var enabled: Bool
        public var progress: Bool
        public var hour: Int

        public init(enabled: Bool, progress: Bool, hour: Int) {
            self.enabled = enabled
            self.progress = progress
            self.hour = hour
        }
    }

    public static func preferences(database: ShifuDatabase) -> Preferences {
        Preferences(
            enabled: Settings.value(SettingsCatalog.remindersEnabled, database: database) == "on",
            progress: Settings.value(SettingsCatalog.remindersProgress, database: database) == "on",
            hour: Settings.value(SettingsCatalog.remindersHour, database: database))
    }

    /// Everything that should be delivered right now, in the order it should be
    /// read: soonest deadline first, and a date notice before the progress
    /// notice for the same deadline.
    ///
    /// Returns empty when reminders are off — the queue is still readable by
    /// `shifu due` and the app, which is the difference between "don't interrupt
    /// me" and "stop tracking this".
    public static func due(
        database: ShifuDatabase, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        calendar: Calendar = .current
    ) throws -> [DeadlineAnnouncement] {
        let preferences = self.preferences(database: database)
        guard preferences.enabled else { return [] }
        return try DeadlineStore.open(database: database)
            .flatMap { standing in
                DeadlineHorizon.announcements(
                    for: standing, now: now, hour: preferences.hour, calendar: calendar)
            }
            .filter { preferences.progress || $0.notch == nil }
    }

    /// Whether there is anything at all to be reminded *about* — the gate on
    /// asking for notification permission. A user who has never typed a date
    /// should never see that prompt: the request is the first moment Shifu asks
    /// for something, and asking before there is a reason is how an app teaches
    /// people to say no.
    public static func hasSomethingToRemind(database: ShifuDatabase) throws -> Bool {
        try !DeadlineStore.open(database: database).isEmpty
    }

    /// Marks one announcement delivered. Called *after* the notification is
    /// handed over, so the failure this ordering picks is a repeated reminder
    /// rather than a silent one — and only one of those the user can recover
    /// from.
    public static func record(
        _ announcement: DeadlineAnnouncement, database: ShifuDatabase
    ) throws {
        try DeadlineStore.stamp(announcement, database: database)
    }
}

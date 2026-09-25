import Foundation

/// The Reminders section's settings (design.md §4.5), split from
/// SettingsCatalog.swift for that file's length only — the catalog is one type,
/// and these are an extension of it, so `ints`/`choices` still list them and the
/// Settings page still renders itself with no per-setting code.
extension SettingsCatalog {
    // Reminders (design.md §4.5). Default *on*, which looks like it contradicts
    // §1's "not a stream of notifications" and does not: the queue is empty
    // until the user types a date, so an untouched Shifu is as silent with this
    // on as off. What is bounded is the schedule per promise — four notices over
    // a deadline's life (`DeadlineHorizon.leads`), not a rate limit over a feed.
    public static let remindersEnabled = ChoiceSetting(
        key: "reminders.enabled", section: .reminders,
        title: "Deadline reminders",
        help: "Notifies you as a date you gave Shifu comes up — a week out, "
            + "three days, the day before, the day itself, and once if it slips.",
        options: [
            .init(
                value: "on", label: "On",
                detail: "Shifu posts a notification for each of those five "
                    + "moments, once each. Deadlines you mark done go quiet "
                    + "immediately, including ones already past."),
            .init(
                value: "off", label: "Off",
                detail: "Nothing is posted. Deadlines still appear in the app "
                    + "and in `shifu due`, and their dates and progress are "
                    + "still tracked — you just have to look.")
        ],
        defaultValue: "on"
    )

    public static let remindersProgress = ChoiceSetting(
        key: "reminders.progress", section: .reminders,
        title: "Progress reports",
        help: "For a deadline you also gave a time target, notifies you as you "
            + "pass each quarter of it. This is the half only Shifu can tell "
            + "you: the hours come from the ledger, not from you logging them.",
        options: [
            .init(
                value: "on", label: "On",
                detail: "Four notices at most — 25%, 50%, 75% and the whole "
                    + "target — each once, from time already in your ledger."),
            .init(value: "off", label: "Off", detail: "Dates only.")
        ],
        defaultValue: "on",
        visibleWhen: (key: "reminders.enabled", value: "on")
    )

    public static let remindersHour = IntSetting(
        key: "reminders.hour", section: .reminders,
        title: "Reminder time",
        help: "When the day's reminders arrive. A deadline with a time of its "
            + "own uses that time on the day it falls due, and this hour for "
            + "every earlier notice.",
        defaultValue: 9, range: 5...22, step: 1, unit: .hourOfDay,
        visibleWhen: (key: "reminders.enabled", value: "on")
    )
}

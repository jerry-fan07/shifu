import Foundation
import ShifuCore
import Testing

/// The seam between the announcement policy and delivery (design.md §4.5).
///
/// `DeadlineReminders` is where the user's settings meet the policy, and where
/// "delivered" is written back. Both halves are worth pinning: a setting that
/// silently fails to silence is the bug that makes someone uninstall, and a
/// stamp that doesn't stick is the bug that makes them mute Shifu in System
/// Settings and never hear from it again.
@Suite struct DeadlineRemindersTests {
    private let hour: Int64 = 3_600_000

    /// A deadline three days out with half its target logged — so a date notice
    /// *and* a progress notice are both due, and each setting can be seen to
    /// silence exactly one of them.
    private func harness() throws -> (ShifuDatabase, now: Int64) {
        let database = try ShifuDatabase.inMemory()
        // Local noon today, so the reminder hour has passed whatever the run's
        // wall clock — the hour gate is pinned in DeadlineHorizonTests.
        let noon = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let now = Int64(noon.timeIntervalSince1970 * 1_000)
        let due = Int64(
            (Calendar.current.date(byAdding: .day, value: 3, to: noon) ?? noon)
                .timeIntervalSince1970 * 1_000)

        let taskID = try database.queue.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO tasks (key, name, created_at, last_active_at) VALUES (?,?,?,?)",
                arguments: ["sem:thesis", "Thesis", 0, 0])
            let taskID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO activities
                      (started_at, ended_at, app_bundle, category, source, task_id)
                    VALUES (?, ?, 'com.apple.Pages', 'work', 'rules', ?)
                    """,
                arguments: [now - 100 * hour, now - 90 * hour, taskID])
            return taskID
        }
        try DeadlineStore.create(
            title: "Thesis draft", dueAt: due, taskID: taskID, targetMs: 20 * hour,
            now: now - 200 * hour, database: database)
        return (database, now)
    }

    @Test func bothNoticesArriveWithTheDefaultSettings() throws {
        let (database, now) = try harness()
        let due = try DeadlineReminders.due(database: database, now: now)
        #expect(due.count == 2)
        #expect(due.contains { $0.lead == 3 })
        #expect(due.contains { $0.notch == 50 })
    }

    /// Off means silent, not untracked. The queue stays readable by `shifu due`
    /// and the app, which is the difference between "don't interrupt me" and
    /// "stop keeping this".
    @Test func remindersOffSilencesEverythingButKeepsTheQueue() throws {
        let (database, now) = try harness()
        try Settings.set(SettingsCatalog.remindersEnabled, to: "off", database: database)

        #expect(try DeadlineReminders.due(database: database, now: now).isEmpty)
        #expect(try DeadlineStore.open(database: database).count == 1)
        #expect(try DeadlineReminders.hasSomethingToRemind(database: database))
    }

    @Test func progressOffLeavesTheDatesAlone() throws {
        let (database, now) = try harness()
        try Settings.set(SettingsCatalog.remindersProgress, to: "off", database: database)

        let due = try DeadlineReminders.due(database: database, now: now)
        #expect(due.count == 1)
        #expect(due.first?.lead == 3)
    }

    /// The whole point of the ledger: what has been delivered is not delivered
    /// again on the next poll, five minutes later.
    @Test func recordingWhatWasSaidStopsTheNextPollRepeatingIt() throws {
        let (database, now) = try harness()
        let first = try DeadlineReminders.due(database: database, now: now)
        #expect(first.count == 2)
        for announcement in first {
            try DeadlineReminders.record(announcement, database: database)
        }

        #expect(try DeadlineReminders.due(
            database: database, now: now + 300_000).isEmpty)
    }

    /// A user who has typed no dates must never see the permission prompt: the
    /// request is the first thing Shifu asks for, and asking with no reason is
    /// how the answer becomes no.
    @Test func thereIsNothingToRemindAboutUntilADateExists() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(try DeadlineReminders.hasSomethingToRemind(database: database) == false)

        let created = try DeadlineStore.create(
            title: "Visa appointment", dueAt: 900 * hour, now: 0, database: database)
        #expect(try DeadlineReminders.hasSomethingToRemind(database: database))

        // …and a promise already kept doesn't count either.
        try DeadlineStore.markDone(created.id ?? 0, at: 1, database: database)
        #expect(try DeadlineReminders.hasSomethingToRemind(database: database) == false)
    }

    @Test func preferencesFallBackToTheCatalogDefaults() throws {
        let database = try ShifuDatabase.inMemory()
        let preferences = DeadlineReminders.preferences(database: database)
        #expect(preferences.enabled)
        #expect(preferences.progress)
        #expect(preferences.hour == DeadlineHorizon.defaultHour)
    }

    /// Both new gated rows point at a real choice and a real option. The
    /// catalog's own `visibilityGatesReferenceRealChoices` only walks `texts`,
    /// so an int or choice row's gate is unguarded there — a typo would hide the
    /// field forever with nothing failing.
    @Test func theRemindersRowsAreWiredIntoTheCatalog() {
        #expect(SettingsCatalog.choices.contains { $0.key == "reminders.enabled" })
        #expect(SettingsCatalog.choices.contains { $0.key == "reminders.progress" })
        #expect(SettingsCatalog.ints.contains { $0.key == "reminders.hour" })

        let gated: [(key: String, value: String)?] = [
            SettingsCatalog.remindersProgress.visibleWhen,
            SettingsCatalog.remindersHour.visibleWhen
        ]
        for gate in gated.compactMap({ $0 }) {
            let choice = SettingsCatalog.choices.first { $0.key == gate.key }
            #expect(choice != nil)
            #expect(choice?.options.contains { $0.value == gate.value } == true)
        }
    }
}

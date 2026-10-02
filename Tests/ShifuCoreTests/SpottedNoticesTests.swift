import Foundation
import Testing
@testable import ShifuCore

/// What Shifu says about a spotted date (design.md §4.7).
///
/// Like `DeadlineHorizonTests`, this mostly guards *silence*: one roll-up a
/// day, each proposal named once, nothing below the high tier, nothing at
/// all with the setting off. A spotted date is a guess, and a guess that
/// repeats is the feature people switch off.
@Suite struct SpottedNoticesTests {
    private let day: Int64 = 86_400_000
    private let hour: Int64 = 3_600_000

    /// Local noon today: past the default 9 o'clock reminder hour.
    private var noon: Int64 {
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private var dawn: Int64 { noon - 7 * hour }   // 05:00, before the reminder hour

    private func seed(
        _ database: ShifuDatabase, _ title: String, daysOut: Int, score: Int, seen: Int64? = nil
    ) throws {
        let seenAt = seen ?? (noon - 2 * hour)
        let hit = DeadlineScout.Hit(
            key: "\(title)|\(daysOut)", title: title, context: "Inbox",
            dueAt: noon + Int64(daysOut) * day, allDay: true, category: .submission,
            score: score, evidence: "\(title) due", signals: [])
        try database.queue.write { db in
            _ = try DeadlineProposalStore.record(
                [hit], source: .init(appBundle: "com.apple.mail", seenAt: seenAt), db: db, now: seenAt)
        }
    }

    // MARK: - The roll-up

    @Test func oneRollupADayNamingTheSoonestThree() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "Thesis", daysOut: 9, score: 6)
        try seed(database, "Grant", daysOut: 4, score: 7)
        try seed(database, "RSVP", daysOut: 6, score: 6)
        try seed(database, "Form", daysOut: 12, score: 8)
        try seed(database, "Minor event", daysOut: 3, score: 3)   // normal: never a banner

        // Before the reminder hour: nothing.
        #expect(try SpottedNotices.due(database: database, now: dawn).isEmpty)

        let notices = try SpottedNotices.due(database: database, now: noon)
        #expect(notices.count == 1)
        let rollup = try #require(notices.first)
        #expect(rollup.kind == .rollup)
        #expect(rollup.title == "Shifu spotted 4 dates")
        // Inside a week a date reads as a person says it; past one, as the
        // calendar does ("Thesis — Oct 11").
        #expect(rollup.body.hasPrefix("Grant — in 4 days · RSVP — in 6 days · Thesis — "))
        #expect(!rollup.body.contains("Form"))
        #expect(rollup.body.hasSuffix("and 1 more"))
        #expect(rollup.proposalIDs.count == 3)

        try SpottedNotices.record(rollup, database: database, now: noon)
        // Same day, later: quiet, even though one was left unnamed.
        #expect(try SpottedNotices.due(database: database, now: noon + 3 * hour).isEmpty)
        // Next day: only the one not yet named.
        let tomorrow = try SpottedNotices.due(database: database, now: noon + day)
        #expect(tomorrow.count == 1)
        #expect(tomorrow.first?.title == "Shifu spotted a date")
        #expect(tomorrow.first?.body.hasPrefix("Form — ") == true)
        #expect(tomorrow.first?.body.contains("more") == false)
        try SpottedNotices.record(try #require(tomorrow.first), database: database, now: noon + day)
        #expect(try SpottedNotices.due(database: database, now: noon + 2 * day).isEmpty)
    }

    /// The first pass after an install backfills two weeks of text. Nine
    /// critical rows due today are one banner, not nine.
    @Test func manyUrgentDatesAreOneBannerPerTick() throws {
        let database = try ShifuDatabase.inMemory()
        for index in 0..<5 { try seed(database, "HW \(index)", daysOut: index % 2, score: 9) }
        let notices = try SpottedNotices.due(database: database, now: dawn)
        #expect(notices.count == 1)
        let urgent = try #require(notices.first)
        #expect(urgent.kind == .urgent)
        #expect(urgent.title == "5 spotted dates due within 2 days")
        #expect(urgent.body.hasSuffix("and 2 more"))
        #expect(urgent.proposalIDs.count == 3)
        try SpottedNotices.record(urgent, database: database, now: dawn)
        // The two not yet named come on the next tick, still as one banner.
        let next = try SpottedNotices.due(database: database, now: dawn + hour)
        #expect(next.count == 1)
        #expect(next.first?.title == "2 spotted dates due within 2 days")
    }

    /// A roll-up whose hour passed while Shifu was closed goes out on the
    /// next poll, not at tomorrow's hour.
    @Test func aMissedHourFiresOnTheNextPoll() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "Grant", daysOut: 4, score: 7)
        #expect(try SpottedNotices.due(database: database, now: noon + 9 * hour).count == 1)
    }

    // MARK: - Urgent

    @Test func aCriticalDateWithinTwoDaysIsAnnouncedAtOnceAndOnce() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "HW 4", daysOut: 1, score: 9)
        try seed(database, "Far exam", daysOut: 20, score: 9)   // critical but not urgent

        let early = try SpottedNotices.due(database: database, now: dawn)
        #expect(early.count == 1)
        let urgent = try #require(early.first)
        #expect(urgent.kind == .urgent)
        #expect(urgent.title == "Spotted: HW 4")
        #expect(urgent.body == "tomorrow · seen in Inbox")
        #expect(urgent.identifier.hasSuffix(".urgent"))

        try SpottedNotices.record(urgent, database: database, now: dawn)
        // At the hour: the far one rolls up; the urgent one is not repeated.
        let later = try SpottedNotices.due(database: database, now: noon)
        #expect(later.count == 1)
        #expect(later.first?.kind == .rollup)
        #expect(later.first?.body == "Far exam — Oct 22" || later.first?.body.hasPrefix("Far exam — ") == true)
    }

    // MARK: - Gates

    @Test func theSettingsSilenceEverything() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "HW 4", daysOut: 1, score: 9)
        try seed(database, "Grant", daysOut: 4, score: 7)
        try Settings.set(SettingsCatalog.remindersSpotted, to: "off", database: database)
        #expect(try SpottedNotices.due(database: database, now: noon).isEmpty)
        #expect(try !SpottedNotices.hasSomethingToAnnounce(database: database))

        try Settings.set(SettingsCatalog.remindersSpotted, to: "on", database: database)
        try Settings.set(SettingsCatalog.remindersEnabled, to: "off", database: database)
        #expect(try SpottedNotices.due(database: database, now: noon).isEmpty)
        // The queue is still there to be looked at.
        #expect(try DeadlineProposalStore.pending(database: database).count == 2)
    }

    /// The gate on asking for notification permission: a user with no typed
    /// deadline but a high-ranked spotted date has something to grant.
    @Test func aSpottedDateIsSomethingToRemindAbout() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(try !DeadlineReminders.hasSomethingToRemind(database: database))
        try seed(database, "Minor", daysOut: 3, score: 3)
        #expect(try !DeadlineReminders.hasSomethingToRemind(database: database))
        try seed(database, "Grant", daysOut: 4, score: 7)
        #expect(try DeadlineReminders.hasSomethingToRemind(database: database))
    }

    @Test func rulingOnAProposalTakesItOutOfTheRollup() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "Grant", daysOut: 4, score: 7)
        try seed(database, "Thesis", daysOut: 9, score: 6)
        let ids = try DeadlineProposalStore.pending(database: database).compactMap(\.id)
        try DeadlineProposalStore.dismiss(ids[0], database: database)
        _ = try DeadlineProposalStore.accept(ids[1], now: noon, database: database)
        #expect(try SpottedNotices.due(database: database, now: noon).isEmpty)
    }

    // MARK: - Words

    @Test func whenReadsCloseDatesAsAPersonAndFarOnesAsACalendar() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, "Near", daysOut: 1, score: 7)
        try seed(database, "Far", daysOut: 30, score: 7)
        let rows = try DeadlineProposalStore.pending(database: database)
        let near = try #require(rows.first { $0.title == "Near" })
        let far = try #require(rows.first { $0.title == "Far" })
        #expect(SpottedNotices.when(near, now: noon) == "tomorrow")
        let farText = SpottedNotices.when(far, now: noon)
        #expect(!farText.contains("days"))
        #expect(farText.count <= 7)   // "Nov 1"-shaped
    }
}

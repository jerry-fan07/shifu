import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The `deadline_proposals` table and the scout's pass over the database
/// (design.md §4.7).
///
/// The properties worth pinning are the ones about *memory*: a repeat
/// sighting folds in rather than duplicating, a dismissal holds against every
/// later sighting, an acceptance mints exactly one deadline, and the
/// watermark means an hourly pass reads each observation once.
@Suite struct DeadlineProposalStoreTests {
    private let day: Int64 = 86_400_000
    private let hour: Int64 = 3_600_000

    private func database() throws -> ShifuDatabase { try ShifuDatabase.inMemory() }

    /// Local noon today — a seen-at the calendar day arithmetic is stable on.
    private var noon: Int64 {
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func hit(
        key: String = "2026-10-20|late-due-date", title: String = "Late Due Date",
        dueAt: Int64? = nil, score: Int = 9, category: DeadlineScout.Category = .submission
    ) -> DeadlineScout.Hit {
        DeadlineScout.Hit(
            key: key, title: title, context: "MATH 1560 Dashboard", dueAt: dueAt ?? noon + 10 * day,
            allDay: false, category: category, score: score,
            evidence: "Late Due Date: Oct 20 at 11:59PM", signals: ["late due date:+3"])
    }

    private func source(seen: Int64, task: Int64? = nil) -> DeadlineScout.Source {
        DeadlineScout.Source(appBundle: "com.google.Chrome", domain: "gradescope.com",
                             windowTitle: "MATH 1560 Dashboard", taskID: task, seenAt: seen)
    }

    private func record(
        _ hits: [DeadlineScout.Hit], seen: Int64, task: Int64? = nil, in database: ShifuDatabase
    ) throws -> Int {
        try database.queue.write { db in
            try DeadlineProposalStore.record(hits, source: source(seen: seen, task: task), db: db, now: seen)
        }
    }

    // MARK: - Sightings

    @Test func aFirstSightingIsARowAndARepeatFoldsIn() throws {
        let database = try self.database()
        #expect(try record([hit()], seen: noon, in: database) == 1)
        #expect(try record([hit()], seen: noon + hour, in: database) == 0)
        let rows = try DeadlineProposalStore.pending(database: database)
        #expect(rows.count == 1)
        #expect(rows.first?.sightings == 2)
        #expect(rows.first?.seenDays == 1)      // same day twice is one day
        #expect(rows.first?.score == 9)
        #expect(rows.first?.tier == .critical)
    }

    /// A date that keeps being on screen is one the user keeps running into:
    /// each new day adds a point, up to three.
    @Test func repetitionAcrossDaysRaisesTheScoreToACap() throws {
        let database = try self.database()
        for offset in 0..<6 {
            _ = try record([hit(score: 5)], seen: noon + Int64(offset) * day, in: database)
        }
        let row = try #require(try DeadlineProposalStore.pending(database: database).first)
        #expect(row.seenDays == 6)
        #expect(row.baseScore == 5)
        #expect(row.score == 5 + DeadlineProposalStore.repeatBonusCap)
        #expect(row.tier == .high)
    }

    @Test func aBetterSightingBringsItsWordingAndATaskFillsIn() throws {
        let database = try self.database()
        let taskID = try database.queue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO tasks (key, name, created_at, last_active_at) VALUES (?,?,?,?)",
                           arguments: ["sem:nt", "Number theory", 0, 0])
            return db.lastInsertedRowID
        }
        _ = try record([hit(title: "Late Due", score: 4)], seen: noon, in: database)
        _ = try record([hit(title: "Late Due Date", score: 9)], seen: noon + hour, task: taskID, in: database)
        let row = try #require(try DeadlineProposalStore.pending(database: database).first)
        #expect(row.title == "Late Due Date")
        #expect(row.baseScore == 9)
        #expect(row.taskID == taskID)
        // Pruning the task leaves the proposal, minus the link.
        try database.queue.write { db in try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [taskID]) }
        #expect(try DeadlineProposalStore.pending(database: database).first?.taskID == nil)
    }

    // MARK: - Rulings

    @Test func aDismissalHoldsAgainstEveryLaterSighting() throws {
        let database = try self.database()
        _ = try record([hit()], seen: noon, in: database)
        let id = try #require(try DeadlineProposalStore.pending(database: database).first?.id)
        try DeadlineProposalStore.dismiss(id, database: database)
        #expect(try record([hit()], seen: noon + day, in: database) == 0)
        #expect(try DeadlineProposalStore.pending(database: database).isEmpty)
        let row = try #require(try DeadlineProposalStore.find(id, database: database))
        #expect(row.status == .dismissed)
        #expect(row.sightings == 2)   // still counted, never resurfaced
    }

    @Test func acceptingMintsOneDeadlineInTheUsersWords() throws {
        let database = try self.database()
        _ = try record([hit()], seen: noon, in: database)
        let id = try #require(try DeadlineProposalStore.pending(database: database).first?.id)
        let deadline = try #require(try DeadlineProposalStore.accept(
            id, title: "MATH 1560 HW4", targetMs: 4 * hour, now: noon, database: database))
        #expect(deadline.title == "MATH 1560 HW4")
        #expect(deadline.dueAt == noon + 10 * day)
        #expect(deadline.allDay == false)
        #expect(deadline.targetMs == 4 * hour)
        #expect(try DeadlineStore.open(database: database).count == 1)
        let row = try #require(try DeadlineProposalStore.find(id, database: database))
        #expect(row.status == .accepted)
        #expect(row.deadlineID == deadline.id)
        // Out of the queue; a second accept is refused by status, not by
        // minting again.
        #expect(try DeadlineProposalStore.pending(database: database).isEmpty)
        // Deleting the deadline later leaves the proposal, minus the link.
        try DeadlineStore.delete(deadline.id ?? 0, database: database)
        #expect(try DeadlineProposalStore.find(id, database: database)?.deadlineID == nil)
    }

    @Test func dismissAllClearsTheQueueAndNothingElse() throws {
        let database = try self.database()
        _ = try record([hit(), hit(key: "2026-10-21|hw-5", title: "HW 5")], seen: noon, in: database)
        let first = try #require(try DeadlineProposalStore.pending(database: database).first?.id)
        _ = try DeadlineProposalStore.accept(first, now: noon, database: database)
        #expect(try DeadlineProposalStore.dismissAll(database: database) == 1)
        #expect(try DeadlineProposalStore.find(first, database: database)?.status == .accepted)
    }

    @Test func aDayGoneByExpiresAnOpenProposalOnly() throws {
        let database = try self.database()
        _ = try record([hit(key: "y|old", dueAt: noon - day), hit()], seen: noon - 2 * day, in: database)
        let stale = try #require(try DeadlineProposalStore.pending(database: database)
            .first { $0.key == "y|old" }?.id)
        #expect(try DeadlineProposalStore.expire(database: database, now: noon) == 1)
        #expect(try DeadlineProposalStore.find(stale, database: database)?.status == .expired)
        #expect(try DeadlineProposalStore.pending(database: database).count == 1)
    }

    @Test func pendingRanksByTierThenDateAndHonoursTheFloor() throws {
        let database = try self.database()
        _ = try record([
            hit(key: "a", title: "soon-normal", dueAt: noon + day, score: 3),
            hit(key: "b", title: "later-critical", dueAt: noon + 5 * day, score: 9),
            hit(key: "c", title: "sooner-critical", dueAt: noon + 2 * day, score: 9),
            hit(key: "d", title: "low", dueAt: noon + day, score: 0)
        ], seen: noon, in: database)
        let titles = try DeadlineProposalStore.pending(database: database).map(\.title)
        #expect(titles == ["sooner-critical", "later-critical", "soon-normal", "low"])
        let shown = try DeadlineProposalStore.pending(database: database, minimumTier: .high).map(\.title)
        #expect(shown == ["sooner-critical", "later-critical"])
    }

    // MARK: - The judge's verdicts

    @Test func aVetoDismissesAndAKeepRewordsWithinOneTier() throws {
        let database = try self.database()
        _ = try record([hit(key: "a", title: "keep me", score: 6), hit(key: "b", title: "drop me", score: 6)],
                       seen: noon, in: database)
        let rows = try DeadlineProposalStore.pending(database: database)
        let keep = try #require(rows.first { $0.key == "a" }?.id)
        let drop = try #require(rows.first { $0.key == "b" }?.id)
        try database.queue.write { db in
            try DeadlineProposalStore.applyJudgment(
                .init(id: keep, keep: true, title: "MATH 1560 HW4", category: .exam, tierShift: 1), db: db)
            try DeadlineProposalStore.applyJudgment(.init(id: drop, keep: false), db: db)
        }
        let kept = try #require(try DeadlineProposalStore.find(keep, database: database))
        #expect(kept.title == "MATH 1560 HW4")
        #expect(kept.category == .exam)
        #expect(kept.tier == .critical)
        #expect(kept.judged)
        #expect(try DeadlineProposalStore.find(drop, database: database)?.status == .dismissed)
        // A later, higher-scoring sighting counts but no longer rewords or
        // re-tiers a judged row.
        _ = try record([hit(key: "a", title: "scout wording", score: 10)], seen: noon + day, in: database)
        let after = try #require(try DeadlineProposalStore.find(keep, database: database))
        #expect(after.title == "MATH 1560 HW4")
        #expect(after.tier == .critical)
        #expect(after.sightings == 2)
    }

    // MARK: - The pass over observations

    private func observe(
        _ database: ShifuDatabase, text: String, title: String? = nil, app: String = "com.google.Chrome",
        url: String? = nil, at seen: Int64
    ) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO observations (started_at, last_seen, app_bundle, window_title, url, capture_kind, text)
                VALUES (?, ?, ?, ?, ?, 'ocr', ?)
                """, arguments: [seen, seen, app, title, url, text])
        }
    }

    @Test func theRunReadsEachObservationOnceAndRecordsWhatItSpots() throws {
        let database = try self.database()
        let seen = noon - 2 * hour
        try observe(database, text: "Late Due Date: Oct 20 at 11:59PM",
                    title: "Fall 2026 MATH 1560 S01 Dashboard | Gradescope - Google Chrome",
                    url: "https://www.gradescope.com/courses/1", at: seen)
        try observe(database, text: "Sharpe Refectory closes dinner in 28 minutes. Ivy Room opens Sunday at 5 PM.",
                    title: "Brown Dining - Google Chrome", at: seen)
        try observe(database, text: "nothing dated here", at: seen)
        // Still being folded into: inside the dedupe TTL, so left for next time.
        try observe(database, text: "HW 2 due Oct 23", at: noon - 1_000)

        let dueOct20 = SpottedDate.first(in: "Oct 20", seenAt: seen)?.dueAt
        let first = try DeadlineScoutRun.run(database: database, now: noon)
        #expect(first.observationsRead == 3)
        #expect(first.created == 2)   // the dining line is kept as a low row, not dropped
        let rows = try DeadlineProposalStore.pending(database: database)
        #expect(rows.first?.title == "Late Due Date")
        #expect(rows.first.map { startOfDay($0.dueAt) } == dueOct20.map(startOfDay))
        #expect(rows.first?.sourceDomain == "gradescope.com")

        let second = try DeadlineScoutRun.run(database: database, now: noon)
        #expect(second.observationsRead == 0)
        let third = try DeadlineScoutRun.run(database: database, now: noon + hour)
        #expect(third.observationsRead == 1)
        #expect(third.created == 1)
        let before = try DeadlineProposalStore.pending(database: database)
        let reset = try DeadlineScoutRun.run(database: database, now: noon + hour, reset: true)
        #expect(reset.observationsRead == 4)
        #expect(reset.created == 0)
        let after = try DeadlineProposalStore.pending(database: database)
        #expect(after.count == 3)
        // A replay counts nothing twice: same sightings, same days, same score.
        #expect(after.map(\.sightings) == before.map(\.sightings))
        #expect(after.map(\.seenDays) == before.map(\.seenDays))
        #expect(after.map(\.score) == before.map(\.score))
    }

    /// Ids and `last_seen` do not move together: the dashboard the user keeps
    /// returning to is an *old* row that is still growing while newer glances
    /// close around it. The pass must hold at that row, not jump past it.
    @Test func aRowStillGrowingHoldsTheWatermarkWhateverItsID() throws {
        let database = try self.database()
        let seen = noon - 3 * hour
        try observe(database, text: "HW 1 due Oct 20", at: seen)
        // Old by id, still being folded into: last_seen is right now.
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO observations (started_at, last_seen, app_bundle, window_title, capture_kind, text)
                VALUES (?, ?, 'com.google.Chrome', 'MATH 1560 Dashboard', 'ocr', 'Late Due Date: Oct 21 at 11:59PM')
                """, arguments: [seen, noon - 1_000])
        }
        try observe(database, text: "HW 3 due Oct 22", at: seen + hour)

        let first = try DeadlineScoutRun.run(database: database, now: noon)
        #expect(first.observationsRead == 1)
        #expect(first.created == 1)
        let held = try DeadlineProposalStore.pending(database: database).map(\.title)
        #expect(held == ["HW 1 due"])
        // Once the dashboard row has closed, it and everything after it are read.
        let second = try DeadlineScoutRun.run(database: database, now: noon + hour)
        #expect(second.observationsRead == 2)
        #expect(second.created == 2)
        #expect(try DeadlineProposalStore.pending(database: database).count == 3)
    }

    @Test func replaysBringBetterWordingWithoutCounting() throws {
        let database = try self.database()
        _ = try record([hit(title: "Late Due", score: 4)], seen: noon, in: database)
        _ = try record([hit(title: "Late Due Date", score: 9)], seen: noon - day, in: database)
        let row = try #require(try DeadlineProposalStore.pending(database: database).first)
        #expect(row.title == "Late Due Date")
        #expect(row.sightings == 1)
        #expect(row.seenDays == 1)
        #expect(row.firstSeen == noon - day)
        #expect(row.lastSeen == noon)
    }

    private func startOfDay(_ ms: Int64) -> Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }

    @Test func previewWritesNothing() throws {
        let database = try self.database()
        try observe(database, text: "Late Due Date: Oct 20 at 11:59PM",
                    url: "https://www.gradescope.com/courses/1", at: noon - 2 * hour)
        let found = try DeadlineScoutRun.preview(database: database, now: noon)
        #expect(found.count == 1)
        #expect(try DeadlineProposalStore.all(database: database).isEmpty)
        #expect(DeadlineScoutRun.watermark(database: database) == 0)
    }
}

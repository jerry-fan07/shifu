import Foundation
import GRDB
import ShifuCore
import Testing

/// The `deadlines` table (design.md §4.5).
///
/// The claims worth making here are the ones about *survival*: a deadline is the
/// only row in Shifu the user typed themselves, and every pipeline around it
/// deletes and rebuilds. If the ledger, a prune, or a merge can take a promise
/// with it, the feature is worse than not having it.
@Suite struct DeadlineStoreTests {
    private let hour: Int64 = 3_600_000

    private func database() throws -> ShifuDatabase {
        try ShifuDatabase.inMemory()
    }

    /// One task and one block of logged time against it.
    private func seedTask(
        _ database: ShifuDatabase, name: String = "Thesis", key: String = "sem:thesis",
        blocks: [(from: Int64, to: Int64)] = []
    ) throws -> Int64 {
        try database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tasks (key, name, created_at, last_active_at) VALUES (?, ?, ?, ?)
                    """,
                arguments: [key, name, 0, 0])
            let taskID = db.lastInsertedRowID
            for block in blocks {
                try db.execute(
                    sql: """
                        INSERT INTO activities
                          (started_at, ended_at, app_bundle, category, source, task_id)
                        VALUES (?, ?, 'com.apple.Pages', 'work', 'rules', ?)
                        """,
                    arguments: [block.from, block.to, taskID])
            }
            return taskID
        }
    }

    @Test func aDeadlineRoundTripsWithItsTaskAndTarget() throws {
        let database = try self.database()
        let taskID = try seedTask(database)
        let created = try DeadlineStore.create(
            title: "  Thesis draft  ", dueAt: 5_000, allDay: false, taskID: taskID,
            targetMs: 20 * hour, now: 1_000, database: database)

        #expect(created.title == "Thesis draft")   // trimmed on the way in
        let open = try DeadlineStore.open(database: database)
        #expect(open.count == 1)
        #expect(open.first?.deadline.dueAt == 5_000)
        #expect(open.first?.deadline.allDay == false)
        #expect(open.first?.deadline.targetMs == 20 * hour)
        #expect(open.first?.taskName == "Thesis")
        #expect(open.first?.deadline.progressNotch == 0)
        #expect(open.first?.deadline.announcedLead == nil)
    }

    @Test func anEmptyTitleIsRefused() throws {
        let database = try self.database()
        #expect(throws: DeadlineError.self) {
            try DeadlineStore.create(title: "   ", dueAt: 1, now: 0, database: database)
        }
    }

    /// Progress counts from when the promise was made, and a block straddling
    /// that moment donates only the part after it. Uncllipped, one long block
    /// begun the day before would arrive as hours of free credit.
    @Test func loggedTimeIsClippedAtTheMomentThePromiseWasMade() throws {
        let database = try self.database()
        let taskID = try seedTask(database, blocks: [
            (from: 0, to: 4 * hour),                 // entirely before — ignored
            (from: 9 * hour, to: 12 * hour),         // straddles: 2 h counts
            (from: 20 * hour, to: 23 * hour)         // entirely after — 3 h
        ])
        try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 10 * hour, database: database)

        let standing = try #require(try DeadlineStore.open(database: database).first)
        #expect(standing.loggedMs == 5 * hour)
        #expect(standing.progressPercent == 25)
    }

    /// The reason this is a table and not a `tasks.due_at` column. `TaskPrune`
    /// and `TaskStore.merge` both `DELETE FROM tasks`; the promise has to
    /// outlive that, having lost only what it was measuring against.
    @Test func deletingTheTaskLeavesThePromiseStandingWithoutItsProgress() throws {
        let database = try self.database()
        let taskID = try seedTask(database, blocks: [(from: 0, to: 6 * hour)])
        try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 0, database: database)
        #expect(try DeadlineStore.open(database: database).first?.loggedMs == 6 * hour)

        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [taskID])
        }

        let survivor = try #require(try DeadlineStore.open(database: database).first)
        #expect(survivor.deadline.title == "Thesis draft")
        #expect(survivor.deadline.taskID == nil)
        #expect(survivor.taskName == nil)
        #expect(survivor.loggedMs == 0)
        // The target it was given survives, so the fraction reads 0% — the
        // honest figure once the thing being measured is gone.
        #expect(survivor.progressPercent == 0)
    }

    /// A deadline needs no task at all — a commitment can precede any work,
    /// which is the other half of why the link is nullable.
    @Test func aDeadlineWithNoTaskIsStillAPromise() throws {
        let database = try self.database()
        try DeadlineStore.create(
            title: "Visa appointment", dueAt: 100 * hour, now: 0, database: database)
        let standing = try #require(try DeadlineStore.open(database: database).first)
        #expect(standing.deadline.taskID == nil)
        #expect(standing.loggedMs == 0)
        #expect(standing.progressPercent == nil)   // no target, nothing claimed
    }

    /// One task, several dates. This is what makes it a critical timeline
    /// rather than a due date.
    @Test func oneTaskCanCarrySeveralMilestones() throws {
        let database = try self.database()
        let taskID = try seedTask(database)
        try DeadlineStore.create(
            title: "Outline", dueAt: 30 * hour, taskID: taskID, now: 0, database: database)
        try DeadlineStore.create(
            title: "Full draft", dueAt: 10 * hour, taskID: taskID, now: 0, database: database)

        let rows = try DeadlineStore.forTask(taskID, database: database)
        #expect(rows.count == 2)
        #expect(rows.map(\.deadline.title) == ["Full draft", "Outline"])   // soonest first
    }

    // MARK: - The announcement ledger

    @Test func stampingALeadOnlyEverMovesItDown() throws {
        let database = try self.database()
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, now: 0, database: database)
        let id = try #require(created.id)

        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .approaching(daysLeft: 3), title: "x", body: "y", lead: 3),
            database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.announcedLead == 3)

        // A stale 7-day notice arriving late must not re-arm the 3-day one.
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .approaching(daysLeft: 7), title: "x", body: "y", lead: 7),
            database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.announcedLead == 3)
    }

    @Test func stampingANotchOnlyEverMovesItUp() throws {
        let database = try self.database()
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, now: 0, database: database)
        let id = try #require(created.id)

        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .progress(percent: 75), title: "x", body: "y", notch: 75),
            database: database)
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .progress(percent: 25), title: "x", body: "y", notch: 25),
            database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.progressNotch == 75)
    }

    /// Pushing a deadline out has to re-arm its reminders. Without this, the
    /// notices for the old, nearer date all read as "already said" and a
    /// deadline moved a month out would never speak again.
    @Test func movingTheDateReArmsTheSchedule() throws {
        let database = try self.database()
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, now: 0, database: database)
        let id = try #require(created.id)
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .approaching(daysLeft: 0), title: "x", body: "y", lead: 0),
            database: database)

        try DeadlineStore.update(id, dueAt: 900 * hour, database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.announcedLead == nil)

        // An edit that does *not* move the date leaves the ledger alone.
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .approaching(daysLeft: 7), title: "x", body: "y", lead: 7),
            database: database)
        try DeadlineStore.update(id, title: "Thesis draft v2", database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.announcedLead == 7)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.title == "Thesis draft v2")
    }

    /// Raising the target has to make the higher quarters reachable again —
    /// otherwise a 20h target bumped to 40h after the 100% notice reports
    /// progress never again, there being nothing above 100. And it must not
    /// re-announce the quarters already earned, which a reset to zero would.
    @Test func raisingTheTargetReArmsProgressWithoutRepeatingIt() throws {
        let database = try self.database()
        let taskID = try seedTask(database, blocks: [(from: 0, to: 22 * hour)])
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 900 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 0, database: database)
        let id = try #require(created.id)

        // 22 h of 20 h — the whole target, announced.
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .progress(percent: 100), title: "x", body: "y", notch: 100),
            database: database)

        try DeadlineStore.update(id, targetMs: 40 * hour, database: database)
        // 22 h of 40 h is 55%: the 50% quarter is earned and stays silent, and
        // 75% is live again.
        let reArmed = try #require(try DeadlineStore.find(id, database: database))
        #expect(reArmed.deadline.progressNotch == 50)
        #expect(reArmed.progressPercent == 55)
        #expect(DeadlineHorizon.announcements(for: reArmed, now: 100 * hour).isEmpty)
    }

    /// Clearing the target lands the notch on zero, which is what a target set
    /// again later should measure from.
    @Test func clearingTheTargetResetsTheProgressLedger() throws {
        let database = try self.database()
        let taskID = try seedTask(database, blocks: [(from: 0, to: 22 * hour)])
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 900 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 0, database: database)
        let id = try #require(created.id)
        try DeadlineStore.stamp(
            .init(deadlineID: id, kind: .progress(percent: 100), title: "x", body: "y", notch: 100),
            database: database)

        try DeadlineStore.update(id, clearTarget: true, database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.progressNotch == 0)
    }

    @Test func clearingATargetIsDifferentFromLeavingItAlone() throws {
        let database = try self.database()
        let taskID = try seedTask(database)
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 0, database: database)
        let id = try #require(created.id)

        try DeadlineStore.update(id, title: "Same date", database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.targetMs == 20 * hour)

        try DeadlineStore.update(id, clearTarget: true, database: database)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.targetMs == nil)
    }

    @Test func markingOneDoneTakesItOutOfTheQueueButNotOutOfHistory() throws {
        let database = try self.database()
        let created = try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, now: 0, database: database)
        let id = try #require(created.id)

        try DeadlineStore.markDone(id, at: 50 * hour, database: database)
        #expect(try DeadlineStore.open(database: database).isEmpty)
        #expect(try DeadlineStore.all(database: database).count == 1)
        #expect(try DeadlineStore.find(id, database: database)?.deadline.isDone == true)

        // Reopening is the same call with no moment.
        try DeadlineStore.markDone(id, at: nil, database: database)
        #expect(try DeadlineStore.open(database: database).count == 1)
    }

    /// A ledger rebuild deletes and re-inserts `activities` every run
    /// (ARCHITECTURE.md §8). Progress is computed from that table on read, so
    /// the promise itself is untouched and the figure simply follows the ledger.
    @Test func aLedgerRebuildCannotDisturbAPromise() throws {
        let database = try self.database()
        let taskID = try seedTask(database, blocks: [(from: 0, to: 8 * hour)])
        try DeadlineStore.create(
            title: "Thesis draft", dueAt: 100 * hour, taskID: taskID,
            targetMs: 20 * hour, now: 0, database: database)

        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM activities")
            try db.execute(
                sql: """
                    INSERT INTO activities
                      (started_at, ended_at, app_bundle, category, source, task_id)
                    VALUES (0, ?, 'com.apple.Pages', 'work', 'rules', ?)
                    """,
                arguments: [12 * hour, taskID])
        }

        let standing = try #require(try DeadlineStore.open(database: database).first)
        #expect(standing.deadline.title == "Thesis draft")
        #expect(standing.loggedMs == 12 * hour)
    }
}

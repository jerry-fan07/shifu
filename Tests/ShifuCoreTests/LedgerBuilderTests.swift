import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct LedgerBuilderTests {
    private func seedObservations(_ db: ShifuDatabase) throws {
        let recorder = ObservationRecorder(database: db)
        try recorder.record(.init(timestamp: 1_000, appBundle: "com.apple.dt.Xcode",
                                  windowTitle: "shifu", captureKind: .ax, text: "swift code editing"))
        try recorder.record(.init(timestamp: 500_000, appBundle: "com.apple.Safari",
                                  windowTitle: "YT", url: "https://youtube.com/w",
                                  captureKind: .ax, text: "video comments feed"))
    }

    @Test func rebuildWritesClassifiedActivities() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        let summary = try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        #expect(summary.blocksWritten == 2)

        let activities = try db.queue.read {
            try Activity.order(Column("started_at")).fetchAll($0)
        }
        #expect(activities.count == 2)
        #expect(activities[0].category == .work)
        #expect(activities[1].category == .entertainment)
        #expect(activities[1].ambiguous)

        // Observations got linked back to their session.
        let linked = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE session_id IS NOT NULL")
        }
        #expect(linked == 2)
    }

    @Test func rebuildIsIdempotent() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        let count = try db.queue.read { try Activity.fetchCount($0) }
        #expect(count == 2)
    }

    @Test func ruleChangeRelabelsOnRebuild() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO rules (kind, value, category, ambiguous)
                VALUES ('domain', 'youtube.com', 'learning', 0)
                """)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(database: db), from: 0, to: 1_000_000)

        let categories = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT category FROM activities ORDER BY started_at")
        }
        #expect(categories == ["work", "learning"])
    }

    @Test func totalsSumByCategory() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            var activityA = Activity(startedAt: 0, endedAt: 60_000, appBundle: "x", category: .work)
            var activityB = Activity(startedAt: 60_000, endedAt: 90_000, appBundle: "x", category: .work)
            var activityC = Activity(startedAt: 90_000, endedAt: 100_000, appBundle: "y", category: .social)
            try activityA.insert(sqlite); try activityB.insert(sqlite); try activityC.insert(sqlite)
        }
        let totals = try LedgerBuilder.totals(database: db, from: 0, to: 200_000)
        #expect(totals[.work] == 90_000)
        #expect(totals[.social] == 10_000)
    }
}

@Suite struct RetentionTests {
    @Test func scrubsOnlyExpiredText() throws {
        let db = try ShifuDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try db.queue.write { sqlite in
            var old = Observation(startedAt: nowMs - 20 * 86_400_000, appBundle: "a",
                                  captureKind: .ax, text: "old secret-ish text", textSimhash: 42)
            var fresh = Observation(startedAt: nowMs - 86_400_000, appBundle: "b",
                                    captureKind: .ax, text: "fresh text", textSimhash: 7)
            try old.insert(sqlite); try fresh.insert(sqlite)
        }
        let scrubbed = try Retention.scrubExpiredText(database: db, olderThanDays: 14, now: now)
        #expect(scrubbed == 1)
        let rows = try db.queue.read { try Observation.order(Column("started_at")).fetchAll($0) }
        #expect(rows[0].text == nil)
        #expect(rows[0].textSimhash == nil)
        #expect(rows[1].text == "fresh text")
    }
}

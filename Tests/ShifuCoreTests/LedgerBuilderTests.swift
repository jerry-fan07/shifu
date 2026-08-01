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

/// Derived state must survive the delete-and-reinsert rebuild: LLM verdicts
/// and retry counters carry across span-identical rows, so hourly analyzer
/// runs over unchanged observations make zero new LLM calls.
@Suite struct LedgerRebuildCarryTests {
    private final class CountingBackend: LLMBackend, @unchecked Sendable {
        let name = "counting-stub"
        private let response: String
        private let lock = NSLock()
        private var callCount = 0

        var calls: Int { lock.withLock { callCount } }

        init(response: String = "[]") { self.response = response }

        func complete(prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { callCount += 1 }
            return response
        }
    }

    /// A short Xcode block plus an ambiguous YouTube block long enough
    /// (≥3 min) and texty enough (≥200 chars) to qualify for extraction
    /// once the LLM relabels it as learning.
    private func seed(_ db: ShifuDatabase) throws {
        try db.queue.write { sqlite in
            var xcode = Observation(startedAt: 1_000, appBundle: "com.apple.dt.Xcode",
                                    windowTitle: "shifu", captureKind: .ax,
                                    text: "swift code editing")
            let article = String(repeating: "Swift actors serialize access to their state. ",
                                 count: 6)
            var video = Observation(startedAt: 500_000, lastSeen: 700_000,
                                    appBundle: "com.apple.Safari", windowTitle: "Actors — YT",
                                    url: "https://youtube.com/watch?v=1",
                                    captureKind: .ax, text: article)
            try xcode.insert(sqlite)
            try video.insert(sqlite)
        }
    }

    private func videoActivity(_ db: ShifuDatabase) throws -> Activity {
        try #require(try db.queue.read { sqlite in
            try Activity.filter(sql: "domain = 'youtube.com'").fetchOne(sqlite)
        })
    }

    @Test func rebuildCarriesLLMStateAndSkipsRework() async throws {
        let db = try ShifuDatabase.inMemory()
        try seed(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let videoID = try #require(try videoActivity(db).id)
        let cardBuilder = CountingBackend(response: #"""
            [{"id": \#(videoID), "cat": "learning", "conf": 0.9,
              "topic": "swift actors tutorial", "entities": ["site:youtube.com"],
              "gist": "watching a talk on swift actors"}]
            """#)
        let summary = try await CardBuilder.run(
            database: db, backend: cardBuilder, from: 0, to: 1_000_000)
        #expect(summary.relabeled == 1)

        try TaskGrouper.run(database: db, from: 0, to: 1_000_000)
        #expect(cardBuilder.calls == 1)

        // Second analyzer pass over unchanged observations.
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let video = try videoActivity(db)
        #expect(video.category == .learning)
        #expect(video.topic == "swift actors tutorial")
        #expect(video.source == "llm")
        #expect(video.confidence == 0.9)
        #expect(!video.ambiguous)
        // The card rode the same span-keyed carry — dropping it wouldn't lose
        // data, it would re-bill every card in the window every hour.
        let carriedCard = try await db.queue.read {
            try String.fetchOne($0, sql: "SELECT card FROM activities WHERE domain = 'youtube.com'")
        }
        #expect(BlockCard.parse(carriedCard)?.topic == "swift actors tutorial")

        // Nothing is pending for the LLM tier: zero new calls.
        let summaryAgain = try await CardBuilder.run(
            database: db, backend: cardBuilder, from: 0, to: 1_000_000)
        #expect(summaryAgain == .init())
        #expect(cardBuilder.calls == 1)
    }

    @Test func rebuildCarriesSemanticAssignmentBySpan() async throws {
        let db = try ShifuDatabase.inMemory()
        try seed(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        // Simulate the semantic and theme passes: the video block joins a
        // task and a theme, the Xcode block burned placement attempts.
        let videoID = try #require(try videoActivity(db).id)
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                UPDATE activities
                SET sem_key = 'sem:learning-swift-actors', theme_key = 'thm:swift-mastery',
                    theme_user_set = 1
                WHERE id = ?
                """, arguments: [videoID])
            try sqlite.execute(sql: """
                UPDATE activities SET sem_attempts = 2, theme_attempts = 1
                WHERE app_bundle = 'com.apple.dt.Xcode'
                """)
        }

        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let carried = try await db.queue.read { sqlite in
            (keys: try Row.fetchOne(sqlite, sql: """
                SELECT sem_key, theme_key, theme_user_set FROM activities
                WHERE domain = 'youtube.com'
                """).map { ($0["sem_key"] as String?, $0["theme_key"] as String?,
                            $0["theme_user_set"] as Bool) },
             attempts: try Row.fetchOne(sqlite, sql: """
                SELECT sem_attempts, theme_attempts FROM activities
                WHERE app_bundle = 'com.apple.dt.Xcode'
                """).map { ($0["sem_attempts"] as Int, $0["theme_attempts"] as Int) })
        }
        #expect(carried.keys?.0 == "sem:learning-swift-actors")
        #expect(carried.keys?.1 == "thm:swift-mastery")
        // Hand filing must survive the rebuild too, or prune and auto-merge
        // stop protecting the task an hour after the user filed it.
        #expect(carried.keys?.2 == true)
        #expect(carried.attempts?.0 == 2)
        #expect(carried.attempts?.1 == 1)

        // New evidence changes the video block's span — the assignment and
        // counter reset so the semantic pass revisits it.
        try await db.queue.write { sqlite in
            try sqlite.execute(
                sql: "UPDATE observations SET last_seen = 900_000 WHERE url IS NOT NULL")
        }
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        let reset = try await db.queue.read { sqlite in
            (semKey: try Row.fetchOne(
                sqlite, sql: "SELECT sem_key FROM activities WHERE domain = 'youtube.com'")
                .flatMap { $0["sem_key"] as String? },
             attempts: try Int.fetchOne(
                sqlite, sql: "SELECT sem_attempts FROM activities WHERE domain = 'youtube.com'"))
        }
        #expect(reset.semKey == nil)
        #expect(reset.attempts == 0)
    }

    /// A `sem_key` written by neighbour inheritance rides the same
    /// span-keyed carry the model's assignments do — pinning the decision
    /// that inheritance writes the carried column rather than a new one.
    @Test func rebuildCarriesInheritedSemKeys() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            // Two Xcode stretches with a 30 s glance between them — three
            // blocks after sessionizing, gaps well inside one sitting.
            for (start, lastSeen, bundle) in [
                (Int64(1_000), Int64(100_000), "com.apple.dt.Xcode"),
                (Int64(130_000), Int64(130_000), "com.apple.Preview"),
                (Int64(160_000), Int64(260_000), "com.apple.dt.Xcode")
            ] {
                var observation = Observation(
                    startedAt: start, lastSeen: lastSeen, appBundle: bundle,
                    windowTitle: "w", captureKind: .ax, text: "t")
                try observation.insert(sqlite)
            }
        }
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                UPDATE activities SET sem_key = 'sem:thesis-writing'
                WHERE app_bundle = 'com.apple.dt.Xcode'
                """)
        }
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 1_000_000) == 1)

        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let inherited = try await db.queue.read { sqlite in
            try String.fetchOne(sqlite, sql: """
                SELECT sem_key FROM activities WHERE app_bundle = 'com.apple.Preview'
                """)
        }
        #expect(inherited == "sem:thesis-writing")
    }

    @Test func concreteRuleOutranksCarriedLLMLabel() async throws {
        let db = try ShifuDatabase.inMemory()
        try seed(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let videoID = try #require(try videoActivity(db).id)
        let cardBuilder = CountingBackend(response: #"""
            [{"id": \#(videoID), "cat": "learning", "conf": 0.9,
              "topic": "swift actors tutorial", "entities": [],
              "gist": "watching a talk on swift actors"}]
            """#)
        _ = try await CardBuilder.run(
            database: db, backend: cardBuilder, from: 0, to: 1_000_000)

        // The user later pins youtube.com — the rule outranks the carried verdict.
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO rules (kind, value, category, ambiguous)
                VALUES ('domain', 'youtube.com', 'entertainment', 0)
                """)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(database: db), from: 0, to: 1_000_000)

        let video = try videoActivity(db)
        #expect(video.category == .entertainment)
        #expect(video.source == "user")
        #expect(video.topic == nil)
        #expect(!video.ambiguous)
    }
}

@Suite struct LabeledActivityTests {
    @Test func joinsTaskAndThemeNamesAndFiltersWindow() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (key, name, created_at, last_active_at)
                VALUES ('sem:sf-flights', 'Booking SF flights', 0, 0)
                """)
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:travel', 'Travel', 0, 0)
                """)
            var labeled = Activity(startedAt: 1_000, endedAt: 601_000,
                                   appBundle: "com.apple.Safari", domain: "united.com",
                                   category: .admin)
            var bare = Activity(startedAt: 700_000, endedAt: 1_300_000,
                                appBundle: "com.apple.dt.Xcode", category: .work)
            var outside = Activity(startedAt: 9_000_000, endedAt: 9_600_000,
                                   appBundle: "com.apple.Safari", category: .work)
            try labeled.insert(sqlite); try bare.insert(sqlite); try outside.insert(sqlite)
            try sqlite.execute(sql: """
                UPDATE activities SET task_id = 1, theme_key = 'thm:travel' WHERE id = ?
                """, arguments: [labeled.id])
        }

        let rows = try LedgerBuilder.labeledActivities(database: db, from: 0, to: 2_000_000)
        #expect(rows.count == 2)
        #expect(rows[0].source == "united.com")
        #expect(rows[0].taskName == "Booking SF flights")
        #expect(rows[0].themeName == "Travel")
        #expect(rows[1].source == "Xcode")
        #expect(rows[1].taskName == nil)
        #expect(rows[1].themeName == nil)
    }

    /// The Time page and the rings both read through here, and neither carries
    /// a system-shell clause any more — `rebuild` is the one place that rule
    /// lives (`SystemBundleDenylistTests`). What they *do* have to keep is
    /// agreeing with each other: a page and a ring that disagree make one
    /// screen's day an hour longer than the other's. The dogfood ledger held a
    /// 60-hour `loginwindow` block that buried a real day on the Time page.
    @Test func theChartAndTheRingsCountTheSameHours() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            let seeded = [
                Activity(startedAt: 0, endedAt: 60_000,
                         appBundle: "com.apple.dt.Xcode", category: .work),
                Activity(startedAt: 3_660_000, endedAt: 3_690_000,
                         appBundle: "com.mitchellh.ghostty", category: .admin)
            ]
            for var activity in seeded { try activity.insert(sqlite) }
        }

        let rows = try LedgerBuilder.labeledActivities(database: db, from: 0, to: 4_000_000)
        #expect(rows.map(\.source) == ["Xcode", "ghostty"])

        let totals = try LedgerBuilder.totals(database: db, from: 0, to: 4_000_000)
        var charted: [ShifuCore.Category: Int64] = [:]
        for row in rows {
            guard let category = ShifuCore.Category(rawValue: row.category) else { continue }
            charted[category, default: 0] += row.durationMs
        }
        #expect(totals == charted)
        #expect(totals[.work] == 60_000)
        #expect(totals[.admin] == 30_000)
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

    /// The window is a setting now (design.md §8 promised "configurable
    /// 1–90"), and the analyzer reads it on every run. This is that
    /// composition: shortening it in Settings has to scrub rows the default
    /// would have kept, or the dial is decoration.
    @Test func storedWindowGovernsWhatIsScrubbed() throws {
        let db = try ShifuDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try db.queue.write { sqlite in
            var recent = Observation(startedAt: nowMs - 10 * 86_400_000, appBundle: "a",
                                     captureKind: .ax, text: "ten days old", textSimhash: 1)
            try recent.insert(sqlite)
        }
        let setting = SettingsCatalog.textRetentionDays

        // The default keeps a ten-day-old row…
        #expect(try Retention.scrubExpiredText(
            database: db, olderThanDays: Settings.value(setting, database: db),
            now: now) == 0)

        // …and a shortened window doesn't.
        try Settings.set(setting, to: 7, database: db)
        #expect(try Retention.scrubExpiredText(
            database: db, olderThanDays: Settings.value(setting, database: db),
            now: now) == 1)
    }
}

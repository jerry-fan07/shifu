import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct StubBackend: LLMBackend {
    let name = "stub"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

private final class CountingBackend: LLMBackend, @unchecked Sendable {
    let name = "counting"
    let response: String
    private let lock = NSLock()
    private(set) var calls = 0

    init(response: String) { self.response = response }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { calls += 1 }
        return response
    }
}

@Suite struct ThemeClustererTests {
    private func seedBlock(
        _ db: ShifuDatabase, ids: inout [Int64], startedAt: Int64, minutes: Int64 = 15,
        domain: String? = nil, topic: String? = nil
    ) throws {
        try db.queue.write { sqlite in
            var activity = Activity(
                startedAt: startedAt, endedAt: startedAt + minutes * 60_000,
                appBundle: "com.apple.Safari", domain: domain,
                category: .unclassified, topic: topic)
            try activity.insert(sqlite)
            ids.append(activity.id!)
        }
    }

    @Test func promptListsRosterTaskNameAndAsksForThemes() {
        let roster = [SemanticTaskGrouper.RosterEntry(
            key: "thm:yc-startup-school", name: "YC Startup School", gist: "Sessions and events")]
        let blocks = [ThemeClusterer.BlockSample(
            id: 4, startedAt: 0, endedAt: 1_200_000, appBundle: "com.apple.Safari",
            domain: "partiful.com", topic: "afterparty rsvps",
            taskName: "Applying to YC afterparties", titles: ["RSVP — YC Afterparty"])]
        let prompt = ThemeClusterer.prompt(roster: roster, blocks: blocks)
        #expect(prompt.contains("t1: YC Startup School — Sessions and events"))
        #expect(prompt.contains("task=Applying to YC afterparties"))
        #expect(prompt.contains("topic=afterparty rsvps"))
        #expect(prompt.contains("new_themes"))
        #expect(ThemeClusterer.prompt(roster: [], blocks: blocks).contains("(none yet)"))
    }

    @Test func rosterThemeJoinsWithoutRenaming() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, gist, created_at, last_active_at)
                VALUES ('thm:travel', 'Summer travel planning', 'Trips.', 0, 5)
                """)
        }
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 1_000_000, domain: "united.com")
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "t1", "confidence": 0.9}],
             "new_themes": []}
            """#)
        let summary = try await ThemeClusterer.run(
            database: db, backend: backend, from: 0, to: 10_000_000,
            now: Date(timeIntervalSince1970: 10_000))
        #expect(summary == .init(assigned: 1, themesProposed: 0))
        let theme = try await db.queue.read { sqlite -> (String, Int64)? in
            guard let row = try Row.fetchOne(
                sqlite, sql: "SELECT name, last_active_at FROM themes") else { return nil }
            return (row["name"], row["last_active_at"])
        }
        #expect(theme?.0 == "Summer travel planning")   // renames stick
        #expect(theme?.1 == 1_900_000)                  // block end advanced it
    }

    /// A task that already lives 70%+ in one theme files its unthemed blocks
    /// there in SQL — the model only ever sees blocks inheritance couldn't
    /// place, which for settled tasks is none of them.
    @Test func dominantThemeInheritsItsTasksUnthemedBlocks() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:travel', 'Travel', 0, 5), ('thm:admin', 'Admin', 0, 5)
                """)
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'sem:sf-trip', 'SF trip', 0, 5),
                       (2, 'sem:split', 'Split task', 0, 5)
                """)
            // Task 1: 80% travel, 20% admin → dominant. Task 2: 50/50 → not.
            for (task, theme, start, minutes) in [
                (1, "thm:travel", Int64(0), Int64(80)),
                (1, "thm:admin", Int64(6_000_000), Int64(20)),
                (2, "thm:travel", Int64(12_000_000), Int64(30)),
                (2, "thm:admin", Int64(18_000_000), Int64(30))
            ] {
                try sqlite.execute(sql: """
                    INSERT INTO activities
                        (started_at, ended_at, app_bundle, category, task_id, theme_key, source)
                    VALUES (?, ?, 'com.apple.Safari', 'admin', ?, ?, 'rules')
                    """, arguments: [start, start + minutes * 60_000, task, theme])
            }
            // The unthemed blocks inheritance should (and shouldn't) file.
            for (task, start) in [(1, Int64(24_000_000)), (2, Int64(30_000_000))] {
                try sqlite.execute(sql: """
                    INSERT INTO activities
                        (started_at, ended_at, app_bundle, category, task_id, source)
                    VALUES (?, ?, 'com.apple.Safari', 'admin', ?, 'rules')
                    """, arguments: [start, start + 600_000, task])
            }
        }
        let filed = try ThemeClusterer.inheritFromTasks(database: db, from: 0, to: 100_000_000)
        #expect(filed == 1)
        let keys = try await db.queue.read { sqlite in
            try Row.fetchAll(sqlite, sql: """
                SELECT task_id, theme_key FROM activities
                WHERE started_at >= 24000000 ORDER BY started_at
                """).map { ($0["task_id"] as Int64, $0["theme_key"] as String?) }
        }
        #expect(keys[0] == (1, "thm:travel"))
        #expect(keys[1].1 == nil)
    }

    /// A `theme_key` naming a theme that no longer exists must not spread to
    /// new blocks — inheritance joins on `themes`.
    @Test func aDeletedThemesKeyDoesNotPropagate() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'sem:ghost', 'Ghost', 0, 5)
                """)
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, theme_key, source)
                VALUES (0, 3600000, 'com.apple.Safari', 'admin', 1, 'thm:gone', 'rules')
                """)
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, source)
                VALUES (7200000, 7800000, 'com.apple.Safari', 'admin', 1, 'rules')
                """)
        }
        #expect(try ThemeClusterer.inheritFromTasks(database: db, from: 0, to: 100_000_000) == 0)
    }

    /// Same closed-blocks rule as the grouper: a block still inside the
    /// sessionizer gap of `to` may grow, and its bought verdict would die
    /// with the next rebuild's span change.
    @Test func blocksStillInsideTheSessionGapAreNeverSent() throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0)
        try seedBlock(db, ids: &ids, startedAt: 9_150_000)   // ends past to − gap
        let pending = try ThemeClusterer.pendingSamples(
            database: db, from: 0, to: 10_000_000)
        #expect(pending.map(\.id) == [ids[0]])
    }

    @Test func unplacedBlockStopsBillingAfterMaxAttempts() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0)
        let backend = CountingBackend(response: #"{"assignments": [], "new_themes": []}"#)
        for _ in 0..<(ThemeClusterer.maxAttempts + 2) {
            _ = try await ThemeClusterer.run(
                database: db, backend: backend, from: 0, to: 10_000_000)
        }
        #expect(backend.calls == ThemeClusterer.maxAttempts)
    }

    @Test func narrativeRegeneratesOnlyWhenCompletedDaysChange() async throws {
        let db = try ShifuDatabase.inMemory()
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, gist, created_at, last_active_at)
                VALUES ('thm:travel', 'Travel', 'Trips.', 0, ?)
                """, arguments: [nowMs])
        }
        var ids: [Int64] = []
        // Two blocks yesterday (completed day), one today (excluded from hash).
        try seedBlock(db, ids: &ids, startedAt: todayStart - 86_400_000 + 3_600_000,
                      domain: "united.com", topic: "booking flights")
        try seedBlock(db, ids: &ids, startedAt: todayStart - 86_400_000 + 7_200_000,
                      domain: "airbnb.com")
        try seedBlock(db, ids: &ids, startedAt: todayStart + 3_600_000, domain: "lonelyplanet.com")
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET theme_key = 'thm:travel'")
        }

        let backend = CountingBackend(response: "The travel story so far.")
        let first = try await ThemeClusterer.refreshNarratives(
            database: db, backend: backend, now: now, calendar: calendar)
        #expect(first == 1)
        #expect(backend.calls == 1)
        let summary = try await db.queue.read { sqlite in
            try String.fetchOne(sqlite, sql: "SELECT summary FROM themes")
        }
        #expect(summary == "The travel story so far.")

        // Unchanged completed days: hash matches, zero calls.
        let second = try await ThemeClusterer.refreshNarratives(
            database: db, backend: backend, now: now, calendar: calendar)
        #expect(second == 0)
        #expect(backend.calls == 1)

        // A new completed day (two days ago) changes the hash: one more call.
        try seedBlock(db, ids: &ids, startedAt: todayStart - 2 * 86_400_000 + 3_600_000,
                      domain: "delta.com")
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET theme_key = 'thm:travel'")
        }
        let third = try await ThemeClusterer.refreshNarratives(
            database: db, backend: backend, now: now, calendar: calendar)
        #expect(third == 1)
        #expect(backend.calls == 2)
    }

    @Test func themeStoreOverviewsAndDetailRollUp() async throws {
        let db = try ShifuDatabase.inMemory()
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, gist, summary, created_at, last_active_at)
                VALUES ('thm:travel', 'Travel', 'Trips.', 'Story.', 0, ?)
                """, arguments: [todayStart])
            try sqlite.execute(sql: """
                INSERT INTO tasks (key, name, created_at, last_active_at)
                VALUES ('sem:sf-flights', 'Booking SF flights', 0, 0)
                """)
        }
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: todayStart - 86_400_000 + 3_600_000,
                      minutes: 60, domain: "united.com", topic: "booking flights")
        try seedBlock(db, ids: &ids, startedAt: todayStart + 3_600_000,
                      minutes: 30, domain: "airbnb.com")
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET theme_key = 'thm:travel'")
            try sqlite.execute(sql: "UPDATE activities SET task_id = 1")
        }

        let overviews = try ThemeStore.overviews(database: db, now: now)
        #expect(overviews.count == 1)
        #expect(overviews[0].name == "Travel")
        #expect(overviews[0].summary == "Story.")
        #expect(overviews[0].totalMs == 90 * 60_000)
        #expect(overviews[0].weekMs == 90 * 60_000)

        let detail = try #require(try ThemeStore.detail(
            themeID: overviews[0].id, database: db, calendar: calendar))
        #expect(detail.overview.totalMs == 90 * 60_000)
        #expect(detail.days.count == 2)                       // newest day first
        #expect(detail.days[0].durationMs == 30 * 60_000)
        #expect(detail.days[1].summary.contains("united.com"))
        #expect(detail.days[1].summary.contains("booking flights"))
        #expect(detail.tasks.map(\.name) == ["Booking SF flights"])
        #expect(detail.recent.count == 2)

        try ThemeStore.rename(themeID: overviews[0].id, to: "Summer travel", database: db)
        let renamed = try ThemeStore.overviews(database: db, now: now)[0]
        #expect(renamed.name == "Summer travel")
        #expect(renamed.gist == "Trips.")          // a rename doesn't wipe the gist
        #expect(try ThemeStore.detail(themeID: 99, database: db) == nil)

        try ThemeStore.update(themeID: renamed.id, name: nil, gist: "Flights and stays.",
                              database: db)
        #expect(try ThemeStore.overviews(database: db, now: now)[0].gist
            == "Flights and stays.")
        #expect(try ThemeStore.overviews(database: db, now: now)[0].name == "Summer travel")
    }

    @Test func themeWithOnlyTodayBlocksGetsNoNarrative() async throws {
        let db = try ShifuDatabase.inMemory()
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:fresh', 'Fresh', 0, ?)
                """, arguments: [Int64(now.timeIntervalSince1970 * 1_000)])
        }
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: todayStart + 3_600_000, domain: "x.com")
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET theme_key = 'thm:fresh'")
        }
        let backend = CountingBackend(response: "Should not be called.")
        let written = try await ThemeClusterer.refreshNarratives(
            database: db, backend: backend, now: now, calendar: calendar)
        #expect(written == 0)
        #expect(backend.calls == 0)
    }
}

// Extension keeps the suite's type body inside the lint budget.
extension ThemeClustererTests {
    /// Emptying a task's theme burns `theme_attempts` precisely so automation
    /// can't re-file what the user cleared (`TaskStore.assignTheme`). The
    /// clusterer honours that in `pendingSamples`; inheritance is the second
    /// writer of `theme_key` and has to honour it too.
    ///
    /// The clear is what makes this reachable: it zeroes the task's themed
    /// time, so the first block themed afterwards is 100% dominant on its own.
    @Test func inheritanceLeavesBlocksTheUserClearedAlone() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:dev', 'Dev', 0, 5)
                """)
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'sem:shifu', 'Shifu work', 0, 5)
                """)
            for start in [Int64(0), 3_600_000, 7_200_000] {
                try sqlite.execute(sql: """
                    INSERT INTO activities
                        (started_at, ended_at, app_bundle, category, task_id, theme_key, source)
                    VALUES (?, ?, 'com.apple.dt.Xcode', 'work', 1, 'thm:dev', 'rules')
                    """, arguments: [start, start + 1_800_000])
            }
        }
        try TaskStore.assignTheme(taskID: 1, themeKey: nil, database: db)
        // The user keeps working; the clusterer files one fresh block, which is
        // now the task's entire themed history.
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, theme_key, source)
                VALUES (10800000, 11400000, 'com.apple.dt.Xcode', 'work', 1, 'thm:dev', 'rules')
                """)
        }

        #expect(try ThemeClusterer.inheritFromTasks(
            database: db, from: 0, to: 100_000_000) == 0)
        let stillCleared = try db.queue.read { sqlite in
            try Int.fetchOne(sqlite, sql: """
                SELECT COUNT(*) FROM activities
                WHERE task_id = 1 AND theme_key IS NULL AND theme_attempts = ?
                """, arguments: [ThemeClusterer.maxAttempts])
        }
        #expect(stillCleared == 3)
    }

    /// Adopting blocks makes a theme more recently active — the rule both
    /// other writers of `theme_key` already follow (`ThemeClusterer.apply`,
    /// `TaskStore.assignTheme`). Without it a theme sustained purely by
    /// inheritance — the settled case inheritance exists to serve — sinks in
    /// the Themes list and eventually falls out of the roster and the
    /// narrative refresh, both of which cut on `last_active_at`.
    @Test func inheritanceAdvancesTheThemesRecency() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:dev', 'Dev', 0, 5)
                """)
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'sem:shifu', 'Shifu work', 0, 5)
                """)
            // Settled task: fully themed, so it is dominant outright.
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, theme_key, source)
                VALUES (0, 3600000, 'com.apple.dt.Xcode', 'work', 1, 'thm:dev', 'rules')
                """)
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, source)
                VALUES (86400000, 90000000, 'com.apple.dt.Xcode', 'work', 1, 'rules')
                """)
        }
        #expect(try ThemeClusterer.inheritFromTasks(
            database: db, from: 0, to: 100_000_000) == 1)
        #expect(try lastActive(db) == 90_000_000)

        // …and only ever forwards: an older block adopted later can't drag the
        // theme's recency back down.
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, task_id, source)
                VALUES (40000000, 50000000, 'com.apple.dt.Xcode', 'work', 1, 'rules')
                """)
        }
        #expect(try ThemeClusterer.inheritFromTasks(
            database: db, from: 0, to: 100_000_000) == 1)
        #expect(try lastActive(db) == 90_000_000)
    }

    private func lastActive(_ db: ShifuDatabase) throws -> Int64? {
        try db.queue.read { sqlite in
            try Int64.fetchOne(sqlite, sql: "SELECT last_active_at FROM themes")
        }
    }
}

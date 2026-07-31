import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct TaskGrouperKeyTests {
    @Test func topicKeysNormalize() {
        #expect(TaskGrouper.key(topic: "Debugging Shifu!", domain: nil, appBundle: "com.apple.dt.Xcode")
            == "topic:debugging-shifu")
        #expect(TaskGrouper.key(topic: "debugging   SHIFU", domain: "x.test", appBundle: "b")
            == "topic:debugging-shifu")
    }

    @Test func fallbackIsDomainThenApp() {
        #expect(TaskGrouper.key(topic: nil, domain: "GitHub.com", appBundle: "com.apple.Safari")
            == "domain:github.com")
        #expect(TaskGrouper.key(topic: nil, domain: nil, appBundle: "com.apple.dt.Xcode")
            == "app:com.apple.dt.xcode")
        // Punctuation-only topic falls through rather than making an empty slug.
        #expect(TaskGrouper.key(topic: "!!!", domain: nil, appBundle: "com.x.y") == "app:com.x.y")
    }

    @Test func defaultNamesRoundTripTheirKeys() {
        #expect(TaskGrouper.isDefaultName("debugging capture daemon",
                                          forKey: "topic:debugging-capture-daemon"))
        #expect(TaskGrouper.isDefaultName("Debugging Capture Daemon!",
                                          forKey: "topic:debugging-capture-daemon"))
        #expect(TaskGrouper.isDefaultName("GitHub.com", forKey: "domain:github.com"))
        #expect(TaskGrouper.isDefaultName("Xcode", forKey: "app:com.apple.dt.xcode"))
        // A user rename never counts as a default name.
        #expect(!TaskGrouper.isDefaultName("Port FSRS to Swift", forKey: "topic:fsrs-port"))
        #expect(!TaskGrouper.isDefaultName("Reading", forKey: "domain:github.com"))
    }

    // The denylist itself is covered in `SystemBundleDenylistTests`. It is no
    // longer this type's business: a shell never reaches the grouper because
    // `LedgerBuilder` never writes it a block.

    @Test func summaryLineReadsWhereThenWhat() {
        #expect(TaskGrouper.summaryLine(sources: ["Xcode", "github.com"],
                                        topics: ["debugging capture daemon"])
            == "Xcode, github.com — debugging capture daemon")
        #expect(TaskGrouper.summaryLine(sources: ["Xcode"], topics: []) == "Xcode")
    }
}

@Suite struct TaskGrouperPipelineTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private var day2: Date { calendar.date(byAdding: .day, value: 1, to: day1)! }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func insert(
        _ database: ShifuDatabase, start: Date, minutes: Double, app: String = "com.apple.dt.Xcode",
        domain: String? = nil, topic: String? = nil, category: ShifuCore.Category = .work
    ) throws {
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(start), endedAt: ms(start) + Int64(minutes * 60_000),
                appBundle: app, domain: domain, category: category, topic: topic)
            try activity.insert(db)
        }
    }

    private func makeDB() throws -> ShifuDatabase { try ShifuDatabase.inMemory() }

    @Test func groupsSameTopicAcrossDaysIntoOneTask() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                   topic: "debugging capture daemon")
        try insert(database, start: day2.addingTimeInterval(10 * 3_600), minutes: 30,
                   topic: "Debugging Capture Daemon")
        try insert(database, start: day1.addingTimeInterval(11 * 3_600), minutes: 15,
                   app: "com.apple.Safari", domain: "news.ycombinator.com")

        let summary = try TaskGrouper.run(
            database: database, from: 0, to: ms(day2) + 86_400_000, calendar: calendar)
        #expect(summary.tasksTouched == 2)

        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        #expect(tasks.count == 2)
        let topicTask = tasks.first { $0.key == "topic:debugging-capture-daemon" }
        #expect(topicTask != nil)
        #expect(topicTask?.name == "debugging capture daemon")

        // The task spans both days: one log per day, durations clipped per day.
        let logs = try database.queue.read { db in
            try TaskLog.filter(sql: "task_id = ?", arguments: [topicTask?.id])
                .order(sql: "day_start").fetchAll(db)
        }
        #expect(logs.count == 2)
        #expect(logs[0].durationMs == 60 * 60_000)
        #expect(logs[1].durationMs == 30 * 60_000)
        #expect(logs[0].summary.contains("Xcode"))

        // Every non-private activity got a task assignment.
        let unassigned = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activities WHERE task_id IS NULL")
        }
        #expect(unassigned == 0)
    }

    @Test func rerunIsIdempotent() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 45, topic: "shifu vault")
        let window = (from: Int64(0), to: ms(day2))
        try TaskGrouper.run(database: database, from: window.from, to: window.to, calendar: calendar)
        try TaskGrouper.run(database: database, from: window.from, to: window.to, calendar: calendar)

        let counts = try database.queue.read { db in
            (tasks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? -1,
             logs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_logs") ?? -1)
        }
        #expect(counts.tasks == 1)
        #expect(counts.logs == 1)
    }

    /// A timezone change re-keys day boundaries: rows written under the old
    /// zone sit at a different midnight inside the same day, match their own
    /// 24 h window, and double-count the day unless the rebuild purges them.
    @Test func rebuildPurgesLogsStrandedByTimezoneChange() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 45,
                   topic: "shifu vault")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)
        // A leftover row from a run under a zone 3 h ahead: same day, same
        // task, day_start at that zone's midnight.
        try database.queue.write { db in
            try db.execute(
                sql: "INSERT INTO task_logs (task_id, day_start, duration_ms, summary) "
                    + "VALUES (1, ?, 2700000, 'stale duplicate')",
                arguments: [ms(day1) + 3 * 3_600_000])
        }
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)
        let logs = try database.queue.read { try TaskLog.order(sql: "day_start").fetchAll($0) }
        #expect(logs.count == 1)
        #expect(logs[0].dayStart == ms(day1))
        #expect(logs[0].durationMs == 45 * 60_000)
    }

    @Test func midnightSpanSplitsAcrossDayLogs() throws {
        let database = try makeDB()
        // 23:30 day1 → 00:30 day2.
        try insert(database, start: day2.addingTimeInterval(-1_800), minutes: 60, topic: "late night fix")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2) + 86_400_000, calendar: calendar)

        let logs = try database.queue.read { try TaskLog.order(sql: "day_start").fetchAll($0) }
        #expect(logs.count == 2)
        #expect(logs[0].durationMs == 30 * 60_000)
        #expect(logs[1].durationMs == 30 * 60_000)
    }

    @Test func renameSurvivesRerunAndExcludesPrivate() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 20, topic: "fsrs port")
        try insert(database, start: day1.addingTimeInterval(12 * 3_600), minutes: 20,
                   app: "com.1password.1password", category: .privateTime)
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        let task = try #require(try database.queue.read { try WorkTask.fetchOne($0) })
        try TaskStore.rename(taskID: task.id!, to: "Port FSRS to Swift", database: database)
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        #expect(tasks.count == 1)                     // private time never becomes a task
        #expect(tasks[0].name == "Port FSRS to Swift")
    }

    @Test func passingSubjectsBelowGateDoNotMintTasks() throws {
        let database = try makeDB()
        // A 3-min glance at a domain and a 2-min once-worded topic: neither
        // earns a task, and their activities stay unassigned.
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 3,
                   app: "com.apple.Safari", domain: "nytimes.com")
        try insert(database, start: day1.addingTimeInterval(10 * 3_600), minutes: 2,
                   topic: "skimming rust article")
        let summary = try TaskGrouper.run(
            database: database, from: 0, to: ms(day2), calendar: calendar)
        #expect(summary.tasksTouched == 0)

        let counts = try database.queue.read { db in
            (tasks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") ?? -1,
             assigned: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM activities WHERE task_id IS NOT NULL") ?? -1,
             logs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_logs") ?? -1)
        }
        #expect(counts.tasks == 0)
        #expect(counts.assigned == 0)
        #expect(counts.logs == 0)
    }

    // "The lock screen never becomes a task" is now a property of the whole
    // pipeline rather than of this grouper — see
    // `SystemBundleDenylistTests.anObservedLockScreenNeverBecomesATask`, which
    // drives it from observations through `LedgerBuilder`.

    @Test func recurringKeyCrossesGateWithinWindowAndMints() throws {
        let database = try makeDB()
        // Three 2-min blocks of one intent: individually passing, together
        // over the gate — one task, every block assigned.
        for hour in [9.0, 11.0, 14.0] {
            try insert(database, start: day1.addingTimeInterval(hour * 3_600), minutes: 2,
                       topic: "booking flights to tokyo")
        }
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        #expect(tasks.map(\.key) == ["topic:booking-flights-to-tokyo"])
        let unassigned = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activities WHERE task_id IS NULL")
        }
        #expect(unassigned == 0)
    }

    @Test func existingTaskAccumulatesSubGateContinuations() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 10,
                   topic: "fsrs port")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        // Next day a 2-min continuation, analyzed in a window that only
        // covers day 2: the existing task attaches it despite the gate.
        try insert(database, start: day2.addingTimeInterval(9 * 3_600), minutes: 2,
                   topic: "fsrs port")
        try TaskGrouper.run(database: database, from: ms(day2), to: ms(day2) + 86_400_000,
                            calendar: calendar)

        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        #expect(tasks.count == 1)
        let logs = try database.queue.read { db in
            try TaskLog.order(sql: "day_start").fetchAll(db)
        }
        #expect(logs.count == 2)
        #expect(logs[1].durationMs == 2 * 60_000)
    }

    /// Filing a task under a theme writes every one of its blocks, so the
    /// derived task→theme relation, the theme's review deck, and a re-file all
    /// agree afterwards.
    @Test func themeAssignmentCoversEveryBlockAndSticks() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60, topic: "shifu vault")
        try insert(database, start: day1.addingTimeInterval(14 * 3_600), minutes: 30, topic: "shifu vault")
        try insert(database, start: day1.addingTimeInterval(16 * 3_600), minutes: 30, topic: "trip planning")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        let key = try #require(try ThemeStore.create(named: "Shifu development", database: database))
        #expect(key == "thm:shifu-development")
        let vaultTask = try #require(try database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks WHERE key = 'topic:shifu-vault'")
        })
        try TaskStore.assignTheme(taskID: vaultTask, themeKey: key, database: database)

        let themed = try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .theme(key: key)))
        #expect(themed.map(\.task.name) == ["shifu vault"])
        #expect(themed[0].themeName == "Shifu development")
        let loose = try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .unassigned))
        #expect(loose.map(\.task.name) == ["trip planning"])
        #expect(try ThemeStore.taskKeys(themeKey: key, database: database) == ["topic:shifu-vault"])

        // Emptying it burns the clusterer's attempts, so the next analyzer run
        // can't quietly re-file what the user just cleared.
        try TaskStore.assignTheme(taskID: vaultTask, themeKey: nil, database: database)
        #expect(try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .theme(key: key))).isEmpty)
        let pending = try ThemeClusterer.pendingSamples(
            database: database, from: 0, to: ms(day2))
        #expect(!pending.contains { $0.id == 1 || $0.id == 2 })
    }

    @Test func overviewCarriesLatestLogAndTotals() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                   topic: "grdb migrations")
        try insert(database, start: day2.addingTimeInterval(9 * 3_600), minutes: 30,
                   app: "com.apple.Safari", domain: "github.com", topic: "grdb migrations")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2) + 86_400_000, calendar: calendar)

        let overviews = try TaskStore.recentTasks(database: database)
        #expect(overviews.count == 1)
        #expect(overviews[0].totalMs == 90 * 60_000)
        #expect(overviews[0].latestSummary?.contains("github.com") == true)

        let dayLogs = try TaskStore.logs(dayStart: ms(day2), database: database)
        #expect(dayLogs.count == 1)
        #expect(dayLogs[0].taskName == "grdb migrations")
    }

    /// The recency filter drops tasks last worked before the cutoff, and the
    /// time beside a surviving row counts only the part inside the window —
    /// an activity straddling the cutoff is clipped, not counted whole.
    @Test func filterScopesBothMembershipAndTime() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                   topic: "spanning task")
        try insert(database, start: day2.addingTimeInterval(9 * 3_600), minutes: 30,
                   topic: "spanning task")
        try insert(database, start: day1.addingTimeInterval(14 * 3_600), minutes: 45,
                   topic: "day one only")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2) + 86_400_000,
                            calendar: calendar)

        let all = try TaskStore.recentTasks(database: database)
        #expect(all.count == 2)
        let spanningMs = all.first { $0.task.name == "spanning task" }?.totalMs ?? 0
        #expect(spanningMs == 90 * 60_000)

        let recent = try TaskStore.recentTasks(
            database: database, filter: .init(since: ms(day2)))
        #expect(recent.map(\.task.name) == ["spanning task"])
        #expect(recent[0].totalMs == 30 * 60_000)

        // A cutoff mid-activity keeps only the minutes after it.
        let midday = ms(day2.addingTimeInterval(9 * 3_600 + 600))
        let clipped = try TaskStore.recentTasks(
            database: database, filter: .init(since: midday))
        #expect(clipped[0].totalMs == 20 * 60_000)
    }

    /// Sorting by time spent reorders a list that recency orders differently.
    @Test func filterSortsByTimeSpentAndProject() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 120,
                   topic: "long early task")
        try insert(database, start: day1.addingTimeInterval(15 * 3_600), minutes: 20,
                   topic: "short late task")
        try TaskGrouper.run(database: database, from: 0, to: ms(day1) + 86_400_000,
                            calendar: calendar)

        let byRecency = try TaskStore.recentTasks(database: database)
        #expect(byRecency.map(\.task.name) == ["short late task", "long early task"])
        let byTime = try TaskStore.recentTasks(
            database: database, filter: .init(sort: .mostTime))
        #expect(byTime.map(\.task.name) == ["long early task", "short late task"])

        // Theme scope: one task filed, the other left loose.
        let key = try #require(try ThemeStore.create(named: "Shifu", database: database))
        try TaskStore.assignTheme(taskID: byTime[0].task.id!, themeKey: key, database: database)

        let inTheme = try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .theme(key: key)))
        #expect(inTheme.map(\.task.name) == ["long early task"])
        #expect(inTheme[0].themeName == "Shifu")

        let loose = try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .unassigned))
        #expect(loose.map(\.task.name) == ["short late task"])
    }

    /// The duration floor drops short tasks, and the match count reports the
    /// filtered total rather than the truncated page — the Task log's "50 of
    /// 364" line depends on the two agreeing.
    @Test func minimumTimeFiltersAndCountIgnoresLimit() throws {
        let database = try makeDB()
        // 6 min: over the minting gate (minNewTaskMs), under the 30-min floor.
        for hour in 0..<4 {
            try insert(database, start: day1.addingTimeInterval(Double(hour) * 3_600),
                       minutes: 6, topic: "brief task \(hour)")
        }
        try insert(database, start: day1.addingTimeInterval(10 * 3_600), minutes: 40,
                   topic: "the real task")
        try TaskGrouper.run(database: database, from: 0, to: ms(day1) + 86_400_000,
                            calendar: calendar)

        let substantial = TaskStore.TaskFilter(minimumMs: 1_800_000)
        let kept = try TaskStore.recentTasks(database: database, filter: substantial)
        #expect(kept.map(\.task.name) == ["the real task"])
        #expect(try TaskStore.matchingTaskCount(
            database: database, filter: substantial) == 1)

        // The count is of everything that matches, not of the page returned.
        let capped = TaskStore.TaskFilter(limit: 2)
        #expect(try TaskStore.recentTasks(database: database, filter: capped).count == 2)
        #expect(try TaskStore.matchingTaskCount(database: database, filter: capped) == 5)
    }

    /// The day log leads with the most recently worked task, not the longest —
    /// the Vault tab's "Today" list is a recency feed.
    @Test func dayLogLeadsWithTheMostRecentTask() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 120,
                   topic: "long morning task")
        try insert(database, start: day1.addingTimeInterval(15 * 3_600), minutes: 20,
                   topic: "short afternoon task")
        try TaskGrouper.run(database: database, from: 0, to: ms(day1) + 86_400_000,
                            calendar: calendar)

        // Filing one task lets the day log carry its theme (derived live from
        // its blocks), which the Vault tab's theme filter scopes on.
        let key = try #require(try ThemeStore.create(named: "Focus", database: database))
        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        let afternoonID = try #require(tasks.first { $0.name == "short afternoon task" }?.id)
        try TaskStore.assignTheme(taskID: afternoonID, themeKey: key, database: database)

        let dayLogs = try TaskStore.logs(dayStart: ms(day1), database: database)
        #expect(dayLogs.map(\.taskName) == ["short afternoon task", "long morning task"])
        #expect(dayLogs.map(\.themeKey) == [key, nil])
    }
}

@Suite struct TaskDetailTests {
    @Test func detailGathersHistorySourcesNotesAndRecent() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:travel', 'Travel', 0, 99)
                """)
            try db.execute(sql: """
                INSERT INTO tasks (key, name, gist, created_at, last_active_at)
                VALUES ('sem:sf-trip', 'Planning the SF trip', 'Flights and lodging.', 0, 99)
                """)
            for (index, domain) in ["united.com", "united.com", "airbnb.com"].enumerated() {
                var activity = Activity(
                    startedAt: Int64(index) * 3_600_000,
                    endedAt: Int64(index) * 3_600_000 + 600_000,
                    appBundle: "com.apple.Safari", domain: domain, category: .admin,
                    topic: index == 2 ? "picking a rental" : nil)
                try activity.insert(db)
                try db.execute(sql: """
                    UPDATE activities SET task_id = 1, theme_key = 'thm:travel' WHERE id = ?
                    """, arguments: [activity.id])
            }
            try db.execute(sql: """
                INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                VALUES (1, 0, 1800000, 'united.com — comparing fares'),
                       (1, 86400000, 600000, 'airbnb.com — picking a rental')
                """)
            try db.execute(sql: """
                INSERT INTO vault_index
                    (note_id, path, kind, task_id, captured, content_hash, mtime)
                VALUES ('01NOTE', '2026/07/27-baggage-rules.md', 'knowledge', 1, 500, 1, 1)
                """)
            let rowid = try Int64.fetchOne(db, sql: "SELECT id FROM vault_index")!
            try db.execute(sql: "INSERT INTO vault_fts (rowid, title, body) VALUES (?, ?, ?)",
                           arguments: [rowid, "Baggage rules", "carry-on limits"])
        }

        let detail = try #require(try TaskStore.detail(taskID: 1, database: database))
        #expect(detail.task.name == "Planning the SF trip")
        #expect(detail.gist == "Flights and lodging.")
        #expect(detail.themeName == "Travel")
        #expect(detail.totalMs == 3 * 600_000)
        #expect(detail.days.map(\.dayStart) == [86_400_000, 0])   // newest first
        #expect(detail.sources.map(\.source) == ["united.com", "airbnb.com"])
        #expect(detail.sources[0].ms == 1_200_000)
        #expect(detail.notes.map(\.title) == ["Baggage rules"])
        #expect(detail.recent.count == 3)
        #expect(detail.recent[0].topic == "picking a rental")     // newest first

        #expect(try TaskStore.detail(taskID: 99, database: database) == nil)
    }
}

@Suite struct ReviewDeckMatchingTests {
    @Test func exactAndContainmentTopicMatch() {
        let note = Note(topic: "GRDB migrations", body: "fact")
        #expect(TaskStore.matches(note: note, taskKey: "topic:grdb-migrations"))
        // Containment either way: extractor and classifier word topics differently.
        #expect(TaskStore.matches(note: note, taskKey: "topic:grdb"))
        let broader = Note(topic: "GRDB", body: "fact")
        #expect(TaskStore.matches(note: broader, taskKey: "topic:grdb-migrations"))
        #expect(!TaskStore.matches(note: note, taskKey: "topic:swiftui-layout"))
    }

    @Test func nonTopicKeysNeedExactMatch() {
        let note = Note(sourceApp: "Safari", sourceURL: "https://github.com/groue/GRDB.swift",
                        topic: "", body: "fact")
        #expect(TaskStore.matches(note: note, taskKey: "domain:github.com"))
        #expect(!TaskStore.matches(note: note, taskKey: "domain:gith"))
    }
}

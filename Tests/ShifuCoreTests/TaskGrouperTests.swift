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

    @Test func projectsGroupTasksAndSumTime() throws {
        let database = try makeDB()
        try insert(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60, topic: "shifu vault")
        try insert(database, start: day1.addingTimeInterval(14 * 3_600), minutes: 30, topic: "shifu radar")
        try TaskGrouper.run(database: database, from: 0, to: ms(day2), calendar: calendar)

        let project = try TaskStore.createProject(named: "Shifu", database: database)
        let tasks = try database.queue.read { try WorkTask.fetchAll($0) }
        for task in tasks {
            try TaskStore.assign(taskID: task.id!, projectID: project.id, database: database)
        }

        let summaries = try TaskStore.projects(database: database)
        #expect(summaries.count == 1)
        #expect(summaries[0].taskCount == 2)
        #expect(summaries[0].totalMs == 90 * 60_000)

        // Duplicate creation returns the existing project.
        let again = try TaskStore.createProject(named: "Shifu", database: database)
        #expect(again.id == project.id)

        let keys = try TaskStore.taskKeys(projectID: project.id!, database: database)
        #expect(Set(keys) == Set(["topic:shifu-vault", "topic:shifu-radar"]))
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
}

@Suite struct TaskPruneTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    /// A legacy task (minted before the substance gate) with one attached
    /// activity of the given length, last active at `endedAt`.
    @discardableResult
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String, minutes: Double,
        projectID: Int64? = nil, endedAt: Int64
    ) throws -> Int64 {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name, projectID: projectID,
                                createdAt: endedAt, lastActiveAt: endedAt)
            try task.insert(db)
            var activity = Activity(
                startedAt: endedAt - Int64(minutes * 60_000), endedAt: endedAt,
                appBundle: "com.apple.Safari",
                domain: key.hasPrefix("domain:") ? String(key.dropFirst(7)) : nil,
                category: .work)
            try activity.insert(db)
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                           arguments: [task.id, activity.id])
            var log = TaskLog(taskID: task.id!, dayStart: endedAt - endedAt % 86_400_000,
                              durationMs: Int64(minutes * 60_000), summary: name)
            try log.insert(db)
            return task.id!
        }
    }

    @Test func prunesOnlyStaleSubThresholdDefaultNamedTasks() throws {
        let database = try ShifuDatabase.inMemory()
        let stale = ms(day1)
        let now = day1.addingTimeInterval(9 * 86_400)

        let junk = try seedTask(database, key: "domain:nytimes.com", name: "nytimes.com",
                                minutes: 3, endedAt: stale)
        let renamed = try seedTask(database, key: "topic:skim-rust", name: "Rust research",
                                   minutes: 3, endedAt: stale)
        let big = try seedTask(database, key: "domain:github.com", name: "github.com",
                               minutes: 45, endedAt: stale)
        try seedTask(database, key: "domain:united.com", name: "united.com",
                     minutes: 3, endedAt: ms(now) - 3_600_000)
        let project = try TaskStore.createProject(named: "Trips", database: database)
        try seedTask(database, key: "domain:kayak.com", name: "kayak.com",
                     minutes: 3, projectID: project.id, endedAt: stale)

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO task_merge_suggestions (task_a, task_b, cosine, status, created_at)
                VALUES (?, ?, 0.95, 'new', 0), (?, ?, 0.95, 'dismissed', 0)
                """, arguments: [junk, big, renamed, big])
            try db.execute(sql: """
                INSERT INTO project_suggestions (task_id, project_id, cosine, status, created_at)
                VALUES (?, ?, 0.9, 'new', 0)
                """, arguments: [junk, project.id])
        }

        let pruned = try TaskStore.prune(database: database, now: now, calendar: calendar)
        #expect(pruned == 1)

        let keys = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM tasks ORDER BY key")
        }
        #expect(keys == ["domain:github.com", "domain:kayak.com",
                         "domain:united.com", "topic:skim-rust"])

        // The activity survives task-less; the junk task's log cascaded away.
        let state = try database.queue.read { db in
            (orphans: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM activities WHERE task_id IS NULL
                """) ?? -1,
             junkLogs: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM task_logs WHERE task_id = \(junk)
                """) ?? -1,
             merges: try String.fetchAll(db, sql: "SELECT status FROM task_merge_suggestions"),
             projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_suggestions") ?? -1)
        }
        #expect(state.orphans == 1)
        #expect(state.junkLogs == 0)
        #expect(state.merges == ["dismissed"])  // only the open pair naming junk died
        #expect(state.projects == 0)

        // Re-running finds nothing left to prune.
        #expect(try TaskStore.prune(database: database, now: now, calendar: calendar) == 0)
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

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

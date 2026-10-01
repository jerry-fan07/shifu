import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// What a task overview costs over time: a documented task is revised at most
/// weekly, from its last week of day notes plus the document itself — where it
/// used to be rewritten on every newly completed day from thirty of them.
@Suite struct TaskOverviewCadenceTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private func daysAgo(_ count: Int) -> Date {
        calendar.date(byAdding: .day, value: -count, to: today)!
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private final class Backend: LLMBackend, @unchecked Sendable {
        let name = "cadence"
        let answer: String
        private let lock = NSLock()
        private var prompts: [String] = []
        init(answer: String = "## Status\nMid-flight.") { self.answer = answer }
        var calls: Int { lock.withLock { prompts.count } }
        var lastPrompt: String { lock.withLock { prompts.last ?? "" } }
        func complete(prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { prompts.append(prompt) }
            return answer
        }
    }

    private func scratch() throws -> (ShifuDatabase, VaultStore) {
        let database = try ShifuDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-overview-cadence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (database, VaultStore(root: root, database: database))
    }

    /// One learning task with an hour, a task log and a day note per day.
    private func seedTask(
        _ database: ShifuDatabase, _ vault: VaultStore, key: String, name: String, days: [Date]
    ) throws {
        let taskID = try database.queue.write { db -> Int64 in
            var task = WorkTask(key: key, name: name, createdAt: ms(days[0]),
                                lastActiveAt: ms(days.last!))
            try task.insert(db)
            return task.id!
        }
        for day in days {
            try database.queue.write { db in
                var activity = Activity(
                    startedAt: ms(day) + 9 * 3_600_000, endedAt: ms(day) + 10 * 3_600_000,
                    appBundle: "com.apple.Safari", category: .learning)
                try activity.insert(db)
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                               arguments: [taskID, activity.id])
                var log = TaskLog(taskID: taskID, dayStart: ms(day),
                                  durationMs: 3_600_000, summary: "Safari — \(name)")
                try log.insert(db)
            }
            try vault.saveWork(WorkNote(
                taskKey: key, taskName: name,
                day: WorkNoteCompiler.dayString(ms(day), calendar: calendar),
                durationMs: 3_600_000, contentHash: ms(day), summary: "Safari — \(name)",
                sessionsProse: "- **09:00–10:00** — worked on \(name)."))
        }
    }

    private func headings(_ prompt: String) -> Int {
        prompt.components(separatedBy: "\n").filter { $0.hasPrefix("### 20") }.count
    }

    @Test func onlyTheLastWeekOfDayNotesIsSent() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, vault, key: "sem:thesis", name: "Thesis",
                     days: (1...12).reversed().map(daysAgo))
        let backend = Backend()
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend, now: today, calendar: calendar)
        #expect(backend.calls == 1)
        #expect(headings(backend.lastPrompt) == TaskOverviewCompiler.maxDayNotes)
        // The newest days, not the oldest.
        #expect(backend.lastPrompt.contains(
            WorkNoteCompiler.dayString(ms(daysAgo(1)), calendar: calendar)))
        #expect(!backend.lastPrompt.contains(
            WorkNoteCompiler.dayString(ms(daysAgo(12)), calendar: calendar)))
    }

    /// An empty answer re-stamps the document the task already has, so the
    /// same prompt isn't re-sent every pass until something changes.
    @Test func anEmptyAnswerWaitsOutTheIntervalToo() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, vault, key: "sem:thesis", name: "Thesis",
                     days: [daysAgo(9), daysAgo(8)])
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: Backend(),
            now: daysAgo(7), calendar: calendar)
        let written = try #require(vault.taskOverview(taskKey: "sem:thesis"))

        try seedTask(database, vault, key: "sem:thesis-more", name: "Thesis more",
                     days: [daysAgo(1)])
        try await database.queue.write { db in
            try db.execute(sql: """
                UPDATE activities SET task_id = (SELECT id FROM tasks WHERE key = 'sem:thesis')
                """)
            try db.execute(sql: """
                UPDATE task_logs SET task_id = (SELECT id FROM tasks WHERE key = 'sem:thesis')
                """)
        }
        try vault.saveWork(WorkNote(
            taskKey: "sem:thesis", taskName: "Thesis",
            day: WorkNoteCompiler.dayString(ms(daysAgo(1)), calendar: calendar),
            durationMs: 3_600_000, contentHash: 1, summary: "Safari — Thesis",
            sessionsProse: "- **09:00–10:00** — a new chapter."))

        let silent = Backend(answer: "   ")
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: silent, now: today, calendar: calendar)
        #expect(silent.calls == 1)
        let restamped = try #require(vault.taskOverview(taskKey: "sem:thesis"))
        #expect(restamped.body == written.body)
        #expect(restamped.inputHash != written.inputHash)

        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: silent, now: today, calendar: calendar)
        #expect(silent.calls == 1)
    }

    /// The per-run cap counts only tasks that are due, so six documented
    /// tasks waiting out their week can't keep a seventh from its first.
    @Test func tasksWaitingOutTheirWeekDoNotStarveANewOne() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        for index in 0..<TaskOverviewCompiler.maxTasksPerRun {
            try seedTask(database, vault, key: "sem:old-\(index)", name: "Old \(index)",
                         days: [daysAgo(3), daysAgo(1)])
        }
        let backend = Backend()
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend, now: today, calendar: calendar)
        #expect(backend.calls == TaskOverviewCompiler.maxTasksPerRun)

        // A less recently active task shows up; the six are all inside
        // their week, so it is the one written.
        try seedTask(database, vault, key: "sem:new", name: "New", days: [daysAgo(4)])
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend,
            now: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
        #expect(backend.calls == TaskOverviewCompiler.maxTasksPerRun + 1)
        #expect(vault.taskOverview(taskKey: "sem:new") != nil)
    }
}

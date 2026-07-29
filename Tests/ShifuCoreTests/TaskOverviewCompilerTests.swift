import Foundation
import GRDB
import Testing
@testable import ShifuCore

private final class OverviewBackend: LLMBackend, @unchecked Sendable {
    let name = "overview"
    let contextWindowTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(window: Int = 60_000) { self.contextWindowTokens = window }

    var calls: Int { lock.withLock { prompts.count } }
    var lastPrompt: String { lock.withLock { prompts.last ?? "" } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return "## Status\nMid-flight.\n\n## Open threads\n- Finish the proof."
    }
}

@Suite struct TaskOverviewCompilerTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private func daysAgo(_ count: Int) -> Date {
        calendar.date(byAdding: .day, value: -count, to: today)!
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func scratch() throws -> (ShifuDatabase, VaultStore) {
        let database = try ShifuDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-overview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (database, VaultStore(root: root, database: database))
    }

    /// A task with one activity + task_log + work note per day in `days`.
    private func seedTask(
        _ database: ShifuDatabase, _ vault: VaultStore, key: String, name: String,
        days: [Date], minutes: Int64 = 60, category: ShifuCore.Category = .learning
    ) throws {
        let taskID = try database.queue.write { db -> Int64 in
            var task = WorkTask(key: key, name: name, createdAt: ms(days[0]),
                                lastActiveAt: ms(days.last!))
            try task.insert(db)
            try db.execute(sql: "UPDATE tasks SET gist = ? WHERE id = ?",
                           arguments: ["All about \(name)", task.id])
            return task.id!
        }
        for day in days {
            try database.queue.write { db in
                var activity = Activity(
                    startedAt: ms(day) + 9 * 3_600_000,
                    endedAt: ms(day) + 9 * 3_600_000 + minutes * 60_000,
                    appBundle: "com.apple.Safari", category: category)
                try activity.insert(db)
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                               arguments: [taskID, activity.id])
                var log = TaskLog(taskID: taskID, dayStart: ms(day),
                                  durationMs: minutes * 60_000, summary: "Safari — \(name)")
                try log.insert(db)
            }
            try vault.saveWork(WorkNote(
                taskKey: key, taskName: name,
                day: WorkNoteCompiler.dayString(ms(day), calendar: calendar),
                durationMs: minutes * 60_000, contentHash: ms(day),
                summary: "Safari — \(name)",
                sessionsProse: "- **09:00–10:00** — worked on \(name) that day.",
                detailProse: "### What was worked on\nDeep work on \(name)."))
        }
    }

    @Test func compilesOnceAndSkipsWhenNothingCompletedChanged() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, vault, key: "sem:nmf", name: "NMF research",
                     days: [daysAgo(3), daysAgo(2), daysAgo(1)])
        let backend = OverviewBackend()

        let summary = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend,
            now: today, calendar: calendar)
        #expect(summary.written == 1)
        #expect(backend.calls == 1)
        // The prompt is built from the day notes, gist included.
        #expect(backend.lastPrompt.contains("NMF research"))
        #expect(backend.lastPrompt.contains("All about NMF research"))
        #expect(backend.lastPrompt.contains("Deep work on NMF research"))
        #expect(backend.lastPrompt.contains("No flashcards"))

        let overview = try #require(vault.taskOverview(taskKey: "sem:nmf"))
        #expect(overview.taskName == "NMF research")
        #expect(overview.body.contains("## Status"))

        // Nothing completed changed ⇒ zero tokens on the next run.
        let second = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend,
            now: today, calendar: calendar)
        #expect(second.written == 0)
        #expect(backend.calls == 1)
    }

    /// Today's note is still growing, so it must not feed the hash — otherwise
    /// every hourly run would regenerate the document.
    @Test func todaysDayNoteIsExcluded() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, vault, key: "sem:nmf", name: "NMF research",
                     days: [daysAgo(2), daysAgo(1)])
        let backend = OverviewBackend()
        _ = try await TaskOverviewCompiler.run(database: database, vault: vault,
                                               backend: backend, now: today,
                                               calendar: calendar)
        #expect(backend.calls == 1)
        // Count only the day headings — the detail prose has `###` too.
        #expect(dayHeadings(in: backend.lastPrompt).count == 2)

        // Today's work on the same task lands a third day note. It must not
        // move the gate, or every hourly run would regenerate the document.
        try appendToday(database, vault, taskKey: "sem:nmf", name: "NMF research")
        _ = try await TaskOverviewCompiler.run(database: database, vault: vault,
                                               backend: backend, now: today,
                                               calendar: calendar)
        #expect(backend.calls == 1)

        // Once that day is behind us, it counts and the document is rebuilt.
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend,
            now: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
        #expect(backend.calls == 2)
        #expect(dayHeadings(in: backend.lastPrompt).count == 3)
    }

    /// The `### YYYY-MM-DD` lines the prompt files each day under.
    private func dayHeadings(in prompt: String) -> [String] {
        prompt.components(separatedBy: "\n")
            .filter { $0.hasPrefix("### 20") }
    }

    /// One more day of work on an existing task, dated today.
    private func appendToday(
        _ database: ShifuDatabase, _ vault: VaultStore, taskKey: String, name: String
    ) throws {
        let taskID = try database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks WHERE key = ?",
                               arguments: [taskKey])!
        }
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(today) + 9 * 3_600_000,
                endedAt: ms(today) + 10 * 3_600_000,
                appBundle: "com.apple.Safari", category: .learning)
            try activity.insert(db)
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                           arguments: [taskID, activity.id])
            var log = TaskLog(taskID: taskID, dayStart: ms(today),
                              durationMs: 3_600_000, summary: "Safari — \(name)")
            try log.insert(db)
        }
        try vault.saveWork(WorkNote(
            taskKey: taskKey, taskName: name,
            day: WorkNoteCompiler.dayString(ms(today), calendar: calendar),
            durationMs: 3_600_000, contentHash: ms(today), summary: "Safari — \(name)",
            sessionsProse: "- **09:00–10:00** — more work on \(name).",
            detailProse: "### What was worked on\nToday's deep work on \(name)."))
    }

    @Test func ineligibleTasksAreSkipped() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        // Mostly admin: documented days aren't what this task is made of.
        try seedTask(database, vault, key: "sem:expenses", name: "Expenses",
                     days: [daysAgo(2), daysAgo(1)], category: ShifuCore.Category.admin)
        // Learning, but under the 30-minute floor.
        try seedTask(database, vault, key: "sem:glance", name: "Glance",
                     days: [daysAgo(1)], minutes: 10)
        let backend = OverviewBackend()

        let summary = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend,
            now: today, calendar: calendar)
        #expect(summary.written == 0)
        #expect(backend.calls == 0)
    }

    /// The file must be a kind that can never enter inbox or review queries,
    /// and must round-trip through the index like every other vault file.
    @Test func overviewFileIsItsOwnKindAndIndexes() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, vault, key: "sem:nmf", name: "NMF research",
                     days: [daysAgo(2), daysAgo(1)])
        _ = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: OverviewBackend(),
            now: today, calendar: calendar)

        let url = vault.taskOverviewURL(taskKey: "sem:nmf")
        #expect(url.path.contains("/tasks/"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(FrontMatter.parse(text)?.kind == .taskOverview)
        #expect(Note.parse(text) == nil)
        #expect(WorkNote.parse(text) == nil)
        #expect(try vault.allNotes().isEmpty)   // not a Note at all
        #expect(try vault.due().isEmpty)

        try VaultIndexer.reconcile(root: vault.root, database: database)
        let kinds = try await database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT kind FROM vault_index WHERE path LIKE 'tasks/%'
                """)
        }
        #expect(kinds == ["task_overview"])
    }

    @Test func budgetDropsOldestDaysRatherThanFailing() throws {
        let days = (0..<8).map { index in
            TaskOverviewCompiler.DayNote(
                day: "2026-07-0\(index + 1)", summary: "Safari — research",
                sessionsProse: String(repeating: "long session prose. ", count: 200),
                detailProse: nil)
        }
        let candidate = TaskOverviewCompiler.Candidate(
            taskKey: "sem:nmf", taskName: "NMF research", gist: nil,
            days: days, inputHash: 1)
        let backend = OverviewBackend(window: TaskOverviewCompiler.responseTokens + 2_000)

        let text = TaskOverviewCompiler.budgeted(candidate, previous: nil, backend: backend)
        #expect(LLMTokens.estimate(text) + TaskOverviewCompiler.responseTokens
            <= backend.contextWindowTokens)
        // The oldest go first; the most recent day is what says where it stands.
        #expect(text.contains("2026-07-08"))
        #expect(!text.contains("2026-07-01"))
    }
}

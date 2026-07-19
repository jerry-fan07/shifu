import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Counts LLM calls so tests can assert the content-hash gate: unchanged
/// days must make zero calls (vault-features.md §2.1).
private final class CountingBackend: LLMBackend, @unchecked Sendable {
    let name = "counting"
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int { lock.withLock { callCount } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { callCount += 1 }
        return "- **09:00–10:00** — chased the observer leak; landed the fix"
    }
}

/// Returns one knowledge candidate, for task_key stamping tests.
private struct ExtractorBackend: LLMBackend {
    let name = "extractor"
    func complete(prompt: String, maxTokens: Int) async throws -> String {
        #"[{"topic": "sck single frame", "note": "SCScreenshotManager captures one frame.", "confidence": 0.9}]"#
    }
}

@Suite struct WorkNoteModelTests {
    @Test func roundTripsThroughSerialization() throws {
        let note = WorkNote(
            id: "01TESTULID0000000000000000", taskKey: "topic:capture-daemon",
            taskName: "Capture daemon", day: "2026-07-18", durationMs: 9_840_000,
            sources: ["Xcode", "github.com"],
            sessions: [.init(start: "09:12", end: "10:41"), .init(start: "14:03", end: "15:20")],
            project: "shifu", contentHash: -42,
            summary: "Xcode, github.com — debugging capture daemon",
            sessionsProse: "- **09:12–10:41** — Chased the AX observer leak.",
            capturedLinks: ["17-sck-single-frame"])
        let parsed = try #require(WorkNote.parse(note.serialize()))
        #expect(parsed == note)
    }

    @Test func lineOneOnlyNoteIsValid() throws {
        let note = WorkNote(
            taskKey: "domain:github.com", taskName: "github.com", day: "2026-07-18",
            durationMs: 60_000, contentHash: 7, summary: "github.com")
        let parsed = try #require(WorkNote.parse(note.serialize()))
        #expect(parsed.sessionsProse == nil)
        #expect(parsed.capturedLinks.isEmpty)
        #expect(parsed.summary == "github.com")
    }

    @Test func knowledgeNotesAreNotWorkNotes() {
        let knowledge = Note(topic: "sqlite wal", body: "WAL journals ahead.")
        #expect(WorkNote.parse(knowledge.serialize()) == nil)
    }
}

@Suite struct WorkNoteCompilerTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private var day2: Date { calendar.date(byAdding: .day, value: 1, to: day1)! }
    private var day3: Date { calendar.date(byAdding: .day, value: 2, to: day1)! }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func makeVault(_ database: ShifuDatabase) throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-worknotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VaultStore(root: root, database: database)
    }

    @discardableResult
    private func insertActivity(
        _ database: ShifuDatabase, start: Date, minutes: Double,
        app: String = "com.apple.dt.Xcode", domain: String? = nil,
        topic: String? = "debugging capture daemon",
        category: ShifuCore.Category = .work, sampleText: String? = nil
    ) throws -> Int64 {
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(start), endedAt: ms(start) + Int64(minutes * 60_000),
                appBundle: app, domain: domain, category: category, topic: topic)
            try activity.insert(db)
            let activityID = activity.id ?? db.lastInsertedRowID
            if let sampleText {
                try db.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, capture_kind, text, session_id)
                    VALUES (?, ?, ?, 'ax', ?, ?)
                    """, arguments: [ms(start), ms(start), app, sampleText, activityID])
            }
            return activityID
        }
    }

    private func compile(
        _ database: ShifuDatabase, _ vault: VaultStore,
        backend: (any LLMBackend)? = nil, from: Date, to: Date
    ) async throws -> WorkNoteCompiler.Summary {
        try TaskGrouper.run(database: database, from: ms(from), to: ms(to))
        return try await WorkNoteCompiler.run(
            database: database, vault: vault, backend: backend, from: ms(from), to: ms(to))
    }

    @Test func compilesDeterministicNoteAndIsIdempotent() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                           sampleText: "GRDB WAL docs")
        try insertActivity(database, start: day1.addingTimeInterval(14 * 3_600), minutes: 30,
                           domain: "github.com", topic: "debugging capture daemon")

        let first = try await compile(database, vault, from: day1, to: day2)
        #expect(first.notesWritten == 1)
        #expect(first.narrativesGenerated == 0)

        let note = try #require(vault.workNote(
            day: WorkNoteCompiler.dayString(ms(day1), calendar: calendar),
            taskKey: "topic:debugging-capture-daemon"))
        #expect(note.durationMs == 90 * 60_000)
        #expect(note.sources == ["Xcode", "github.com"])
        #expect(note.sessions.count == 2)   // 5 h gap splits the day
        #expect(note.summary.contains("Xcode"))
        #expect(note.sessionsProse == nil)  // no backend ⇒ line 1 only

        let url = vault.workNoteURL(day: note.day, taskKey: note.taskKey)
        let bytesBefore = try String(contentsOf: url, encoding: .utf8)
        _ = try await compile(database, vault, from: day1, to: day2)
        let bytesAfter = try String(contentsOf: url, encoding: .utf8)
        #expect(bytesBefore == bytesAfter)  // identical files, same id kept
    }

    @Test func hashGateSpendsZeroTokensOnUnchangedDays() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = CountingBackend()
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)  // unchanged day: prose carried, no call

        // LedgerBuilder's idempotent rebuild recreates the same spans and text
        // under fresh row ids every analyzer run — still no regeneration.
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM observations")
            try db.execute(sql: "DELETE FROM activities")
        }
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)

        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)
        let carried = try #require(vault.workNote(
            day: dayStr, taskKey: "topic:debugging-capture-daemon"))
        #expect(carried.sessionsProse?.contains("observer leak") == true)

        // New activity on the same task-day changes the hash ⇒ regenerate.
        try insertActivity(database, start: day1.addingTimeInterval(16 * 3_600), minutes: 20,
                           sampleText: "perf harness output")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 2)
    }

    @Test func substanceThresholdSkipsNarrative() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = CountingBackend()
        // 3 minutes < 10-minute default; text present but too little time.
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 3,
                           sampleText: "dashboard glance")
        // 45 minutes but zero text samples.
        try insertActivity(database, start: day1.addingTimeInterval(11 * 3_600), minutes: 45,
                           app: "com.apple.mail", topic: "reading mail")

        let summary = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(summary.notesWritten == 2)
        #expect(summary.narrativesGenerated == 0)
        #expect(backend.calls == 0)
    }

    @Test func privateActivitiesNeverReachTheVault() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                           sampleText: "public work")
        try insertActivity(database, start: day1.addingTimeInterval(11 * 3_600), minutes: 60,
                           topic: "SECRET-TOPIC", category: .privateTime,
                           sampleText: "SECRET-SAMPLE-TEXT")

        _ = try await compile(database, vault, from: day1, to: day2)

        let enumerator = FileManager.default.enumerator(at: vault.root,
                                                        includingPropertiesForKeys: nil)!
        let files = enumerator.allObjects.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("SECRET"))
        }
    }

    @Test func taskRenameSurvivesRebuild() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60)
        _ = try await compile(database, vault, from: day1, to: day2)

        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)
        let before = try #require(vault.workNote(day: dayStr,
                                                 taskKey: "topic:debugging-capture-daemon"))

        let taskID = try await database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks WHERE key = ?",
                               arguments: ["topic:debugging-capture-daemon"])!
        }
        try TaskStore.rename(taskID: taskID, to: "Fix the daemon", database: database)
        _ = try await compile(database, vault, from: day1, to: day2)

        let after = try #require(vault.workNote(day: dayStr,
                                                taskKey: "topic:debugging-capture-daemon"))
        #expect(after.id == before.id)              // same file identity
        #expect(after.taskName == "Fix the daemon") // display name refreshed
    }

    @Test func capturedSectionLinksTheDaysKnowledgeNotes() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60)
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))

        // A knowledge note stamped with the task's key, captured that day.
        let knowledge = Note(captured: day1.addingTimeInterval(10 * 3_600),
                             topic: "sck single frame",
                             taskKey: "topic:debugging-capture-daemon",
                             body: "One frame, no stream.")
        try vault.save(knowledge)

        _ = try await WorkNoteCompiler.run(
            database: database, vault: vault, backend: nil, from: ms(day1), to: ms(day2))

        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)
        let work = try #require(vault.workNote(day: dayStr,
                                               taskKey: "topic:debugging-capture-daemon"))
        let expectedLink = "\(knowledge.id.lowercased())-sck-single-frame"
        #expect(work.capturedLinks == [expectedLink])
        #expect(work.serialize().contains("[[\(expectedLink)]]"))
    }

    @Test func dateRangeForgetRemovesAndRecompilesNotes() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        for day in [day1, day2, day3] {
            try insertActivity(database, start: day.addingTimeInterval(9 * 3_600), minutes: 60)
            try insertActivity(database, start: day.addingTimeInterval(14 * 3_600), minutes: 30)
        }
        _ = try await compile(database, vault, from: day1, to: calendar.date(
            byAdding: .day, value: 1, to: day3)!)

        let dayStr = { (day: Date) in WorkNoteCompiler.dayString(self.ms(day), calendar: self.calendar) }
        #expect(vault.workNote(day: dayStr(day2), taskKey: "topic:debugging-capture-daemon") != nil)

        // Forget day 2 entirely plus day 3's morning (boundary).
        try DeletionTools.forgetRange(
            database: database, from: day2, to: day3.addingTimeInterval(10 * 3_600),
            vault: vault)

        #expect(vault.workNote(day: dayStr(day1), taskKey: "topic:debugging-capture-daemon") != nil)
        #expect(vault.workNote(day: dayStr(day2), taskKey: "topic:debugging-capture-daemon") == nil)
        let boundary = try #require(vault.workNote(day: dayStr(day3),
                                                   taskKey: "topic:debugging-capture-daemon"))
        #expect(boundary.durationMs == 30 * 60_000)  // afternoon survived

        // Index rows follow immediately: nothing for day 2 remains.
        let day2Rows = try await database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM vault_index
                WHERE kind = 'work' AND captured >= ? AND captured < ?
                """, arguments: [ms(day2), ms(day3)])!
        }
        #expect(day2Rows == 0)
        // Stale task_logs went with it.
        let day2Logs = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_logs WHERE day_start = ?",
                             arguments: [ms(calendar.startOfDay(for: day2))])!
        }
        #expect(day2Logs == 0)
    }

    @Test func analyzerOrderKeepsTaskRowsIdentical() async throws {
        // The V2 pipeline runs TaskGrouper before extraction; grouping again
        // after an extraction pass must not change task or log rows.
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 60,
                           category: .learning,
                           sampleText: String(repeating: "SCScreenshotManager docs. ", count: 12))
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        let snapshot = { try self.taskRows(database) }
        let before = try snapshot()

        _ = try await KnowledgeExtractor.run(
            database: database, vault: vault, backend: ExtractorBackend(),
            from: ms(day1), to: ms(day2))
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        #expect(try snapshot() == before)

        // And extraction stamped the source task's key into the note (§2.3).
        let inbox = try vault.inbox()
        #expect(inbox.count == 1)
        #expect(inbox.first?.taskKey == "topic:debugging-capture-daemon")
        #expect(TaskStore.matches(note: inbox[0], taskKey: "topic:debugging-capture-daemon"))
        #expect(!TaskStore.matches(note: inbox[0], taskKey: "topic:something-else"))
    }

    private func taskRows(_ database: ShifuDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT t.key || '|' || t.name || '|' || l.day_start || '|'
                       || l.duration_ms || '|' || l.summary
                FROM task_logs l JOIN tasks t ON t.id = l.task_id
                ORDER BY l.day_start, t.key
                """)
        }
    }
}

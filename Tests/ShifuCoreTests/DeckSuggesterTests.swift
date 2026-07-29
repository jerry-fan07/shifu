import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Replies from a script, one entry per call, and records every prompt — the
/// caps are call-count claims, so counting is the point.
private final class ScriptedBackend: LLMBackend, @unchecked Sendable {
    let name = "scripted"
    private let lock = NSLock()
    private var responses: [String]
    private(set) var prompts: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    var calls: Int { lock.withLock { prompts.count } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock {
            prompts.append(prompt)
            return responses.isEmpty ? "{\"worth\": false}" : responses.removeFirst()
        }
    }
}

@Suite struct DeckSuggesterTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }

    private func worthResponse(title: String, cards: Int) -> String {
        let items = (0..<cards).map { index in
            """
            {"topic": "topic \(index)", "note": "An explanation of topic \(index).",
             "question": "What is topic \(index) in FSRS?", "answer": "It is the \(index) one.",
             "confidence": 0.9}
            """
        }.joined(separator: ", ")
        return #"{"worth": true, "title": "\#(title)", "cards": [\#(items)]}"#
    }

    /// A task with `minutes` of `category` time in the window, plus screen
    /// text so the prompt has evidence to carry.
    @discardableResult
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String,
        minutes: Int64, category: ShifuCore.Category = .learning, daysAgo: Int64 = 1
    ) throws -> Int64 {
        let endedAt = nowMs - daysAgo * 86_400_000
        return try database.queue.write { db in
            var task = WorkTask(key: key, name: name, createdAt: endedAt,
                                lastActiveAt: endedAt)
            try task.insert(db)
            try db.execute(sql: "UPDATE tasks SET gist = ? WHERE id = ?",
                           arguments: ["Learning \(name)", task.id])
            var activity = Activity(
                startedAt: endedAt - minutes * 60_000, endedAt: endedAt,
                appBundle: "com.apple.Safari", category: category)
            try activity.insert(db)
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                           arguments: [task.id, activity.id])
            var observation = Observation(
                startedAt: activity.startedAt, lastSeen: endedAt,
                appBundle: "com.apple.Safari", captureKind: .ocr,
                text: "Stability is the number of days until recall probability "
                    + "falls to 90 percent for \(name).", sessionId: activity.id)
            try observation.insert(db)
            var log = TaskLog(taskID: task.id!, dayStart: endedAt - endedAt % 86_400_000,
                              durationMs: minutes * 60_000,
                              summary: "Safari — reading about \(name)")
            try log.insert(db)
            return task.id!
        }
    }

    // MARK: - Selection

    @Test func onlySubstantialIntentNamedFocusTasksQualify() throws {
        let database = try ShifuDatabase.inMemory()
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", minutes: 90)
        try seedTask(database, key: "topic:convex-opt", name: "Convex optimization",
                     minutes: 60, category: ShifuCore.Category.work)
        // Too little time to be worth a deck.
        try seedTask(database, key: "sem:brief-skim", name: "Brief skim", minutes: 10)
        // A container key names no subject — never a deck candidate.
        try seedTask(database, key: "domain:github.com", name: "github.com", minutes: 200)
        // Substantial, but the time is mostly admin.
        try seedTask(database, key: "sem:expenses", name: "Expenses", minutes: 90,
                     category: ShifuCore.Category.admin)
        // Outside the 14-day window.
        try seedTask(database, key: "sem:old-course", name: "Old course", minutes: 300,
                     daysAgo: 30)

        let keys = try DeckSuggester.candidates(database: database, now: now).map(\.taskKey)
        #expect(keys == ["sem:fsrs", "topic:convex-opt"])   // richest first
    }

    /// A task with a *tail* of learning inside mostly-admin time is not a
    /// deck, even when the tail alone clears the minute floor.
    @Test func dominanceIsMeasuredAgainstTheWholeTask() throws {
        let database = try ShifuDatabase.inMemory()
        try seedTask(database, key: "sem:mixed", name: "Mixed", minutes: 50)
        try database.queue.write { db in
            let taskID = try Int64.fetchOne(
                db, sql: "SELECT id FROM tasks WHERE key = 'sem:mixed'")
            var admin = Activity(startedAt: nowMs - 200 * 60_000, endedAt: nowMs - 100 * 60_000,
                                 appBundle: "com.apple.Mail", category: .admin)
            try admin.insert(db)
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                           arguments: [taskID, admin.id])
        }
        #expect(try DeckSuggester.candidates(database: database, now: now).isEmpty)
    }

    @Test func decksAndVerdictsSuppressATaskForever() throws {
        let database = try ShifuDatabase.inMemory()
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", minutes: 90)
        try seedTask(database, key: "sem:convex", name: "Convex", minutes: 80)
        try seedTask(database, key: "sem:graphs", name: "Graphs", minutes: 70)

        try DeckStore.create(title: "FSRS", taskKey: "sem:fsrs", database: database)
        try DeckStore.decline(taskKey: "sem:convex", database: database)

        let keys = try DeckSuggester.candidates(database: database, now: now).map(\.taskKey)
        #expect(keys == ["sem:graphs"])
    }

    // MARK: - Parse

    @Test func worthFalseAndThinProposalsBothMeanNo() {
        #expect(DeckSuggester.parse(#"{"worth": false}"#) == nil)
        #expect(DeckSuggester.parse("not json at all") == nil)
        // One card can't demonstrate a deck.
        #expect(DeckSuggester.parse(worthResponse(title: "FSRS", cards: 1)) == nil)
        // Cards without a Q/A are reference notes, not samples of a deck.
        #expect(DeckSuggester.parse("""
            {"worth": true, "title": "FSRS", "cards": [
              {"topic": "a", "note": "n", "confidence": 0.9},
              {"topic": "b", "note": "n", "confidence": 0.9}]}
            """) == nil)

        let proposal = DeckSuggester.parse(worthResponse(title: "FSRS internals", cards: 3))
        #expect(proposal?.title == "FSRS internals")
        #expect(proposal?.samples.count == 3)
        #expect(proposal?.samples.first?.question == "What is topic 0 in FSRS?")
    }

    // MARK: - Run

    @Test func qualifyingTaskBecomesAProposalAndADeclineIsRemembered() async throws {
        let database = try ShifuDatabase.inMemory()
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", minutes: 90)
        try seedTask(database, key: "sem:expenses-review", name: "Expense review", minutes: 80)
        let backend = ScriptedBackend([worthResponse(title: "FSRS internals", cards: 2),
                                       #"{"worth": false}"#])

        #expect(try await DeckSuggester.run(database: database, backend: backend, now: now) == 1)
        #expect(backend.calls == 2)
        // The prompt carries the task's own evidence, not just its name.
        #expect(backend.prompts[0].contains("FSRS internals"))
        #expect(backend.prompts[0].contains("Learning FSRS internals"))       // gist
        #expect(backend.prompts[0].contains("Safari — reading about"))        // day line
        #expect(backend.prompts[0].contains("recall probability"))            // screen text

        let pending = try DeckStore.pendingSuggestions(database: database)
        #expect(pending.count == 1)
        #expect(pending[0].title == "FSRS internals")
        #expect(pending[0].samples.count == 2)

        // Both verdicts are on file, so a second run bills nothing at all.
        let second = ScriptedBackend([])
        #expect(try await DeckSuggester.run(database: database, backend: second, now: now) == 0)
        #expect(second.calls == 0)
    }

    /// The cap is on *calls*, not on accepted suggestions: the first weekly
    /// run against a mature ledger must not bill an open-ended row of probes.
    @Test func maxPerRunCapsModelCallsNotAcceptances() async throws {
        let database = try ShifuDatabase.inMemory()
        for index in 0..<5 {
            try seedTask(database, key: "sem:subject-\(index)", name: "Subject \(index)",
                         minutes: Int64(100 - index))
        }
        let backend = ScriptedBackend(Array(repeating: #"{"worth": false}"#, count: 5))

        #expect(try await DeckSuggester.run(database: database, backend: backend, now: now) == 0)
        #expect(backend.calls == DeckSuggester.maxPerRun)
        // The three it never reached are still candidates next week.
        #expect(try DeckSuggester.candidates(database: database, now: now).count == 3)
    }

    @Test func fullQueueShortCircuitsBeforeAnyCall() async throws {
        let database = try ShifuDatabase.inMemory()
        for index in 0..<4 {
            try seedTask(database, key: "sem:subject-\(index)", name: "Subject \(index)",
                         minutes: 90)
            if index < DeckSuggester.maxOpenSuggestions {
                try DeckStore.suggest(
                    taskKey: "sem:subject-\(index)", title: "Deck \(index)",
                    samples: [DeckStore.SampleCard(topic: "t", note: "n", question: "q",
                                                   answer: "a")],
                    database: database)
            }
        }
        let backend = ScriptedBackend([])
        #expect(try await DeckSuggester.run(database: database, backend: backend, now: now) == 0)
        #expect(backend.calls == 0)
    }
}

import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct StubBackend: LLMBackend {
    let name = "stub"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

/// Assigns every block in the prompt to one shared new task and records each
/// prompt, so tests can assert batching and cross-batch roster growth.
private final class GroupingBackend: LLMBackend, @unchecked Sendable {
    let name = "grouping"
    let contextWindowTokens: Int
    let responseHeadroomTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(contextWindowTokens: Int, responseHeadroomTokens: Int = 0) {
        self.contextWindowTokens = contextWindowTokens
        self.responseHeadroomTokens = responseHeadroomTokens
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        let ids = prompt.split(separator: "\n").compactMap { line in
            line.hasPrefix("id=") ? Int64(line.dropFirst(3).prefix(while: \.isNumber)) : nil
        }
        // Reuse the roster entry when the task already exists, else create it.
        let handle = prompt.contains(": Planning the SF trip") ? "t1" : "n1"
        let assignments = ids
            .map { #"{"id": \#($0), "task": "\#(handle)", "confidence": 0.9}"# }
            .joined(separator: ",")
        return #"{"assignments": [\#(assignments)], "new_tasks": [{"handle": "n1", "#
            + #""title": "Planning the SF trip", "gist": "Flights and lodging."}]}"#
    }
}

/// Sendable snapshot of a `tasks` row, so async reads can return it whole.
private struct TaskRowSnapshot: Sendable {
    var id: Int64
    var key: String
    var name: String
    var gist: String?
    var lastActiveAt: Int64
}

@Suite struct SemanticTaskGrouperTests {
    /// One activity with an observation carrying a title and text, so it
    /// qualifies as an evidence-bearing candidate.
    private func seedBlock(
        _ db: ShifuDatabase, id: inout [Int64], startedAt: Int64, minutes: Int64 = 10,
        bundle: String = "com.apple.Safari", domain: String? = nil,
        title: String? = "some window", text: String? = "some screen text"
    ) throws {
        try db.queue.write { sqlite in
            var activity = Activity(
                startedAt: startedAt, endedAt: startedAt + minutes * 60_000,
                appBundle: bundle, domain: domain, category: .unclassified)
            try activity.insert(sqlite)
            if title != nil || text != nil {
                try sqlite.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                    VALUES (?, ?, ?, ?, 'ax', ?, ?)
                    """, arguments: [startedAt, startedAt + minutes * 60_000, bundle,
                                     title, text, activity.id])
            }
            id.append(activity.id!)
        }
    }

    @Test func parsesVerdictWrappedInProse() {
        let verdict = SemanticTaskGrouper.parse("""
        Sure! Here is the grouping:
        ```json
        {"assignments": [{"id": 4, "task": "t1", "confidence": 0.8},
                         {"id": 5, "task": "n1", "confidence": 0.95}],
         "new_tasks": [{"handle": "n1", "title": "Booking flights", "gist": "Fares."},
                       {"handle": "n2", "title": "   "}]}
        ```
        """)
        #expect(verdict.assignments == [
            .init(id: 4, task: "t1", confidence: 0.8),
            .init(id: 5, task: "n1", confidence: 0.95)
        ])
        // The blank-titled task is dropped at parse time.
        #expect(verdict.newTasks == [.init(handle: "n1", title: "Booking flights", gist: "Fares.")])
    }

    /// The prompt's JSON example is a fill-in slot, not an answer. A model
    /// that echoes it must mint nothing: the first `sem:` task this project
    /// ever created was the old example's title *and* gist, verbatim, over
    /// unrelated evidence. An empty roster is the worst case, so this is a
    /// first-run bug — see `TaskGrouper.isPlaceholder`.
    @Test func echoedPromptPlaceholderMintsNothing() {
        let verdict = SemanticTaskGrouper.parse("""
        {"assignments": [{"id": 7, "task": "n1", "confidence": 0.99}],
         "new_tasks": [{"handle": "n1", "title": "<…>", "gist": "<…>"}]}
        """)
        // The slot survives parsing as a title (parse only drops blanks)…
        #expect(verdict.newTasks == [.init(handle: "n1", title: "<…>", gist: nil)])
        // …but slugs to nothing, so resolve mints no task and the confident
        // assignment pointing at it is dropped with it.
        let resolved = SemanticTaskGrouper.resolve(verdict, batch: [7], roster: [])
        #expect(resolved.newTaskByKey.isEmpty)
        #expect(resolved.assignmentsByKey.isEmpty)
    }

    /// Whatever the placeholder is, it must never survive `slug` — that is
    /// the property the guard above rests on.
    @Test func promptPlaceholdersAreUnsluggable() {
        let prompt = SemanticTaskGrouper.prompt(roster: [], blocks: [])
        #expect(prompt.contains(#""title": "<…>""#))
        #expect(TaskGrouper.isPlaceholder("<…>"))
        // And no prompt example is a usable task name any more.
        #expect(!prompt.contains("Booking flights for the SF trip"))
        #expect(!prompt.contains("Comparing fares and picking travel dates"))
    }

    @Test func parseToleratesGarbage() {
        #expect(SemanticTaskGrouper.parse("no json here") == .init(assignments: [], newTasks: []))
        #expect(SemanticTaskGrouper.parse("{}") == .init(assignments: [], newTasks: []))
    }

    @Test func promptListsRosterAndBlocks() {
        let roster = [SemanticTaskGrouper.RosterEntry(
            key: "sem:yc-afterparties", name: "Applying to YC afterparties",
            gist: "RSVPs around Startup School")]
        let blocks = [SemanticTaskGrouper.BlockSample(
            id: 12, startedAt: 0, endedAt: 21 * 60_000, appBundle: "com.apple.Safari",
            domain: "partiful.com", topic: nil, titles: ["RSVP — YC Afterparty"],
            textSample: "You're invited")]
        let prompt = SemanticTaskGrouper.prompt(roster: roster, blocks: blocks)
        #expect(prompt.contains("t1: Applying to YC afterparties — RSVPs around Startup School"))
        #expect(prompt.contains("id=12"))
        #expect(prompt.contains("domain=partiful.com"))
        #expect(prompt.contains("titles=RSVP — YC Afterparty"))
        #expect(prompt.contains("text: You're invited"))
        #expect(SemanticTaskGrouper.prompt(roster: [], blocks: blocks).contains("(none yet)"))
    }

    @Test func runCreatesTaskAndGroupsBlocksUnderIt() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0, domain: "partiful.com",
                      title: "RSVP — YC Afterparty")
        try seedBlock(db, id: &ids, startedAt: 3_600_000, domain: "lu.ma",
                      title: "AI founders afterparty — lu.ma")
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "n1", "confidence": 0.9},
                             {"id": \#(ids[1]), "task": "n1", "confidence": 0.85}],
             "new_tasks": [{"handle": "n1", "title": "Applying to YC afterparties",
                            "gist": "RSVPs and applications around Startup School."}]}
            """#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 2, tasksCreated: 1))

        try TaskGrouper.run(database: db, from: 0, to: 10_000_000)
        let task = try await db.queue.read { sqlite -> TaskRowSnapshot? in
            guard let row = try Row.fetchOne(sqlite, sql: """
                SELECT id, key, name, gist, last_active_at FROM tasks
                """) else { return nil }
            return TaskRowSnapshot(id: row["id"], key: row["key"], name: row["name"],
                                   gist: row["gist"], lastActiveAt: row["last_active_at"])
        }
        #expect(task?.key == "sem:applying-to-yc-afterparties")
        #expect(task?.name == "Applying to YC afterparties")
        #expect(task?.gist == "RSVPs and applications around Startup School.")
        let taskIDs = try await db.queue.read { sqlite in
            try Int64.fetchAll(sqlite, sql: "SELECT DISTINCT task_id FROM activities")
        }
        #expect(taskIDs == [task?.id])
    }

    @Test func assignmentToRosterTaskJoinsWithoutRenaming() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (key, name, gist, created_at, last_active_at)
                VALUES ('sem:sf-trip', 'My renamed trip task', 'Old gist.', 0, 5)
                """)
        }
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 1_000_000, domain: "united.com",
                      title: "SFO flights — United")
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "t1", "confidence": 0.9}],
             "new_tasks": []}
            """#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000,
            now: Date(timeIntervalSince1970: 10_000))
        #expect(summary == .init(assigned: 1, tasksCreated: 0))

        let task = try await db.queue.read { sqlite -> TaskRowSnapshot? in
            guard let row = try Row.fetchOne(sqlite, sql: """
                SELECT id, key, name, gist, last_active_at FROM tasks
                """) else { return nil }
            return TaskRowSnapshot(id: row["id"], key: row["key"], name: row["name"],
                                   gist: row["gist"], lastActiveAt: row["last_active_at"])
        }
        #expect(task?.name == "My renamed trip task")     // renames stick
        #expect(task?.gist == "Old gist.")
        #expect(task?.lastActiveAt == 1_600_000)          // the block's end time
        let semKey = try await db.queue.read { sqlite in
            try String.fetchOne(sqlite, sql: "SELECT sem_key FROM activities")
        }
        #expect(semKey == "sem:sf-trip")
    }

    @Test func lowConfidenceUnknownHandleAndForeignIDBurnAttempts() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0)
        try seedBlock(db, id: &ids, startedAt: 3_600_000)
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "n1", "confidence": 0.3},
                             {"id": \#(ids[1]), "task": "t7", "confidence": 0.9},
                             {"id": 9999, "task": "n1", "confidence": 0.9}],
             "new_tasks": [{"handle": "n1", "title": "Some task", "gist": null}]}
            """#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 0, tasksCreated: 0))

        let rows = try await db.queue.read { sqlite -> [(String?, Int)] in
            try Row.fetchAll(sqlite, sql: "SELECT sem_key, sem_attempts FROM activities")
                .map { ($0["sem_key"], $0["sem_attempts"]) }
        }
        for row in rows {
            #expect(row.0 == nil)
            #expect(row.1 == 1)
        }
        // The declared-but-unreferenced new task creates no row.
        let taskCount = try await db.queue.read { sqlite in
            try Int.fetchOne(sqlite, sql: "SELECT COUNT(*) FROM tasks")
        }
        #expect(taskCount == 0)
    }

    @Test func unplacedBlockStopsBillingAfterMaxAttempts() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0)
        final class CountingBackend: LLMBackend, @unchecked Sendable {
            let name = "counting"
            private let lock = NSLock()
            private(set) var calls = 0
            func complete(prompt: String, maxTokens: Int) async throws -> String {
                lock.withLock { calls += 1 }
                return #"{"assignments": [], "new_tasks": []}"#
            }
        }
        let backend = CountingBackend()
        for _ in 0..<(SemanticTaskGrouper.maxAttempts + 2) {
            _ = try await SemanticTaskGrouper.run(
                database: db, backend: backend, from: 0, to: 10_000_000)
        }
        #expect(backend.calls == SemanticTaskGrouper.maxAttempts)
    }

    @Test func shortAndEvidencelessBlocksAreNeverSent() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        // 30-second block: too short. Meta-only block: no titles, text, or topic.
        try seedBlock(db, id: &ids, startedAt: 0, minutes: 0)
        try seedBlock(db, id: &ids, startedAt: 3_600_000, title: nil, text: nil)
        let shortID = ids[0]
        try await db.queue.write { sqlite in
            try sqlite.execute(
                sql: "UPDATE activities SET ended_at = started_at + 30000 WHERE id = ?",
                arguments: [shortID])
        }
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 10_000_000)
        #expect(samples.isEmpty)
    }

    // System shells used to need a clause in `pendingSamples`, and this suite
    // asserted it. They can't reach the candidate sweep at all now — the
    // ledger holds no block for one — so the guarantee lives at the write
    // boundary, in `SystemBundleDenylistTests`.

    @Test func privateAndAlreadyAssignedBlocksAreNeverSent() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0)
        try seedBlock(db, id: &ids, startedAt: 3_600_000)
        let (privateID, assignedID) = (ids[0], ids[1])
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET category = 'private' WHERE id = ?",
                               arguments: [privateID])
            try sqlite.execute(sql: "UPDATE activities SET sem_key = 'sem:done' WHERE id = ?",
                               arguments: [assignedID])
        }
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 10_000_000)
        #expect(samples.isEmpty)
    }

    @Test func runSplitsBatchesAndGrowsRosterAcrossThem() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<8 {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 3_600_000,
                          title: "window \(index)",
                          text: String(repeating: "dense screen text ", count: 30))
        }
        let backend = GroupingBackend(contextWindowTokens: 2_600)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 100_000_000)
        #expect(backend.prompts.count > 1)
        for prompt in backend.prompts {
            #expect(LLMTokens.estimate(prompt)
                <= 2_600 - SemanticTaskGrouper.responseTokenReserve)
        }
        // The task created by batch 1 is offered (and reused) in batch 2.
        #expect(backend.prompts.last!.contains("t1: Planning the SF trip — Flights and lodging."))
        #expect(summary == .init(assigned: 8, tasksCreated: 1))
        let distinctKeys = try await db.queue.read { sqlite in
            try String.fetchAll(sqlite, sql: "SELECT DISTINCT sem_key FROM activities")
        }
        #expect(distinctKeys == ["sem:planning-the-sf-trip"])
    }

    /// A thinking backend's headroom outranks the stage's answer reserve when
    /// sizing batches: prompts must leave the whole headroom free, or the
    /// model burns the remainder on chain-of-thought and answers nothing.
    @Test func runReservesThinkingHeadroomWhenSizingBatches() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<8 {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 3_600_000,
                          title: "window \(index)",
                          text: String(repeating: "dense screen text ", count: 30))
        }
        let headroom = SemanticTaskGrouper.responseTokenReserve + 600
        let backend = GroupingBackend(contextWindowTokens: 3_200,
                                      responseHeadroomTokens: headroom)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 100_000_000)
        #expect(summary.assigned == 8)
        #expect(backend.prompts.count > 1)
        for prompt in backend.prompts {
            #expect(LLMTokens.estimate(prompt) <= 3_200 - headroom)
        }
    }

    @Test func humanizeStripsPrefixAndDashes() {
        #expect(SemanticTaskGrouper.humanize(key: "sem:booking-sf-flights") == "booking sf flights")
        #expect(SemanticTaskGrouper.humanize(key: "domain:united.com") == "domain:united.com")
    }

    @Test func taskGrouperPrefersSemKeyOverMechanicalKey() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            // Two different domains, one semantic task; a third block unassigned.
            var one = Activity(startedAt: 0, endedAt: 600_000,
                               appBundle: "com.apple.Safari", domain: "united.com",
                               category: .admin)
            var two = Activity(startedAt: 700_000, endedAt: 1_300_000,
                               appBundle: "com.apple.Safari", domain: "airbnb.com",
                               category: .admin)
            var three = Activity(startedAt: 1_400_000, endedAt: 2_000_000,
                                 appBundle: "com.apple.Safari", domain: "news.ycombinator.com",
                                 category: .entertainment)
            try one.insert(sqlite); try two.insert(sqlite); try three.insert(sqlite)
            try sqlite.execute(sql: """
                UPDATE activities SET sem_key = 'sem:planning-the-sf-trip' WHERE id IN (?, ?)
                """, arguments: [one.id, two.id])
        }
        try TaskGrouper.run(database: db, from: 0, to: 10_000_000)
        let tasks = try await db.queue.read { sqlite -> [(String, String)] in
            try Row.fetchAll(sqlite, sql: "SELECT key, name FROM tasks ORDER BY key")
                .map { ($0["key"], $0["name"]) }
        }
        #expect(tasks.count == 2)
        #expect(tasks[0].0 == "domain:news.ycombinator.com")
        // No pre-created row (semantic pass skipped): humanized fallback name.
        #expect(tasks[1].0 == "sem:planning-the-sf-trip")
        #expect(tasks[1].1 == "planning the sf trip")
    }
}

// Extension keeps the suite's type body inside the lint budget.
extension SemanticTaskGrouperTests {
    /// The backend's window decides the roster tier at exactly
    /// `fullRosterMinContextTokens`: a sub-16k backend (the local profile)
    /// gets compact roster lines — names and gists only — while 16k and up
    /// keeps the history facts the prior weighting rests on.
    @Test func sub16kWindowsGetTheCompactRoster() async throws {
        let nowMs: Int64 = 1_000_000_000_000
        let day: Int64 = 86_400_000
        for (window, expectFacts) in [(12_000, false), (16_000, true)] {
            let db = try ShifuDatabase.inMemory()
            try await db.queue.write { sqlite in
                try sqlite.execute(sql: """
                    INSERT INTO tasks (id, key, name, created_at, last_active_at)
                    VALUES (1, 'sem:sf-trip', 'Planning the SF trip', ?, ?)
                    """, arguments: [nowMs - 5 * day, nowMs - 2 * day])
                try sqlite.execute(sql: """
                    INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                    VALUES (1, ?, 3600000, 'united.com — flights')
                    """, arguments: [nowMs - 2 * day])
            }
            var ids: [Int64] = []
            try seedBlock(db, id: &ids, startedAt: nowMs - 3_600_000)
            let backend = GroupingBackend(contextWindowTokens: window)
            _ = try await SemanticTaskGrouper.run(
                database: db, backend: backend, from: nowMs - day, to: nowMs,
                now: Date(timeIntervalSince1970: Double(nowMs) / 1_000))
            let prompt = try #require(backend.prompts.first)
            #expect(prompt.contains("t1: Planning the SF trip"))
            #expect(prompt.contains("60m over 1d") == expectFacts, "window \(window)")
        }
    }

    /// Even under a huge token budget, one call carries at most
    /// `batchBlockLimit` blocks: replaying a real 60-block prompt showed the
    /// model's verdicts destabilize with long runs of same-shaped assignment
    /// lines (identical replays agreed on as little as 26% of assignments,
    /// or collapsed onto a single task), while 24-block batches stabilized
    /// them — see the constant.
    @Test func batchesCapAtTheBlockLimitEvenInsideTheTokenBudget() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<(SemanticTaskGrouper.batchBlockLimit + 6) {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 3_600_000)
        }
        let backend = GroupingBackend(contextWindowTokens: 100_000)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 1_000_000_000)
        #expect(summary.assigned == SemanticTaskGrouper.batchBlockLimit + 6)
        let sizes = backend.prompts.map { prompt in
            prompt.components(separatedBy: "\nid=").count - 1
        }
        #expect(sizes == [SemanticTaskGrouper.batchBlockLimit, 6])
    }

    /// A block whose `ended_at` is within a sessionizer gap of `to` may still
    /// be growing — its verdict would be discarded by the next rebuild when
    /// the span moves, so it must not be bought at all.
    @Test func blocksStillInsideTheSessionGapAreNeverSent() throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0)
        // Ends exactly at `to` — the shape of a block the user is still in.
        try seedBlock(db, id: &ids, startedAt: 9_400_000)
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 10_000_000)
        #expect(samples.map(\.id) == [ids[0]])
    }

    /// Minting is held to a higher floor than joining: a wrong join is one
    /// mislabeled block, a wrong mint is a roster entry every later batch is
    /// invited to reuse — and the hourly pass runs on the fast slot now.
    @Test func mintingATaskNeedsMoreConfidenceThanJoiningOne() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0)
        try seedBlock(db, id: &ids, startedAt: 3_600_000)
        try await db.queue.write { sqlite in
            // Active now, so the roster window includes it.
            try sqlite.execute(sql: """
                INSERT INTO tasks (key, name, created_at, last_active_at)
                VALUES ('sem:sf-trip', 'Planning the SF trip', 0, ?)
                """, arguments: [Int64(Date().timeIntervalSince1970 * 1_000)])
        }
        // 0.65 clears the join floor (0.6) but not the mint floor (0.75).
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "t1", "confidence": 0.65},
                             {"id": \#(ids[1]), "task": "n1", "confidence": 0.65}],
             "new_tasks": [{"handle": "n1", "title": "Something new", "gist": null}]}
            """#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 1, tasksCreated: 0))
        let assigned = try await db.queue.read { sqlite in
            try Row.fetchAll(sqlite, sql: "SELECT sem_key FROM activities ORDER BY started_at")
                .map { $0["sem_key"] as String? }
        }
        #expect(assigned == ["sem:sf-trip", nil])
    }
}

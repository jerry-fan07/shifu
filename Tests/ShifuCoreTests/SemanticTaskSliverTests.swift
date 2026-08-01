import Foundation
import GRDB
import Testing
@testable import ShifuCore

// Sub-minute placement — runs (SemanticTaskSlivers.swift) and neighbour
// inheritance (SemanticTaskInheritance.swift). The grouper pipeline's own
// suite lives in SemanticTaskGrouperTests.swift.

private struct StubBackend: LLMBackend {
    let name = "stub"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

/// One activity, optionally with an observation carrying a title and text so
/// it qualifies as an evidence-bearing candidate. Same shape as the grouper
/// suite's seeder.
private func seedBlock(
    _ db: ShifuDatabase, id: inout [Int64], startedAt: Int64, minutes: Int64 = 10,
    durationMs: Int64? = nil, bundle: String = "com.apple.Safari",
    title: String? = "some window", text: String? = "some screen text"
) throws {
    let endedAt = startedAt + (durationMs ?? minutes * 60_000)
    try db.queue.write { sqlite in
        var activity = Activity(
            startedAt: startedAt, endedAt: endedAt,
            appBundle: bundle, category: .unclassified)
        try activity.insert(sqlite)
        if title != nil || text != nil {
            try sqlite.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                VALUES (?, ?, ?, ?, 'ax', ?, ?)
                """, arguments: [startedAt, endedAt, bundle, title, text, activity.id])
        }
        id.append(activity.id!)
    }
}

@Suite struct SemanticTaskSliverTests {
    /// The quota regression: recency-ordered admission once bought 59
    /// slivers and 1 long block. Long blocks take slots first now, however
    /// many runs the window holds; runs fill the remainder by pooled time.
    @Test func longBlocksTakeCandidateSlotsBeforeSlivers() throws {
        let db = try ShifuDatabase.inMemory()
        var longIDs: [Int64] = []
        for index in 0..<3 {
            try seedBlock(db, id: &longIDs, startedAt: Int64(index) * 3_600_000)
        }
        // 200 newer slivers across four apps — four fat runs, all newer than
        // every long block.
        var sliverIDs: [Int64] = []
        for index in 0..<200 {
            try seedBlock(db, id: &sliverIDs,
                          startedAt: 11_000_000 + Int64(index) * 40_000,
                          durationMs: 30_000,
                          bundle: "com.hopper.app\(index % 4)", title: "Hopper")
        }
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 30_000_000, limit: 5)
        #expect(samples.count == 5)
        #expect(Set(longIDs).isSubset(of: Set(samples.map(\.id))))
        #expect(samples.filter { $0.memberIDs.count > 1 }.count == 2)
    }

    /// A run's evidence fans across all its members and still obeys one
    /// block's sampling budget — a 12-block run costs what one block costs.
    @Test func aRunsEvidenceStaysInsideOneBlocksBudget() throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<12 {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 120_000,
                          durationMs: 30_000, bundle: "com.conductor.app",
                          title: "workspace \(index)")
        }
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 10_000_000)
        let run = try #require(samples.first)
        #expect(run.titles.count <= SemanticTaskGrouper.sampleCount)
        // The spread reaches past the run's opening minutes: first and last
        // members are sampled, not five neighbours from the front.
        #expect(run.titles.first == "workspace 0")
        #expect(run.titles.last == "workspace 11")
    }

    @Test func assigningARunWritesEveryMemberBlock() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<3 {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 120_000,
                          durationMs: 30_000, bundle: "com.conductor.app",
                          title: "Conductor — shifu")
        }
        let backend = StubBackend(response: #"""
            {"assignments": [{"id": \#(ids[0]), "task": "n1", "confidence": 0.9}],
             "new_tasks": [{"handle": "n1", "title": "Shipping the tasks page",
                            "gist": "Runs and gates."}]}
            """#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 3, tasksCreated: 1))
        let keys = try await db.queue.read { sqlite in
            try String.fetchAll(sqlite, sql: "SELECT DISTINCT sem_key FROM activities")
        }
        #expect(keys == ["sem:shipping-the-tasks-page"])
    }

    @Test func decliningARunBurnsAnAttemptOnEveryMember() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        for index in 0..<3 {
            try seedBlock(db, id: &ids, startedAt: Int64(index) * 120_000,
                          durationMs: 30_000, bundle: "com.conductor.app",
                          title: "Conductor — shifu")
        }
        let backend = StubBackend(response: #"{"assignments": [], "new_tasks": []}"#)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 0, tasksCreated: 0, declined: 1))
        let attempts = try await db.queue.read { sqlite in
            try Int.fetchAll(sqlite, sql: "SELECT sem_attempts FROM activities")
        }
        #expect(attempts == [1, 1, 1])
    }

    /// The pure cut rule: 14 min of gap keeps a run together, 16 min cuts
    /// it; another app between two glances doesn't cut their run, but a
    /// different domain of the same app is a different bucket.
    @Test func runsAreCutOnAppDomainAndGap() {
        func sliver(
            _ id: Int64, at startedAt: Int64, app: String = "com.conductor.app",
            domain: String? = nil
        ) -> SemanticTaskGrouper.SliverRow {
            .init(id: id, startedAt: startedAt, endedAt: startedAt + 30_000,
                  appBundle: app, domain: domain, topic: nil)
        }
        let close = SemanticTaskGrouper.coalesce(
            [sliver(1, at: 0), sliver(2, at: 30_000 + 14 * 60_000)])
        #expect(close.map { $0.map(\.id) } == [[1, 2]])
        let far = SemanticTaskGrouper.coalesce(
            [sliver(1, at: 0), sliver(2, at: 30_000 + 16 * 60_000)])
        #expect(far.map { $0.map(\.id) } == [[1], [2]])
        let interleaved = SemanticTaskGrouper.coalesce([
            sliver(1, at: 0), sliver(2, at: 60_000, app: "com.apple.mail"),
            sliver(3, at: 120_000)
        ])
        #expect(interleaved.map { $0.map(\.id) } == [[1, 3], [2]])
        let domains = SemanticTaskGrouper.coalesce([
            sliver(1, at: 0, app: "com.apple.Safari", domain: "github.com"),
            sliver(2, at: 60_000, app: "com.apple.Safari", domain: "linear.app")
        ])
        #expect(domains.map { $0.map(\.id) } == [[1], [2]])
    }

    /// The prompt line for a run leads with what it is — glances and pooled
    /// minutes — not the wall-clock span it hopped across.
    @Test func promptRendersARunAsVisitsNotAsItsSpan() {
        let run = SemanticTaskGrouper.BlockSample(
            id: 7, startedAt: 0, endedAt: 41 * 60_000,
            appBundle: "com.conductor.app", domain: nil, topic: nil,
            titles: ["Conductor"], textSample: "",
            memberIDs: [7, 8, 9, 10, 11, 12, 13], activeMs: 3 * 60_000)
        let prompt = SemanticTaskGrouper.prompt(roster: [], blocks: [run])
        #expect(prompt.contains("id=7"))
        #expect(prompt.contains("7 visits · 3m over 41m"))
    }
}

// MARK: - Neighbour inheritance (design.md §5.3)

@Suite struct SemanticTaskInheritanceTests {
    /// Seeds A (10 min, sem-keyed), then slivers, then B (10 min, same key),
    /// spaced a minute apart so every gap is inside one sitting.
    private func seedSandwich(
        _ db: ShifuDatabase, key: String = "sem:writing-the-thesis",
        sliverCategory: ShifuCore.Category = .work
    ) throws -> [Int64] {
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0, title: nil, text: nil)
        try seedBlock(db, id: &ids, startedAt: 660_000, durationMs: 30_000,
                      bundle: "com.apple.mail", title: nil, text: nil)
        try seedBlock(db, id: &ids, startedAt: 720_000, durationMs: 30_000,
                      bundle: "com.apple.mail", title: nil, text: nil)
        try seedBlock(db, id: &ids, startedAt: 810_000, title: nil, text: nil)
        try db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET sem_key = ? WHERE id IN (?, ?)",
                               arguments: [key, ids[0], ids[3]])
            try sqlite.execute(sql: "UPDATE activities SET category = ? WHERE id IN (?, ?)",
                               arguments: [sliverCategory.rawValue, ids[1], ids[2]])
        }
        return ids
    }

    /// Both slivers between the two thesis blocks adopt the thesis — the
    /// nearest sem-keyed neighbours sandwich them, and other unplaced blocks
    /// in between don't break the sandwich. Re-running files nothing new.
    @Test func sandwichedSliverAdoptsItsNeighboursTask() throws {
        let db = try ShifuDatabase.inMemory()
        let ids = try seedSandwich(db)
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 2)
        let keys = try db.queue.read { sqlite in
            try Row.fetchAll(sqlite, sql: """
                SELECT id, sem_key FROM activities WHERE id IN (?, ?)
                """, arguments: [ids[1], ids[2]])
                .map { $0["sem_key"] as String? }
        }
        #expect(keys == ["sem:writing-the-thesis", "sem:writing-the-thesis"])
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 0)
    }

    /// A messaging glance inside a work stretch is a break from it, never a
    /// continuation — 18 of the 146 dogfood sandwiches were this shape,
    /// every one inside a `work` stretch.
    @Test func messagingInsideWorkIsABreakNotAContinuation() throws {
        let db = try ShifuDatabase.inMemory()
        _ = try seedSandwich(db, sliverCategory: .communication)
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 0)
    }

    /// Contiguity makes the sandwich mean "inside one sitting": a gap wider
    /// than the sessionizer's on either side breaks it, and neighbours
    /// wearing different keys were never a sandwich at all.
    @Test func neighboursSeparatedByAnIdleGapAreNotASandwich() throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, id: &ids, startedAt: 0, title: nil, text: nil)
        // 5 min after A ends: outside gapThresholdMs.
        try seedBlock(db, id: &ids, startedAt: 900_000, durationMs: 30_000,
                      bundle: "com.apple.mail", title: nil, text: nil)
        try seedBlock(db, id: &ids, startedAt: 990_000, title: nil, text: nil)
        try db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET sem_key = ? WHERE id IN (?, ?)",
                               arguments: ["sem:writing-the-thesis", ids[0], ids[2]])
        }
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 0)

        // Close the gap but split the keys: still no sandwich.
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                UPDATE activities SET started_at = 660000, ended_at = 690000 WHERE id = ?
                """, arguments: [ids[1]])
            try sqlite.execute(sql: """
                UPDATE activities
                SET sem_key = 'sem:other-work', started_at = 750000, ended_at = 1350000
                WHERE id = ?
                """, arguments: [ids[2]])
        }
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 0)
    }

    /// Only blocks nothing else will place inherit: a long unplaced block is
    /// the model's to judge, and a sliver whose attempts are exhausted was
    /// *declined* — inheriting it would back-door a verdict the model
    /// already refused, the same sentinel ThemeInheritance honours.
    @Test func inheritanceIsIdempotentAndSkipsExhausted() throws {
        let db = try ShifuDatabase.inMemory()
        let ids = try seedSandwich(db)
        try db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET sem_attempts = ? WHERE id = ?",
                               arguments: [SemanticTaskGrouper.maxAttempts, ids[1]])
            // A 2-min unplaced block in the same spot stays the model's.
            try sqlite.execute(sql: """
                UPDATE activities SET ended_at = started_at + 120000 WHERE id = ?
                """, arguments: [ids[2]])
        }
        #expect(try SemanticTaskGrouper.inheritFromNeighbors(
            database: db, from: 0, to: 10_000_000) == 0)
    }
}

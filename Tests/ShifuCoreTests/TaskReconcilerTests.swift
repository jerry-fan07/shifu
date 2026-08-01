import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The daily roster audit (`TaskReconciler`): the reasoning model's one
/// scheduled call. What matters here is the write path — proposals must ride
/// the existing suggestion queue's gates, never fold anything themselves.
@Suite struct TaskReconcilerTests {
    private func entry(_ key: String, _ name: String,
                       gist: String? = nil) -> SemanticTaskGrouper.RosterEntry {
        SemanticTaskGrouper.RosterEntry(key: key, name: name, gist: gist)
    }

    private func seedTasks(_ db: ShifuDatabase) throws {
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, gist, created_at, last_active_at)
                VALUES (1, 'sem:sf-trip', 'Planning the SF trip', 'Flights.', 0, 5),
                       (2, 'sem:sf-travel', 'SF travel', NULL, 0, 5),
                       (3, 'sem:thesis', 'Writing the thesis', NULL, 0, 5)
                """)
        }
    }

    @Test func promptListsTheRosterAndTheSchema() {
        let prompt = TaskReconciler.prompt(roster: [
            entry("sem:sf-trip", "Planning the SF trip", gist: "Flights."),
            entry("sem:thesis", "Writing the thesis")
        ])
        #expect(prompt.contains("t1: Planning the SF trip — Flights."))
        #expect(prompt.contains("t2: Writing the thesis"))
        #expect(prompt.contains(#""merges""#))
        #expect(prompt.contains(#""gists""#))
    }

    @Test func parseDropsSelfPairsAndEmptyGists() {
        let verdict = TaskReconciler.parse("""
        Sure — here's my review:
        ```json
        {"merges": [{"a": "t1", "b": "t2", "confidence": 0.9},
                    {"a": "t3", "b": "t3", "confidence": 0.99},
                    {"a": "t1", "confidence": 0.9}],
         "gists": [{"task": "t2", "gist": "  "},
                   {"task": "t3", "gist": "Drafting chapter three."}]}
        ```
        """)
        #expect(verdict.merges == [.init(handleA: "t1", handleB: "t2", confidence: 0.9)])
        #expect(verdict.gists == ["t3": "Drafting chapter three."])
    }

    @Test func mergeProposalsJoinTheQueueOrderedAndCapped() throws {
        let db = try ShifuDatabase.inMemory()
        try seedTasks(db)
        let roster = [entry("sem:sf-trip", "Planning the SF trip"),
                      entry("sem:sf-travel", "SF travel"),
                      entry("sem:thesis", "Writing the thesis")]
        let summary = try TaskReconciler.apply(
            .init(merges: [
                // Given b-before-a to prove the stored pair is id-ordered.
                .init(handleA: "t2", handleB: "t1", confidence: 0.99),
                .init(handleA: "t3", handleB: "t9", confidence: 0.9),   // unknown handle
                .init(handleA: "t1", handleB: "t3", confidence: 0.5)    // under the floor
            ]),
            roster: roster, database: db)
        #expect(summary == .init(mergesSuggested: 1, gistsFilled: 0))

        let row = try db.queue.read {
            try Row.fetchOne(
                $0, sql: "SELECT task_a, task_b, cosine, source FROM task_merge_suggestions")
        }
        #expect(row?["task_a"] == Int64(1))
        #expect(row?["task_b"] == Int64(2))
        // The score is stored raw and stamped with its scale (v27). It used to
        // be capped below the embedding auto-merge bar, which is why nothing
        // this stage proposed ever folded; `source` is what separates them now.
        #expect(row?["cosine"] == 0.99)
        #expect(row?["source"] == "reconcile")
    }

    @Test func aDismissedPairStaysDismissed() throws {
        let db = try ShifuDatabase.inMemory()
        try seedTasks(db)
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO task_merge_suggestions (task_a, task_b, cosine, status, created_at)
                VALUES (1, 2, 0.9, 'dismissed', 0)
                """)
        }
        let summary = try TaskReconciler.apply(
            .init(merges: [.init(handleA: "t1", handleB: "t2", confidence: 0.95)]),
            roster: [entry("sem:sf-trip", "A"), entry("sem:sf-travel", "B")],
            database: db)
        #expect(summary.mergesSuggested == 0)
        let status = try db.queue.read {
            try String.fetchOne($0, sql: "SELECT status FROM task_merge_suggestions")
        }
        #expect(status == "dismissed")
    }

    @Test func gistsFillOnlyTasksThatHaveNone() throws {
        let db = try ShifuDatabase.inMemory()
        try seedTasks(db)
        let summary = try TaskReconciler.apply(
            .init(gists: ["t1": "Overwritten?", "t2": "Booking the SF flights."]),
            roster: [entry("sem:sf-trip", "A", gist: "Flights."),
                     entry("sem:sf-travel", "B")],
            database: db)
        #expect(summary == .init(mergesSuggested: 0, gistsFilled: 1))
        let gists = try db.queue.read {
            try Row.fetchAll($0, sql: "SELECT id, gist FROM tasks ORDER BY id")
                .map { $0["gist"] as String? }
        }
        #expect(gists == ["Flights.", "Booking the SF flights.", nil])
    }

    @Test func aRosterOfOneMakesNoCall() async throws {
        let db = try ShifuDatabase.inMemory()
        final class TrappedBackend: LLMBackend, @unchecked Sendable {
            let name = "trapped"
            func complete(prompt: String, maxTokens: Int) async throws -> String {
                Issue.record("a lone task earned an LLM call")
                return "{}"
            }
        }
        // No tasks at all, then one task — neither is worth a daily audit.
        #expect(try await TaskReconciler.run(database: db, backend: TrappedBackend()) == .init())
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (key, name, created_at, last_active_at)
                VALUES ('sem:only', 'Only task', 0, ?)
                """, arguments: [Int64(Date().timeIntervalSince1970 * 1_000)])
        }
        #expect(try await TaskReconciler.run(database: db, backend: TrappedBackend()) == .init())
    }
}

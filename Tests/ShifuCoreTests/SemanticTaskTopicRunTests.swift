import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Topic runs (SemanticTaskSlivers.swift): consecutive carded blocks in one
/// app and domain whose cards name the same topic reach the model as one
/// candidate, and its verdict — or its decline — lands on every member.
@Suite struct SemanticTaskTopicRunTests {
    private let minute: Int64 = 60_000

    private func card(_ topic: String, gist: String = "working") -> String {
        BlockCard(category: .work, topic: topic, entities: [], gist: gist).json!
    }

    private func sample(
        _ id: Int64, at start: Int64, minutes: Int64, topic: String?,
        app: String = "com.apple.dt.Xcode", domain: String? = nil, gist: String = "working"
    ) -> SemanticTaskGrouper.BlockSample {
        SemanticTaskGrouper.BlockSample(
            id: id, startedAt: start, endedAt: start + minutes * minute,
            appBundle: app, domain: domain, topic: nil,
            card: topic.map { card($0, gist: gist) }, titles: [], textSample: "")
    }

    @Test func consecutiveBlocksOfOneTopicPoolIntoOneCandidate() {
        let pooled = SemanticTaskGrouper.poolByTopic([
            sample(1, at: 0, minutes: 5, topic: "debugging capture daemon"),
            // Other apps may sit between; the run goes on across them.
            sample(2, at: 6 * minute, minutes: 2, topic: "replying to Sam", app: "com.apple.MobileSMS"),
            // Case and punctuation are not wording: this is the same topic.
            sample(3, at: 12 * minute, minutes: 20, topic: "Debugging capture-daemon",
                   gist: "stepping through AX teardown"),
            sample(4, at: 40 * minute, minutes: 3, topic: "debugging capture daemon")
        ])
        #expect(pooled.count == 2)
        let run = pooled.first { $0.memberIDs.count > 1 }
        #expect(run?.id == 1)
        #expect(run?.memberIDs == [1, 3, 4])
        #expect(run?.activeMs == 28 * minute)
        #expect(run?.startedAt == 0)
        #expect(run?.endedAt == 43 * minute)
        // The longest member's card speaks for the run.
        #expect(BlockCard.parse(run?.card)?.gist == "stepping through AX teardown")
    }

    @Test func runsAreCutOnTopicSourceAndGap() {
        let pooled = SemanticTaskGrouper.poolByTopic([
            sample(1, at: 0, minutes: 5, topic: "debugging capture daemon"),
            // Same topic, other app: another run.
            sample(2, at: 6 * minute, minutes: 5, topic: "debugging capture daemon",
                   app: "com.google.Chrome", domain: "github.com"),
            // Same app, other topic: another run.
            sample(3, at: 12 * minute, minutes: 5, topic: "planning the release"),
            // Same app and topic as 1, but past the gap: another run.
            sample(4, at: 5 * minute + SemanticTaskGrouper.topicRunGapMs + minute,
                   minutes: 5, topic: "debugging capture daemon"),
            // No card, no topic to pool on: alone.
            sample(5, at: 70 * minute, minutes: 5, topic: nil),
            sample(6, at: 76 * minute, minutes: 5, topic: nil)
        ])
        #expect(pooled.count == 6)
        #expect(pooled.allSatisfy { $0.memberIDs.count == 1 })
    }

    /// End to end: the run is one line to the model, and one answer files
    /// every member.
    @Test func assigningATopicRunFilesEveryMember() async throws {
        let db = try ShifuDatabase.inMemory()
        let ids = try await db.queue.write { sqlite -> [Int64] in
            var inserted: [Int64] = []
            for (index, start) in [Int64(0), 10 * minute, 25 * minute].enumerated() {
                var activity = Activity(
                    startedAt: start, endedAt: start + 5 * minute,
                    appBundle: "com.apple.dt.Xcode", category: .work)
                try activity.insert(sqlite)
                try sqlite.execute(sql: "UPDATE activities SET card = ? WHERE id = ?",
                                   arguments: [card("debugging capture daemon",
                                                    gist: "step \(index)"), activity.id])
                inserted.append(activity.id!)
            }
            return inserted
        }
        let samples = try SemanticTaskGrouper.pendingSamples(
            database: db, from: 0, to: 100 * minute)
        #expect(samples.count == 1)
        #expect(samples.first?.memberIDs == ids)

        struct Stub: LLMBackend {
            let name = "stub"
            let response: String
            func complete(prompt: String, maxTokens: Int) async throws -> String { response }
        }
        let backend = Stub(response: """
            {"assignments": [{"id": \(ids[0]), "task": "n1", "confidence": 0.9}],
             "new_tasks": [{"handle": "n1", "title": "Debugging the capture daemon",
                            "gist": "Fixing observer teardown."}]}
            """)
        let summary = try await SemanticTaskGrouper.run(
            database: db, backend: backend, from: 0, to: 100 * minute)
        #expect(summary.assigned == 3)
        let keys = try await db.queue.read { sqlite in
            try String.fetchAll(sqlite, sql: "SELECT sem_key FROM activities ORDER BY id")
        }
        #expect(keys == Array(repeating: "sem:debugging-the-capture-daemon", count: 3))
    }
}

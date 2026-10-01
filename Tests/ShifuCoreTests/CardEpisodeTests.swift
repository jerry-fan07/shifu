import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Card episodes (`CardBuilder.episodes`): one window, reopened inside a
/// quarter hour, is one thing being done — carded once, the card written to
/// every block of it.
@Suite struct CardEpisodeTests {
    private let minute: Int64 = 60_000

    private func block(
        _ id: Int64, at start: Int64, minutes: Int64 = 3, app: String = "com.google.Chrome",
        domain: String? = "github.com", title: String? = "Pull request #12 · org/shifu"
    ) -> CardBuilder.PendingBlock {
        CardBuilder.PendingBlock(
            id: id, startedAt: start, endedAt: start + minutes * minute, appBundle: app,
            domain: domain, ambiguous: false, firstTitle: title)
    }

    @Test func oneWindowReopenedInsideAQuarterHourIsOneEpisode() {
        let episodes = CardBuilder.episodes([
            block(1, at: 0),
            // Another window between the two visits doesn't end the episode.
            block(2, at: 4 * minute, app: "com.apple.MobileSMS", domain: nil, title: "Sam"),
            block(3, at: 10 * minute),
            block(4, at: 20 * minute)
        ])
        #expect(episodes.map { $0.map(\.id) } == [[1, 3, 4], [2]])
    }

    @Test func episodesAreCutOnWindowAndGap() {
        let episodes = CardBuilder.episodes([
            block(1, at: 0),
            // Same app and site, another page title: another question.
            block(2, at: 4 * minute, title: "Issues · org/shifu"),
            // The first window again, but past the gap.
            block(3, at: 3 * minute + CardBuilder.episodeGapMs + minute),
            // No title: nothing to say it is the same thing, so it stands alone.
            block(4, at: 40 * minute, title: nil),
            block(5, at: 42 * minute, title: nil)
        ])
        #expect(episodes.allSatisfy { $0.count == 1 })
        #expect(episodes.count == 5)
    }

    /// End to end: three blocks of one window are one line in the prompt, and
    /// one card lands on all three — relabeling the ambiguous one as a fresh
    /// card would. A block no card came back for burns an attempt, members
    /// and all.
    @Test func oneCardIsWrittenToEveryBlockOfItsEpisode() async throws {
        let db = try ShifuDatabase.inMemory()
        let ids = try await db.queue.write { sqlite -> [Int64] in
            var inserted: [Int64] = []
            for (index, start) in [Int64(0), 6 * minute, 12 * minute, 60 * minute].enumerated() {
                var activity = Activity(
                    startedAt: start, endedAt: start + 3 * minute,
                    appBundle: "com.google.Chrome", domain: "youtube.com",
                    category: .entertainment, ambiguous: index == 1)
                try activity.insert(sqlite)
                // The last block is another video: its own episode.
                let title = index == 3 ? "Some other video" : "SwiftUI layout deep dive"
                try sqlite.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                    VALUES (?, ?, 'com.google.Chrome', ?, 'ax', 'transcript', ?)
                    """, arguments: [start, start + 3 * minute, title, activity.id])
                inserted.append(activity.id!)
            }
            return inserted
        }
        let samples = try CardBuilder.pendingSamples(database: db, from: 0, to: 200 * minute)
        #expect(samples.count == 2)
        #expect(samples.first { $0.memberIDs.count > 1 }?.memberIDs == Array(ids.prefix(3)))

        struct Stub: LLMBackend {
            let name = "stub"
            let response: String
            func complete(prompt: String, maxTokens: Int) async throws -> String { response }
        }
        // Answers for the episode's handle only; the lone block gets nothing.
        let backend = Stub(response: """
            [{"id": \(ids[0]), "cat": "learning", "conf": 0.9, "topic": "learning swiftui layout",
              "entities": [], "gist": "watching a SwiftUI layout talk"}]
            """)
        let summary = try await CardBuilder.run(
            database: db, backend: backend, from: 0, to: 200 * minute)
        #expect(summary.built == 3)
        #expect(summary.relabeled == 1)

        let rows = try await db.queue.read { sqlite in
            try Row.fetchAll(sqlite, sql: """
                SELECT card IS NOT NULL AS carded, category, card_attempts
                FROM activities ORDER BY id
                """)
        }
        #expect(rows.map { $0["carded"] as Bool } == [true, true, true, false])
        // Only the ambiguous block takes the card's category.
        #expect(rows.map { $0["category"] as String }
            == ["entertainment", "learning", "entertainment", "entertainment"])
        #expect(rows.map { $0["card_attempts"] as Int } == [0, 0, 0, 1])
    }
}

import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct StubBackend: LLMBackend {
    let name = "stub"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

/// Themes are the user's, not the model's (design.md §5.3, migration v17):
/// the clusterer files blocks into themes that exist and *proposes* the rest.
@Suite struct ThemeProposalsTests {
    private func seedBlock(
        _ db: ShifuDatabase, ids: inout [Int64], startedAt: Int64, minutes: Int64 = 15,
        domain: String? = nil
    ) throws {
        try db.queue.write { sqlite in
            var activity = Activity(
                startedAt: startedAt, endedAt: startedAt + minutes * 60_000,
                appBundle: "com.apple.Safari", domain: domain, category: .unclassified)
            try activity.insert(sqlite)
            ids.append(activity.id!)
        }
    }

    /// A theme the model invents is a suggestion, never a row in the Themes
    /// grid, and its blocks stay unfiled until the user says yes.
    @Test func runProposesNewThemeInsteadOfCreatingIt() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0, minutes: 20, domain: "partiful.com")
        try seedBlock(db, ids: &ids, startedAt: 3_600_000, minutes: 40,
                      domain: "startupschool.org")
        let summary = try await ThemeClusterer.run(
            database: db, backend: StubBackend(response: ycVerdict(ids)),
            from: 0, to: 10_000_000)
        #expect(summary == .init(assigned: 0, themesProposed: 1))

        let counts = try await db.queue.read { sqlite -> (Int, Int) in
            (try Int.fetchOne(sqlite, sql: "SELECT COUNT(*) FROM themes") ?? -1,
             try Int.fetchOne(sqlite, sql: """
                SELECT COUNT(*) FROM activities WHERE theme_key IS NOT NULL
                """) ?? -1)
        }
        #expect(counts.0 == 0)      // no theme row
        #expect(counts.1 == 0)      // nothing filed

        // Placed-but-pending blocks burn an attempt: the model has answered,
        // and re-asking hourly would pay for the same verdict again.
        let attempts = try await db.queue.read { sqlite in
            try Int.fetchAll(sqlite, sql: "SELECT theme_attempts FROM activities")
        }
        #expect(attempts == [1, 1])

        let pending = try ThemeProposals.pending(database: db)
        #expect(pending.count == 1)
        #expect(pending[0].key == "thm:yc-startup-school")
        #expect(pending[0].name == "YC Startup School")
        #expect(pending[0].gist == "The program and everything around it.")
        #expect(pending[0].blockCount == 2)
        #expect(pending[0].totalMs == 60 * 60_000)
    }

    @Test func acceptingProposalMintsThemeAndFilesItsBlocks() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0, domain: "partiful.com")
        try seedBlock(db, ids: &ids, startedAt: 3_600_000, domain: "startupschool.org")
        _ = try await ThemeClusterer.run(
            database: db, backend: StubBackend(response: ycVerdict(ids)),
            from: 0, to: 10_000_000)

        let proposal = try #require(try ThemeProposals.pending(database: db).first)
        #expect(try ThemeProposals.accept(proposal, database: db) == "thm:yc-startup-school")

        let theme = try #require(try ThemeStore.overviews(database: db).first)
        #expect(theme.key == "thm:yc-startup-school")
        #expect(theme.name == "YC Startup School")
        #expect(theme.gist == "The program and everything around it.")
        let keys = try await db.queue.read { sqlite in
            try String.fetchAll(sqlite, sql: "SELECT DISTINCT theme_key FROM activities")
        }
        #expect(keys == ["thm:yc-startup-school"])
        #expect(try ThemeProposals.pending(database: db).isEmpty)   // answered
    }

    /// A dismissal is permanent — the unique key means the same initiative
    /// can't come back a run later wearing the same name.
    @Test func dismissedProposalIsNeverSuggestedAgain() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0, domain: "partiful.com")
        _ = try await ThemeClusterer.run(
            database: db, backend: StubBackend(response: ycVerdict(ids)),
            from: 0, to: 10_000_000)
        let proposal = try #require(try ThemeProposals.pending(database: db).first)
        try ThemeProposals.dismiss(proposalID: proposal.id, database: db)

        var more: [Int64] = []
        try seedBlock(db, ids: &more, startedAt: 7_200_000, domain: "startupschool.org")
        let summary = try await ThemeClusterer.run(
            database: db, backend: StubBackend(response: ycVerdict(more)),
            from: 0, to: 10_000_000)
        #expect(summary.themesProposed == 0)
        #expect(try ThemeProposals.pending(database: db).isEmpty)
    }

    /// Creating the theme by hand answers the question the suggestion asked.
    @Test func creatingThemeByHandClearsItsProposal() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0, domain: "partiful.com")
        _ = try await ThemeClusterer.run(
            database: db, backend: StubBackend(response: ycVerdict(ids)),
            from: 0, to: 10_000_000)
        #expect(try ThemeProposals.pending(database: db).count == 1)

        #expect(try ThemeStore.create(named: "YC Startup School", database: db)
            == "thm:yc-startup-school")
        #expect(try ThemeProposals.pending(database: db).isEmpty)
    }

    @Test func deletingThemeUnfilesItsBlocksAndRulesTheKeyOut() async throws {
        let db = try ShifuDatabase.inMemory()
        var ids: [Int64] = []
        try seedBlock(db, ids: &ids, startedAt: 0, minutes: 30, domain: "united.com")
        let key = try #require(try ThemeStore.create(named: "Travel", database: db))
        #expect(key == "thm:travel")
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: "UPDATE activities SET theme_key = ?, theme_user_set = 1",
                               arguments: [key])
        }

        let theme = try #require(try ThemeStore.overviews(database: db).first)
        try ThemeStore.delete(themeID: theme.id, database: db)
        #expect(try ThemeStore.overviews(database: db).isEmpty)

        // Unfiled, attempt-capped so the next run can't quietly re-file it,
        // hand-filed bit cleared — and its time untouched.
        let freed = try await db.queue.read { sqlite in
            try Int.fetchOne(sqlite, sql: """
                SELECT COUNT(*) FROM activities
                WHERE theme_key IS NULL AND theme_attempts = ? AND theme_user_set = 0
                  AND ended_at - started_at = ?
                """, arguments: [ThemeClusterer.maxAttempts, 30 * 60_000])
        }
        #expect(freed == 1)

        // And the model can't offer it straight back.
        let verdict = try #require(SemanticTaskGrouper.parse(#"""
            {"assignments": [{"id": \#(ids[0]), "task": "n1", "confidence": 0.9}],
             "new_themes": [{"handle": "n1", "title": "Travel", "gist": "Trips."}]}
            """#, newEntriesKey: "new_themes"))
        _ = try ThemeClusterer.apply(
            verdict,
            batch: [.init(id: ids[0], startedAt: 0, endedAt: 1_800_000,
                          appBundle: "com.apple.Safari", domain: "united.com",
                          topic: nil, taskName: nil, titles: [])],
            roster: [], database: db)
        #expect(try ThemeProposals.pending(database: db).isEmpty)
        #expect(try ThemeStore.overviews(database: db).isEmpty)
    }

    /// Every block in `ids` confidently placed in one invented theme.
    private func ycVerdict(_ ids: [Int64]) -> String {
        let assignments = ids
            .map { #"{"id": \#($0), "task": "n1", "confidence": 0.9}"# }
            .joined(separator: ", ")
        return #"""
            {"assignments": [\#(assignments)],
             "new_themes": [{"handle": "n1", "title": "YC Startup School",
                             "gist": "The program and everything around it."}]}
            """#
    }
}

import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The evidence half of semantic grouping (design.md §5.3): the weighted
/// roster, the stickiness context, and what one block's sampled evidence
/// actually contains.
@Suite struct SemanticTaskEvidenceTests {
    private typealias Grouper = SemanticTaskGrouper
    /// Fixed "now" (Sep 2001) so roster ages are exact, not clock-dependent.
    private static let nowMs: Int64 = 1_000_000_000_000
    private var now: Date { Date(timeIntervalSince1970: Double(Self.nowMs) / 1_000) }

    private func entry(
        _ name: String, key: String? = nil, minutes: Int = 0, daysActive: Int = 0,
        lastActiveDays: Int = 0, sources: [String] = []
    ) -> Grouper.RosterEntry {
        Grouper.RosterEntry(
            key: key ?? "sem:\(TaskGrouper.slug(name))", name: name, gist: nil,
            minutes: minutes, daysActive: daysActive, lastActiveDays: lastActiveDays,
            topSources: sources)
    }

    private func block(id: Int64 = 1, urls: [String] = []) -> Grouper.BlockSample {
        Grouper.BlockSample(
            id: id, startedAt: 0, endedAt: 20 * 60_000, appBundle: "com.apple.Safari",
            domain: "overleaf.com", topic: nil, titles: ["thesis.tex"], urls: urls,
            textSample: "chapter three")
    }

    // MARK: - Roster as a distribution

    @Test func rosterLineCarriesHistoryOnlyInTheFullTier() {
        let task = entry("Writing the thesis", minutes: 150, daysActive: 4,
                         lastActiveDays: 2, sources: ["overleaf.com", "scholar.google.com"])
        let full = Grouper.rosterLine(handle: "t1", entry: task, detail: .full)
        #expect(full == "t1: Writing the thesis · 2.5h over 4d · last 2d ago · "
            + "overleaf.com, scholar.google.com")
        #expect(Grouper.rosterLine(handle: "t1", entry: task, detail: .compact)
            == "t1: Writing the thesis")
        // Minted this run: no logged history yet, so no invented zeroes.
        #expect(Grouper.rosterLine(handle: "t2", entry: entry("Brand new task"), detail: .full)
            == "t2: Brand new task")
        #expect(Grouper.rosterLine(
            handle: "t3", entry: entry("Booking flights", minutes: 45, daysActive: 1),
            detail: .full) == "t3: Booking flights · 45m over 1d · last today")
    }

    @Test func compactTierKeepsTheHeaviestTasksInRecencyOrder() {
        let roster = (1...5).map { index in
            entry("task \(index)", minutes: index == 2 ? 5 : index * 100)
        }
        let kept = Grouper.compacted(roster, limit: 3)
        // Heaviest three (t5, t4, t3), still listed most-recent-first.
        #expect(kept.map(\.name) == ["task 3", "task 4", "task 5"])
        #expect(Grouper.compacted(roster, limit: 9).count == 5)
    }

    @Test func activeRosterCarriesLoggedTimeDaysAndSources() async throws {
        let db = try ShifuDatabase.inMemory()
        let day: Int64 = 86_400_000
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, gist, created_at, last_active_at)
                VALUES (1, 'sem:sf-trip', 'Planning the SF trip', 'Flights and lodging.',
                        ?, ?)
                """, arguments: [Self.nowMs - 5 * day, Self.nowMs - 2 * day])
            for (index, ms) in [3_600_000, 1_800_000].enumerated() {
                try sqlite.execute(sql: """
                    INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                    VALUES (1, ?, ?, 'united.com — flights')
                    """, arguments: [Self.nowMs - Int64(index + 2) * day, ms])
            }
            // 40 minutes on united.com, 10 on airbnb.com, and private time that
            // must never surface as a source.
            for (domain, minutes, category) in [("united.com", Int64(40), "admin"),
                                                ("airbnb.com", Int64(10), "admin"),
                                                ("bank.example", Int64(90), "private")] {
                try sqlite.execute(sql: """
                    INSERT INTO activities
                        (started_at, ended_at, app_bundle, domain, category, task_id, source)
                    VALUES (?, ?, 'com.apple.Safari', ?, ?, 1, 'rules')
                    """, arguments: [Self.nowMs - 2 * day,
                                     Self.nowMs - 2 * day + minutes * 60_000,
                                     domain, category])
            }
        }
        let roster = try Grouper.activeRoster(database: db, now: now)
        #expect(roster.count == 1)
        #expect(roster[0].minutes == 90)
        #expect(roster[0].daysActive == 2)
        #expect(roster[0].lastActiveDays == 2)
        #expect(roster[0].topSources == ["united.com", "airbnb.com"])
        #expect(Grouper.rosterLine(handle: "t1", entry: roster[0], detail: .full)
            .contains("1.5h over 2d · last 2d ago · united.com, airbnb.com"))
    }

    // MARK: - Stickiness, fenced

    @Test func promptShowsNeighborsAndFencesInterruptions() {
        let roster = [entry("Writing the thesis", minutes: 300, daysActive: 6)]
        let neighbors = [
            Grouper.NeighborBlock(
                startedAt: 0, endedAt: 15 * 60_000, appBundle: "com.apple.Safari",
                domain: "overleaf.com", taskKey: roster[0].key, taskName: roster[0].name),
            Grouper.NeighborBlock(
                startedAt: 40 * 60_000, endedAt: 55 * 60_000,
                appBundle: "com.tinyspeck.slackmacgap", domain: nil,
                taskKey: "sem:standups", taskName: "Team standups")
        ]
        let prompt = Grouper.prompt(roster: roster, blocks: [block()], neighbors: neighbors)
        #expect(prompt.contains("Already grouped, around this batch"))
        #expect(prompt.contains("15m overleaf.com → t1 (Writing the thesis)"))
        // Off-roster neighbours are named, not handled — nothing to reuse.
        #expect(prompt.contains("15m slackmacgap → Team standups"))
        #expect(prompt.contains("Work is sticky"))
        #expect(prompt.contains("Interruptions are the exception"))
        // Context lines carry no ids: only batch blocks are assignable.
        #expect(prompt.components(separatedBy: "id=").count == 2)
        #expect(!Grouper.prompt(roster: roster, blocks: [block()])
            .contains("Already grouped"))
    }

    @Test func compactTierTrimsTheContextSection() {
        let neighbors = (0..<5).map { index in
            Grouper.NeighborBlock(
                startedAt: Int64(index) * 600_000, endedAt: Int64(index) * 600_000 + 300_000,
                appBundle: "com.apple.Safari", domain: "site\(index).com",
                taskKey: "sem:thesis", taskName: "Writing the thesis")
        }
        let prompt = Grouper.prompt(roster: [], blocks: [block()], neighbors: neighbors,
                                    detail: .compact)
        #expect(!prompt.contains("site0.com"))
        #expect(!prompt.contains("site1.com"))
        #expect(prompt.contains("site4.com"))
    }

    @Test func assignedNeighborsCoverBothSidesOfTheAnchorOnly() async throws {
        let db = try ShifuDatabase.inMemory()
        let anchor: Int64 = 12 * 3_600_000
        let hour: Int64 = 3_600_000
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'sem:sf-trip', 'Planning the SF trip', 0, 0)
                """)
            // before | after | unassigned | outside the window | no task row
            for (start, semKey, category) in [(anchor - hour, "sem:sf-trip", "admin"),
                                              (anchor + hour, "sem:sf-trip", "admin"),
                                              (anchor - 2 * hour, nil, "admin"),
                                              (anchor - 9 * hour, "sem:sf-trip", "admin"),
                                              (anchor - 3 * hour, "sem:old-key", "admin"),
                                              (anchor - 4 * hour, "sem:sf-trip", "private")] {
                try sqlite.execute(sql: """
                    INSERT INTO activities
                        (started_at, ended_at, app_bundle, category, sem_key, source)
                    VALUES (?, ?, 'com.apple.Safari', ?, ?, 'rules')
                    """, arguments: [start, start + 600_000, category, semKey])
            }
        }
        let neighbors = try Grouper.assignedNeighbors(database: db, around: anchor)
        #expect(neighbors.map(\.startedAt) == [anchor - 3 * hour, anchor - hour, anchor + hour])
        #expect(neighbors[0].taskName == "old key")     // humanized: no task row
        #expect(neighbors[1].taskName == "Planning the SF trip")
    }

    // MARK: - Evidence: pages and spread sampling

    @Test func urlTokenKeepsTwoPathSegmentsAndDropsTheRest() {
        #expect(Grouper.urlToken("https://www.github.com/org/repo/pull/12?tab=files#c3")
            == "github.com/org/repo")
        #expect(Grouper.urlToken("https://united.com") == "united.com")
        #expect(Grouper.urlToken("not a url") == nil)
        // A secret pasted into a path is redacted here — `observations.url` is
        // stored raw, so the prompt is where it would have leaked.
        #expect(Grouper.urlToken("https://example.com/reset/ghp_0123456789abcdefghij")
            == "example.com/reset/[REDACTED:KEY]")
    }

    @Test func spreadIndicesReachFirstAndLast() {
        #expect(Grouper.spreadIndices(total: 12, count: 5) == [0, 2, 5, 8, 11])
        #expect(Grouper.spreadIndices(total: 3, count: 5) == [0, 1, 2])
        #expect(Grouper.spreadIndices(total: 0, count: 5).isEmpty)
    }

    @Test func blockEvidenceSpansTheWholeBlockAndCarriesPages() async throws {
        let db = try ShifuDatabase.inMemory()
        let minutes: Int64 = 60
        try await db.queue.write { sqlite in
            var activity = Activity(
                startedAt: 0, endedAt: minutes * 60_000, appBundle: "com.apple.Safari",
                domain: "github.com", category: .unclassified)
            try activity.insert(sqlite)
            for index in 0..<12 {
                try sqlite.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, window_title, url,
                         capture_kind, text, session_id)
                    VALUES (?, ?, 'com.apple.Safari', ?, ?, 'ax', ?, ?)
                    """, arguments: [Int64(index) * 300_000, Int64(index) * 300_000 + 1_000,
                                     "window \(index)",
                                     "https://github.com/shifu/shifu/pull/\(index)?q=secret",
                                     "text \(index)", activity.id])
            }
        }
        let samples = try Grouper.pendingSamples(database: db, from: 0, to: 10_000_000)
        #expect(samples.count == 1)
        // First and last observation both reach the model — a `LIMIT 5` would
        // have described an hour by its opening minutes.
        #expect(samples[0].titles.first == "window 0")
        #expect(samples[0].titles.last == "window 11")
        #expect(samples[0].titles.count == Grouper.sampleCount)
        #expect(samples[0].urls == ["github.com/shifu/shifu"])
        #expect(samples[0].textSample.contains("text 0"))
        #expect(samples[0].textSample.contains("text 11"))
        // The page identity replaces the bare domain in the prompt.
        let prompt = Grouper.prompt(roster: [], blocks: samples)
        #expect(prompt.contains("pages=github.com/shifu/shifu"))
        #expect(!prompt.contains("domain=github.com"))
        #expect(!prompt.contains("q=secret"))
    }

    // MARK: - Budget

    @Test func compactRosterKeepsSmallContextBackendsInBudget() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            for index in 0..<30 {
                try sqlite.execute(sql: """
                    INSERT INTO tasks (key, name, gist, created_at, last_active_at)
                    VALUES (?, ?, ?, 0, ?)
                    """, arguments: ["sem:task-\(index)", "Ongoing effort number \(index)",
                                     "A sentence of gist about effort \(index).",
                                     Self.nowMs - Int64(index) * 3_600_000])
            }
            var activity = Activity(
                startedAt: Self.nowMs, endedAt: Self.nowMs + 600_000,
                appBundle: "com.apple.Safari", domain: "partiful.com",
                category: .unclassified)
            try activity.insert(sqlite)
            try sqlite.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                VALUES (?, ?, 'com.apple.Safari', 'RSVP', 'ax', 'You are invited', ?)
                """, arguments: [Self.nowMs, Self.nowMs + 600_000, activity.id])
        }
        // Foundation Models: 4k for prompt *and* response (invariant 7).
        let backend = RecordingBackend(contextWindowTokens: 4_000)
        _ = try await Grouper.run(database: db, backend: backend, from: 0,
                                  to: Self.nowMs + 10_000_000, now: now)
        let prompt = try #require(backend.prompts.first)
        #expect(LLMTokens.estimate(prompt) <= 4_000 - Grouper.responseTokenReserve)
        #expect(prompt.contains("t\(Grouper.compactRosterLimit): "))
        #expect(!prompt.contains("t\(Grouper.compactRosterLimit + 1): "))
        #expect(!prompt.contains(" over "))     // compact lines carry no history
    }
}

/// Records prompts and places nothing, so a run can be inspected for what the
/// model was shown.
private final class RecordingBackend: LLMBackend, @unchecked Sendable {
    let name = "recording"
    let contextWindowTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(contextWindowTokens: Int) { self.contextWindowTokens = contextWindowTokens }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return #"{"assignments": [], "new_tasks": []}"#
    }
}

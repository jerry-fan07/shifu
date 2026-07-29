import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Answers every workflow mentioned in the prompt and records each call, so
/// tests can assert how `describe` chunks a run across a small context window.
private final class RecordingBackend: LLMBackend, @unchecked Sendable {
    let name = "recording"
    let contextWindowTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(contextWindowTokens: Int = 200_000) { self.contextWindowTokens = contextWindowTokens }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        let ids = prompt.split(separator: "\n").compactMap { line in
            line.hasPrefix("id=") ? Int64(line.dropFirst(3).prefix(while: \.isNumber)) : nil
        }
        return "[" + ids.map {
            #"{"id": \#($0), "verdict": "yes", "title": "Automate invoice reconciliation","#
                + #""suggestion": "Claude Code can pull the Stripe payouts and diff them.","#
                + #""setup_minutes": 45, "saved_minutes_weekly": 90,"#
                + #""teach": "Claude Code can be scheduled with launchd.", "confidence": 0.8}"#
        }.joined(separator: ",") + "]"
    }
}

private struct FixedBackend: LLMBackend {
    let name = "fixed"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

@Suite struct RadarTests {
    private func candidate(
        _ key: String = "task:topic:reconciling-invoices", occurrences: Int = 5,
        name: String = "reconciling invoices", totalMinutes: Double = 200
    ) -> PatternMiner.Candidate {
        PatternMiner.Candidate(
            key: key, kind: .task, name: name, gist: "Matching payouts against invoices",
            daysActive: occurrences, totalMinutes: totalMinutes, occurrences: occurrences,
            schedule: "weekday mornings, usually 9–11",
            sources: [.init(label: "stripe.com", minutes: 125),
                      .init(label: "docs.google.com", minutes: 75)],
            logSummaries: ["stripe.com, docs.google.com — reconciling invoices"],
            titles: ["Payouts – Stripe"], textSample: "payout 4,120.00 settled")
    }

    private func stored(_ database: ShifuDatabase) throws -> [Suggestion] {
        try database.queue.read { db in try Suggestion.order(Column("id")).fetchAll(db) }
    }

    /// Upsert + describe in one step — the weekly run, minus the mining.
    @discardableResult
    private func run(
        _ database: ShifuDatabase, _ candidates: [PatternMiner.Candidate],
        backend: any LLMBackend = RecordingBackend(), now: Date = Date()
    ) async throws -> Radar.Described {
        try Radar.upsert(candidates: candidates, database: database, now: now)
        return try await Radar.describe(database: database, backend: backend,
                                        candidates: candidates)
    }

    // MARK: - Upsert & dismissal memory

    @Test func upsertInsertsThenUpdates() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(try Radar.upsert(candidates: [candidate()], database: database) == 1)
        #expect(try Radar.upsert(candidates: [candidate(occurrences: 8)],
                                 database: database) == 0)
        let rows = try stored(database)
        #expect(rows.count == 1)
        #expect(rows[0].occurrences == 8)
        #expect(rows[0].kind == "task")
        #expect(rows[0].evidence.contains("weekday mornings"))
    }

    @Test func activeHidesUndescribedRows() async throws {
        let database = try ShifuDatabase.inMemory()
        try Radar.upsert(candidates: [candidate()], database: database)
        // Mined evidence is not advice: with no backend configured this is all
        // there is, and it must never render as a suggestion (§6.2).
        #expect(try Radar.active(database: database).isEmpty)

        // A row whose dossier isn't in this run's candidates stays untouched.
        try await Radar.describe(database: database, backend: RecordingBackend(),
                                 candidates: [candidate("task:topic:something-else")])
        #expect(try Radar.active(database: database).isEmpty)

        try await Radar.describe(database: database, backend: RecordingBackend(),
                                 candidates: [candidate()])
        #expect(try Radar.active(database: database).count == 1)
    }

    @Test func dismissedStaysDismissedUntilRecurrenceDoubles() async throws {
        let database = try ShifuDatabase.inMemory()
        try await run(database, [candidate(occurrences: 6)])
        try Radar.dismiss(try Radar.active(database: database)[0], database: database)
        #expect(try Radar.active(database: database).isEmpty)

        // 11 days active is < 2×6 → stays dismissed.
        try Radar.upsert(candidates: [candidate(occurrences: 11)], database: database)
        #expect(try Radar.active(database: database).isEmpty)

        // 12 doubles the recurrence it was dismissed at → resurfaces (§6.2),
        // keeping the description it already had.
        try Radar.upsert(candidates: [candidate(occurrences: 12)], database: database)
        let active = try Radar.active(database: database)
        #expect(active.count == 1)
        #expect(active[0].title == "Automate invoice reconciliation")
    }

    @Test func snoozeExpires() async throws {
        let database = try ShifuDatabase.inMemory()
        let now = Date()
        try await run(database, [candidate()], now: now)
        try Radar.snooze(try Radar.active(database: database)[0], days: 30,
                         database: database, now: now)
        #expect(try Radar.active(database: database).isEmpty)

        // Re-mine before expiry: still snoozed. After expiry: back.
        try Radar.upsert(candidates: [candidate()], database: database,
                         now: now.addingTimeInterval(10 * 86_400))
        #expect(try Radar.active(database: database).isEmpty)
        try Radar.upsert(candidates: [candidate()], database: database,
                         now: now.addingTimeInterval(31 * 86_400))
        #expect(try Radar.active(database: database).count == 1)
    }

    @Test func staleUndescribedRowsAreDroppedButDismissalsAreKept() async throws {
        let database = try ShifuDatabase.inMemory()
        let now = Date()
        try Radar.upsert(candidates: [candidate("task:topic:mined-once"),
                                      candidate("task:topic:dismissed-once")],
                         database: database, now: now)
        try Radar.dismiss(try #require(try stored(database).last), database: database)

        // Two months on, neither key recurs. The unjudged row is debris; the
        // dismissal is memory and has to survive.
        try Radar.upsert(candidates: [candidate("task:topic:something-new")],
                         database: database,
                         now: now.addingTimeInterval(Double(61) * 86_400))
        #expect(try stored(database).map(\.patternKey)
            == ["task:topic:dismissed-once", "task:topic:something-new"])
    }

    // MARK: - Describer

    @Test func describeWritesGatedFieldsFromMockJSON() async throws {
        let database = try ShifuDatabase.inMemory()
        let backend = RecordingBackend()
        let described = try await run(database, [candidate()], backend: backend)
        #expect(described == Radar.Described(accepted: 1, rejected: 0))

        // The dossier — not a domain and a count — is what the model saw.
        let prompt = try #require(backend.prompts.first)
        #expect(prompt.contains("Claude Code"))
        #expect(prompt.contains("what: Matching payouts against invoices"))
        #expect(prompt.contains("where: stripe.com 125m · docs.google.com 75m"))
        #expect(prompt.contains("titles: Payouts – Stripe"))
        #expect(prompt.contains("screen text: payout 4,120.00 settled"))

        let row = try #require(try Radar.active(database: database).first)
        #expect(row.title == "Automate invoice reconciliation")
        #expect(row.suggestion?.contains("Claude Code") == true)
        #expect(row.teach == "Claude Code can be scheduled with launchd.")
        #expect(row.setupMinutes == 45)
        // The LLM's grounded estimate replaces the mechanical one.
        #expect(row.estMinutesSavedWeekly == 90)
        #expect(row.confidence == 0.8)
        #expect(row.sizingLabel == "saves ≈90 min/wk (est.) · setup ≈45 min")

        // Re-mining does not clobber the grounded estimate with mined minutes.
        try Radar.upsert(candidates: [candidate()], database: database)
        #expect(try Radar.active(database: database)[0].estMinutesSavedWeekly == 90)
    }

    @Test func noVerdictLowConfidenceAndBadPaybackAutoDismiss() async throws {
        let database = try ShifuDatabase.inMemory()
        let candidates = ["task:topic:a", "task:topic:b", "task:topic:c"].map {
            candidate($0, occurrences: 7)
        }
        // 1: an honest no. 2: a guess. 3: 10 hours of setup to save 15 min/wk —
        // the shape of the suggestion that started this rewrite.
        let backend = FixedBackend(response: """
            ```json
            [{"id": 1, "verdict": "no", "title": "Reading the news",
              "suggestion": "This is reading. Leave it alone.",
              "setup_minutes": 0, "saved_minutes_weekly": 0, "confidence": 0.9},
             {"id": 2, "verdict": "yes", "title": "Maybe scriptable",
              "suggestion": "Something could be scripted here.",
              "setup_minutes": 20, "saved_minutes_weekly": 30, "confidence": 0.4},
             {"id": 3, "verdict": "yes", "title": "Puppeteer the whole thing",
              "suggestion": "Write browser automation for it.",
              "setup_minutes": "600", "saved_minutes_weekly": "15", "confidence": 0.9}]
            ```
            """)
        let described = try await run(database, candidates, backend: backend)
        #expect(described == Radar.Described(accepted: 0, rejected: 3))
        #expect(try Radar.active(database: database).isEmpty)

        // Each is dismissed *at its current recurrence* and left undescribed,
        // so a doubled habit comes back to be judged fresh rather than wearing
        // last month's no.
        for row in try stored(database) {
            #expect(row.status == "dismissed")
            #expect(row.dismissedAtOccurrences == 7)
            #expect(row.suggestion == nil)
            #expect(row.snoozedUntil != nil)        // the model's no is dated
        }
        try Radar.upsert(candidates: candidates.map { candidate($0.key, occurrences: 14) },
                         database: database)
        #expect(try stored(database).allSatisfy { $0.status == "new" && $0.suggestion == nil })
        #expect(try Radar.active(database: database).isEmpty)
    }

    @Test func savedMinutesCannotExceedTheMinutesObserved() async throws {
        let database = try ShifuDatabase.inMemory()
        // The dossier is 200 minutes over 14 days — 100 a week.
        let backend = FixedBackend(response: #"""
            [{"id": 1, "verdict": "yes", "title": "Automate the whole afternoon",
              "suggestion": "Claude Code can do all of it.", "setup_minutes": 120,
              "saved_minutes_weekly": 600, "confidence": 0.9}]
            """#)
        try await run(database, [candidate()], backend: backend)

        let row = try #require(try Radar.active(database: database).first)
        #expect(row.estMinutesSavedWeekly == 100)
        #expect(row.sizingLabel == "saves ≈100 min/wk (est.) · setup ≈2.0 h")
    }

    @Test func aYesWithoutNumbersStaysPendingRatherThanBeingBuried() async throws {
        let database = try ShifuDatabase.inMemory()
        let backend = FixedBackend(response: #"""
            [{"id": 1, "verdict": "yes", "title": "Weekly invoice reconciliation",
              "suggestion": "Claude Code can diff the payouts.", "confidence": 0.9}]
            """#)
        let described = try await run(database, [candidate()], backend: backend)
        // Neither accepted nor dismissed: a formatting slip must not bury a
        // real suggestion, so the row waits for next week's run.
        #expect(described == Radar.Described(accepted: 0, rejected: 0))
        let row = try #require(try stored(database).first)
        #expect(row.status == "new")
        #expect(row.suggestion == nil)
    }

    @Test func theModelsNoLapsesButTheUsersDoesNot() async throws {
        let database = try ShifuDatabase.inMemory()
        let now = Date()
        let backend = FixedBackend(response: #"""
            [{"id": 1, "verdict": "no", "title": "Reading the news",
              "suggestion": "Leave it alone.", "setup_minutes": 0,
              "saved_minutes_weekly": 0, "confidence": 0.9}]
            """#)
        try Radar.upsert(candidates: [candidate(occurrences: 9)], database: database, now: now)
        try await Radar.describe(database: database, backend: backend,
                                 candidates: [candidate(occurrences: 9)])
        #expect(try stored(database)[0].status == "dismissed")

        // 9 days active in a 14-day window can never double, so without the
        // re-ask date this row would be dismissed forever on a model's say-so.
        let later = now.addingTimeInterval(Double(Radar.reaskDismissedAfterDays + 1) * 86_400)
        try Radar.upsert(candidates: [candidate(occurrences: 9)], database: database, now: later)
        #expect(try stored(database)[0].status == "new")
        #expect(try stored(database)[0].suggestion == nil)   // judged fresh

        // A user's dismissal carries no date: it stands until the habit doubles.
        try Radar.dismiss(try stored(database)[0], database: database)
        try Radar.upsert(candidates: [candidate(occurrences: 9)], database: database,
                         now: later.addingTimeInterval(400 * 86_400))
        #expect(try stored(database)[0].status == "dismissed")
    }

    @Test func describeSplitsBatchesUnderSmallContextWindow() async throws {
        let database = try ShifuDatabase.inMemory()
        let candidates = (0..<6).map { candidate("task:topic:workflow-\($0)") }
        // A window with room for the framing plus a dossier or two — the
        // invariant-7 guard: prompts are sized by tokens, never by item count.
        let fixed = LLMTokens.estimate(Radar.describerPrompt([]))
        let backend = RecordingBackend(
            contextWindowTokens: Radar.responseTokenReserve + fixed + 400)
        let budget = backend.contextWindowTokens - Radar.responseTokenReserve

        let described = try await run(database, candidates, backend: backend)
        #expect(described.accepted == 6)
        #expect(backend.prompts.count > 1)
        for prompt in backend.prompts {
            #expect(LLMTokens.estimate(prompt) <= budget)
        }
    }

    @Test func automationPromptCarriesEvidenceAndAssessment() async throws {
        let database = try ShifuDatabase.inMemory()
        try await run(database, [candidate()])
        let brief = try #require(try Radar.active(database: database).first).automationPrompt
        #expect(brief.contains("Workflow: Automate invoice reconciliation"))
        #expect(brief.contains("weekday mornings"))       // observed evidence
        #expect(brief.contains("stripe.com"))
        #expect(brief.contains("Claude Code can pull the Stripe payouts"))
        #expect(brief.contains("Worth knowing: Claude Code can be scheduled"))
        #expect(brief.contains("setup ≈45 min"))
        #expect(brief.contains("Interview me first"))
    }
}

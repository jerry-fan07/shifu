import Foundation
import Testing
@testable import ShifuCore

private struct FixedBackend: LLMBackend {
    let name = "fixed"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

private final class RecordingBackend: LLMBackend, @unchecked Sendable {
    let name = "recording"
    var prompts: [String] = []
    let response: String
    init(response: String) { self.response = response }
    func complete(prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        return response
    }
}

/// The model's second opinion (design.md §4.7): what it is shown, what its
/// answer may change, and the one-shot rule.
@Suite struct DeadlineScoutJudgeTests {
    private let day: Int64 = 86_400_000
    private let hour: Int64 = 3_600_000

    private var noon: Int64 {
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func seed(_ database: ShifuDatabase, _ title: String, score: Int) throws -> Int64 {
        let hit = DeadlineScout.Hit(
            key: "\(title)", title: title, context: "MATH 1560 Dashboard", dueAt: noon + 5 * day,
            allDay: false, category: .submission, score: score,
            evidence: "\(title): Oct 20 at 11:59PM", signals: [])
        try database.queue.write { db in
            _ = try DeadlineProposalStore.record(
                [hit], source: .init(appBundle: "com.google.Chrome", domain: "gradescope.com", seenAt: noon),
                db: db, now: noon)
        }
        return try #require(try DeadlineProposalStore.pending(database: database).first { $0.title == title }?.id)
    }

    @Test func thePromptShowsEachProposalWithItsEvidenceAndContext() throws {
        let database = try ShifuDatabase.inMemory()
        let id = try seed(database, "Late Due Date", score: 9)
        let rows = try DeadlineProposalStore.unjudged(database: database, limit: 10)
        let prompt = DeadlineScoutJudge.prompt(for: rows, now: noon)
        #expect(prompt.contains("id=\(id) due="))
        #expect(prompt.contains("window=\"MATH 1560 Dashboard\""))
        #expect(prompt.contains("site=gradescope.com"))
        #expect(prompt.contains("text: Late Due Date: Oct 20 at 11:59PM"))
        #expect(prompt.contains("scout=critical"))
        #expect(prompt.contains("Today is "))
        #expect(prompt.contains(DeadlineScout.Category.allCases.map(\.rawValue).joined(separator: ", ")))
    }

    @Test func parsingTakesProseAroundTheArrayAndClampsTheShift() {
        let tiers: [Int64: DeadlineScout.Tier] = [1: .normal, 2: .high, 3: .critical, 4: .low]
        let parsed = DeadlineScoutJudge.parse("""
            Sure — here is my read:
            [{"id": 1, "keep": true, "title": "MATH 1560 HW4", "category": "submission", "importance": 4},
             {"id": 2, "keep": "false"},
             {"id": 3, "keep": true, "importance": "1"},
             {"id": 4, "title": "  ", "importance": 2},
             {"id": 9, "keep": true}]
            Hope that helps.
            """, tiers: tiers)
        #expect(parsed.count == 4)                       // id 9 was never asked about
        #expect(parsed[0].tierShift == 1)                // normal → wants critical, moves one
        #expect(parsed[0].title == "MATH 1560 HW4")
        #expect(parsed[0].category == .submission)
        #expect(parsed[1].keep == false)
        #expect(parsed[2].tierShift == -1)               // critical → wants low, moves one
        #expect(parsed[3].keep == true)                  // missing keep keeps
        #expect(parsed[3].title == nil)                  // blank title is no title
        #expect(parsed[3].tierShift == 1)
        #expect(DeadlineScoutJudge.parse("no json here", tiers: tiers).isEmpty)
    }

    @Test func aRunAppliesVerdictsAndSpendsTheWholeBatch() async throws {
        let database = try ShifuDatabase.inMemory()
        let keep = try seed(database, "Late Due Date", score: 6)
        let drop = try seed(database, "Dining closes", score: 6)
        let skipped = try seed(database, "Unanswered", score: 6)
        let backend = RecordingBackend(response: """
            [{"id": \(keep), "keep": true, "title": "MATH 1560 HW4", "importance": 4},
             {"id": \(drop), "keep": false}]
            """)
        let summary = try await DeadlineScoutJudge.run(database: database, backend: backend, now: noon)
        #expect(summary.judged == 2)
        #expect(summary.dropped == 1)
        #expect(backend.prompts.count == 1)

        let kept = try #require(try DeadlineProposalStore.find(keep, database: database))
        #expect(kept.title == "MATH 1560 HW4")
        #expect(kept.tier == .critical)
        #expect(kept.judged)
        #expect(try DeadlineProposalStore.find(drop, database: database)?.status == .dismissed)
        // Not answered, still spent: it stands on the scout's score and is
        // not billed again.
        let left = try #require(try DeadlineProposalStore.find(skipped, database: database))
        #expect(left.judged)
        #expect(left.title == "Unanswered")
        #expect(left.tier == .high)
        #expect(try DeadlineProposalStore.unjudged(database: database, limit: 10).isEmpty)

        // A second run has nothing to ask.
        let again = try await DeadlineScoutJudge.run(database: database, backend: backend, now: noon)
        #expect(again == DeadlineScoutJudge.Summary())
        #expect(backend.prompts.count == 1)
    }

    @Test func anUnreadableAnswerThrowsButStillSpendsTheBatch() async throws {
        let database = try ShifuDatabase.inMemory()
        let id = try seed(database, "Late Due Date", score: 6)
        await #expect(throws: LLMError.self) {
            try await DeadlineScoutJudge.run(
                database: database, backend: FixedBackend(response: "I cannot help with that."), now: noon)
        }
        #expect(try DeadlineProposalStore.find(id, database: database)?.judged == true)
    }

    @Test func batchesAreCutByTokensNotCount() throws {
        let database = try ShifuDatabase.inMemory()
        for index in 0..<12 { _ = try seed(database, "Proposal \(index)", score: 6) }
        let rows = try DeadlineProposalStore.unjudged(database: database, limit: 40)
        let one = DeadlineScoutJudge.batches(rows, now: noon, promptTokenBudget: 100_000)
        #expect(one.count == 1)
        let header = LLMTokens.estimate(DeadlineScoutJudge.prompt(for: [], now: noon))
        let many = DeadlineScoutJudge.batches(rows, now: noon, promptTokenBudget: header + 120)
        #expect(many.count > 1)
        #expect(many.flatMap { $0 }.count == rows.count)
    }
}

import Foundation
import GRDB

/// The model's second opinion on what the scout spotted (design.md §4.7).
///
/// The scout decides what *is* a candidate; this only decides what to make of
/// one. It may veto (the row is dismissed and remembered, so the same line
/// stays quiet), reword the title into the user's intent, correct the
/// category, and move the tier by at most one step either way. It may not
/// mint a proposal the scout did not find, and a proposal it never reaches
/// stands on the scout's score alone — so with no backend, or a failing one,
/// the feature is whole, only less well worded.
///
/// One shot per proposal (`judged`), like a block card: the evidence is a
/// closed line of text and cannot improve, so re-asking buys the same answer.
public enum DeadlineScoutJudge {
    public struct Judgment: Equatable, Sendable {
        public var id: Int64
        public var keep: Bool
        public var title: String?
        public var category: DeadlineScout.Category?
        /// −1, 0 or +1 against the scout's tier.
        public var tierShift: Int

        public init(id: Int64, keep: Bool, title: String? = nil,
                    category: DeadlineScout.Category? = nil, tierShift: Int = 0) {
            self.id = id
            self.keep = keep
            self.title = title
            self.category = category
            self.tierShift = tierShift
        }
    }

    public struct Summary: Equatable, Sendable {
        public var judged = 0
        public var dropped = 0

        public init() {}
    }

    /// Proposals per run. A busy day spots a few dozen; the rest wait an hour.
    public static let batchLimit = 40
    /// One verdict is an id, a flag, a short title, a category and a digit —
    /// call it 50 tokens; the batch needs ~2k, with room for a model that
    /// pads.
    public static let responseTokenReserve = 3_000
    static let titleLimit = 70

    // MARK: - Prompt (pure, testable)

    static func prompt(for proposals: [DeadlineProposal], now: Int64, calendar: Calendar = .current) -> String {
        let categories = DeadlineScout.Category.allCases.map(\.rawValue).joined(separator: ", ")
        var lines = [
            "Below are dates a local screen reader spotted on one person's Mac, each with the line",
            "it was read from and the window it was in. For each, decide whether it is a real",
            "commitment, event or opportunity FOR THIS PERSON — something they would want to be",
            "reminded of — as opposed to opening hours, a news or social post, a past event, an",
            "advertisement, a date in code or a transcript, or someone else's schedule.",
            "Fields:",
            "- id: as given",
            "- keep: true for a real one, false to drop it",
            "- title: the thing as they would name it, 3-8 words, no date (\"CSCI 1420 HW2 late",
            "  deadline\", \"RSVP for Virtual Connect event\") — use the window for the subject",
            "- category: exactly one of \(categories)",
            "- importance: 4 must not miss (exam, graded submission, answering an offer),",
            "  3 should act on it (application, registration, RSVP, payment), 2 worth knowing",
            "  (an event they might attend), 1 barely (a sale, a product launch)",
            "Respond with ONLY a JSON array, one object per id:",
            #"[{"id": 1, "keep": true, "title": "CSCI 1420 HW2 late deadline","#,
            #"  "category": "submission", "importance": 4}]"#,
            "",
            "Today is \(day(now, calendar: calendar)).",
            "Spotted:"
        ]
        for proposal in proposals {
            var desc = "id=\(proposal.id ?? 0) due=\(day(proposal.dueAt, calendar: calendar))"
            if !proposal.allDay { desc += " \(DeadlineCopy.clock(proposal.dueAt, calendar: calendar))" }
            desc += " app=\(SemanticTaskGrouper.shortBundle(proposal.sourceApp))"
            if let domain = proposal.sourceDomain { desc += " site=\(domain)" }
            if let context = proposal.context { desc += " window=\"\(context)\"" }
            desc += " seen=\(proposal.sightings)x/\(proposal.seenDays)d"
            desc += " scout=\(proposal.tier.label.lowercased())"
            lines.append(desc)
            lines.append("  text: \(proposal.evidence)")
        }
        return lines.joined(separator: "\n")
    }

    static func batches(_ proposals: [DeadlineProposal], now: Int64, promptTokenBudget: Int) -> [[DeadlineProposal]] {
        LLMTokens.batches(proposals, budget: promptTokenBudget) { prompt(for: $0, now: now) }
    }

    /// Parses the model's array, tolerating prose around it. A verdict
    /// without an id is nothing; one without `keep` keeps.
    static func parse(_ response: String, tiers: [Int64: DeadlineScout.Tier]) -> [Judgment] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.int64Value, let current = tiers[id] else { return nil }
            let keep = (item["keep"] as? Bool) ?? ((item["keep"] as? String).map { $0.lowercased() == "true" } ?? true)
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(titleLimit)
            let category = (item["category"] as? String).flatMap(DeadlineScout.Category.init(rawValue:))
            var shift = 0
            if let importance = (item["importance"] as? NSNumber)?.intValue
                ?? (item["importance"] as? String).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                // 1…4 maps onto the four tiers; the judge may move one step.
                let wanted = max(0, min(3, importance - 1))
                shift = max(-1, min(1, wanted - current.rawValue))
            }
            return Judgment(
                id: id, keep: keep, title: title.flatMap { $0.isEmpty ? nil : String($0) },
                category: category, tierShift: shift)
        }
    }

    // MARK: - Pipeline

    /// Judges every open, unjudged proposal, best first. A mid-run failure
    /// keeps the batches already written.
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws -> Summary {
        let proposals = try DeadlineProposalStore.unjudged(database: database, limit: batchLimit)
        guard !proposals.isEmpty else { return Summary() }
        let promptBudget = max(512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))
        var summary = Summary()
        for batch in batches(proposals, now: now, promptTokenBudget: promptBudget) {
            let response = try await backend.complete(
                prompt: prompt(for: batch, now: now), maxTokens: responseTokenReserve)
            let tiers = Dictionary(uniqueKeysWithValues: batch.compactMap { row in row.id.map { ($0, row.tier) } })
            let judgments = parse(response, tiers: tiers)
            let batchIDs = batch.compactMap(\.id)
            try await database.queue.write { db in
                for judgment in judgments {
                    try DeadlineProposalStore.applyJudgment(judgment, db: db)
                }
                // The whole batch is spent, answered or not: a proposal the
                // model skipped stands on the scout's score, and is not
                // billed again next hour for an answer it did not get.
                try db.execute(sql: """
                    UPDATE deadline_proposals SET judged = 1
                    WHERE id IN (\(databaseQuestionMarks(count: batchIDs.count))) AND status = 'new'
                    """, arguments: StatementArguments(batchIDs))
            }
            summary.judged += judgments.count
            summary.dropped += judgments.filter { !$0.keep }.count
            if judgments.isEmpty {
                throw LLMError.badResponse("judge returned no verdicts for \(batch.count) proposals")
            }
        }
        return summary
    }

    private static func day(_ ms: Int64, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: Double(ms) / 1_000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

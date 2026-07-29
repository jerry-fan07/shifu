import Foundation
import GRDB

/// The opportunity describer (design.md §6.2): each mined dossier goes to the
/// model with real evidence and a named tool catalog, and comes back either as
/// advice a person can act on or as a "no" that dismisses itself.
///
/// Three things make this different from the one-line describer it replaces:
/// the model sees *what the user was doing* (schedule, sources, day logs,
/// sampled titles and text) instead of a domain and a count; it is told which
/// automation surfaces actually exist in 2026, so it stops reaching for
/// Puppeteer boilerplate; and its answer passes honesty gates in code, so a
/// "10–15 h setup to save 15 min/week" can never reach the tab.
extension Radar {
    /// Below this the model is guessing, and a guess is worse than an empty
    /// tab. Same floor the classifier and grouper use.
    public static let confidenceFloor = 0.6
    /// Setup has to pay for itself inside a month of the weekly saving it
    /// claims. This is the gate the old ranking-only design lacked.
    public static let maxPaybackWeeks: Double = 4
    /// How long the describer's own "no" stands before the row is judged
    /// again. Only auto-dismissals carry a date — a user's dismissal is
    /// permanent until the habit doubles (`Radar.resurfaces`).
    public static let reaskDismissedAfterDays = 90
    /// Room reserved for the JSON answer; the prompt is batched to fit the
    /// rest of the window (CLAUDE.md invariant 7). Larger than the grouper's
    /// because each verdict carries prose, not a handle and a number.
    public static let responseTokenReserve = 2_500

    /// One `suggestions` row paired with the dossier it was mined from, for
    /// the length of one weekly run. Dossiers are never persisted: a row the
    /// describer doesn't reach is simply re-mined next week.
    struct Dossier {
        var id: Int64
        var candidate: PatternMiner.Candidate
    }

    public struct Described: Equatable, Sendable {
        public var accepted = 0
        public var rejected = 0

        public init(accepted: Int = 0, rejected: Int = 0) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }

    // MARK: - Prompt (pure, testable)

    static func describerPrompt(_ batch: [Dossier]) -> String {
        var lines = header
        for dossier in batch { lines.append(contentsOf: dossierLines(dossier)) }
        lines.append(contentsOf: wireFormat)
        return lines.joined(separator: "\n")
    }

    /// Framing + the tool catalog. Named surfaces are the point: without them
    /// the model falls back on whatever automation advice was common in its
    /// training data, which is how "write Puppeteer scripts, 10–15 h setup"
    /// became the tab's house style.
    private static var header: [String] {
        [
            "Below is how one person actually spent their time over the last "
                + "\(PatternMiner.windowDays) days,",
            "taken from a local screen-time ledger. For each recurring workflow, decide whether",
            "automating it is worth their time — and if so, with which tool.",
            "",
            "Most habits are fine exactly as they are. Reading, browsing, judgment calls and",
            "thinking work cannot be automated: answer no. No is a useful answer here — a tab",
            "of weak suggestions is worse than an empty one.",
            "",
            "Tools you may recommend. Pick the simplest one that fully does the job:",
            "- Claude Code: an agentic coding tool in the terminal. Scripts, file and data",
            "  chores, API glue, report generation, repo work. Schedule it with cron or launchd",
            "  to run unattended.",
            "- claude.ai / Claude Desktop: Projects hold reusable context; MCP connectors reach",
            "  Gmail, Drive, Calendar, Notion, GitHub and Slack; scheduled tasks re-run a saved",
            "  prompt on their own. Best for recurring research, summarizing, triage, drafting.",
            "- Claude in Chrome: a browser agent that drives the pages they already use. Best",
            "  for repetitive multi-step web work with no API behind it.",
            "- OS-native automation when the job is deterministic: Shortcuts, AppleScript,",
            "  launchd, Hazel (file rules), Keyboard Maestro (macros and hotkeys).",
            "- Alerting instead of polling: when a page is checked over and over, the fix is a",
            "  notification, webhook or watcher, so the change comes to them.",
            "",
            "Rules:",
            "- Ground every claim in the evidence shown. Never invent data sources, file names,",
            "  APIs, sites or accounts that do not appear in it.",
            "- Setup estimates must be realistic for someone competent with these tools.",
            "- Minutes saved can never exceed the minutes actually observed.",
            "- If it needs access they may not have (an API key, an admin console, an export),",
            "  make getting that the first step.",
            "- Name the tool explicitly and give one concrete first step.",
            "",
            "Workflows:"
        ]
    }

    /// One dossier as the model sees it.
    private static func dossierLines(_ dossier: Dossier) -> [String] {
        let candidate = dossier.candidate
        var lines = ["", "id=\(dossier.id) [\(candidate.kind.rawValue)] \(candidate.name)"]
        if let gist = candidate.gist, !gist.isEmpty { lines.append("  what: \(gist)") }
        lines.append("  observed: \(candidate.evidenceLine)")
        if !candidate.sources.isEmpty {
            lines.append("  where: " + candidate.sources
                .prefix(PatternMiner.topSourceLimit)
                .map { "\($0.label) \(Int($0.minutes.rounded()))m" }
                .joined(separator: " · "))
        }
        for signal in candidate.signals { lines.append("  signal: \(signal)") }
        for summary in candidate.logSummaries { lines.append("  day log: \(summary)") }
        if !candidate.titles.isEmpty {
            lines.append("  titles: " + candidate.titles.joined(separator: " | "))
        }
        if !candidate.textSample.isEmpty { lines.append("  screen text: \(candidate.textSample)") }
        return lines
    }

    private static var wireFormat: [String] {
        [
            "",
            "Respond with ONLY a JSON array, one object per workflow above:",
            #"[{"id": 12, "verdict": "yes", "title": "Weekly invoice reconciliation","#,
            #"  "suggestion": "2-4 sentences: what the workflow is, which tool automates it,"#
                + #" and the concrete first step.","#,
            #"  "setup_minutes": 45, "saved_minutes_weekly": 30,"#,
            #"  "teach": "One sentence naming a capability they may not know exists.","#,
            #"  "confidence": 0.8}]"#,
            "verdict: yes (worth automating), partial (one step of it is), no (leave it manual).",
            "title: 4-8 words naming the workflow — no numbers, no tool names.",
            "confidence: 0-1 that this is genuinely worth their time. Be honest.",
            "Answer for every id, including the ones you say no to."
        ]
    }

    /// Splits dossiers into batches whose rendered prompt fits the budget
    /// (`LLMTokens.batches`), so this scales from a 4k window to a 200k one
    /// without a per-backend special case (invariant 7). The framing and tool
    /// catalog are re-rendered per batch, which is the point: they are ~1k
    /// tokens of the budget every batch has to pay.
    static func batches(_ dossiers: [Dossier], promptTokenBudget: Int) -> [[Dossier]] {
        LLMTokens.batches(dossiers, budget: promptTokenBudget, render: describerPrompt)
    }

    // MARK: - Verdicts

    /// One workflow's verdict. A *proposal*, like every other LLM output here:
    /// `apply` drops ids outside the batch and runs the gates below.
    struct Description: Equatable {
        var id: Int64
        var verdict: String
        var title: String
        var suggestion: String
        var setupMinutes: Double?
        var savedMinutesWeekly: Double?
        var teach: String?
        var confidence: Double
    }

    static func parseDescriptions(_ response: String) -> [Description] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { object in
            guard let id = (object["id"] as? NSNumber)?.int64Value,
                  let title = object["title"] as? String,
                  let suggestion = object["suggestion"] as? String
            else { return nil }
            return Description(
                id: id,
                verdict: (object["verdict"] as? String ?? "yes").lowercased(),
                title: String(title.prefix(80)),
                suggestion: String(suggestion.prefix(600)),
                setupMinutes: number(object["setup_minutes"]),
                savedMinutesWeekly: number(object["saved_minutes_weekly"]),
                teach: (object["teach"] as? String).map { String($0.prefix(240)) },
                confidence: number(object["confidence"]) ?? 0)
        }
    }

    /// Models answer "45" and "45 minutes" about equally often.
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String {
            return Double(text.prefix { $0.isNumber || $0 == "." || $0 == "-" })
        }
        return nil
    }

    /// What a verdict does to its row.
    enum Outcome: Equatable {
        case accepted(savedMinutesWeekly: Double)
        case rejected
        /// The model said yes but left out the numbers the gate needs. Not a
        /// no: the row stays pending and is asked about again next week,
        /// rather than being buried by a formatting slip.
        case unanswered
    }

    /// The worthwhileness gate (§6.2). Confidence used to scale rank only,
    /// which meant everything shipped and the weak ones merely shipped lower.
    ///
    /// The saving is also held to what was actually observed. "Ground every
    /// claim in the evidence" is a prompt rule, and prompt rules are requests;
    /// a workflow that costs 40 min a week cannot be made to save 600,
    /// however confidently that is asserted, and the number feeds both the
    /// tab's sizing line and the ranking.
    static func outcome(_ description: Description, observedWeeklyMinutes: Double) -> Outcome {
        guard description.verdict != "no", description.confidence >= confidenceFloor
        else { return .rejected }
        guard let saved = description.savedMinutesWeekly, saved > 0,
              let setup = description.setupMinutes, setup >= 0
        else { return .unanswered }
        let grounded = min(saved, max(observedWeeklyMinutes, 1))
        return setup <= maxPaybackWeeks * grounded
            ? .accepted(savedMinutesWeekly: grounded)
            : .rejected
    }

    // MARK: - Pipeline

    /// Describes this run's freshly mined candidates. Rows that were already
    /// described keep their text; rows the model rejects are auto-dismissed at
    /// their current recurrence, so they return only if the habit doubles —
    /// and they return *undescribed*, to be judged fresh rather than wearing
    /// last month's "no".
    @discardableResult
    public static func describe(
        database: ShifuDatabase, backend: any LLMBackend,
        candidates: [PatternMiner.Candidate]
    ) async throws -> Described {
        let byKey = Dictionary(candidates.map { ($0.key, $0) }) { first, _ in first }
        let pending = try await database.queue.read { db in
            try Suggestion.filter(sql: "suggestion IS NULL AND status = 'new'").fetchAll(db)
        }
        let dossiers = pending.compactMap { row -> Dossier? in
            guard let id = row.id, let candidate = byKey[row.patternKey] else { return nil }
            return Dossier(id: id, candidate: candidate)
        }
        guard !dossiers.isEmpty else { return Described() }

        let budget = max(
            512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))
        var outcome = Described()
        for batch in batches(dossiers, promptTokenBudget: budget) {
            let response = try await backend.complete(
                prompt: describerPrompt(batch), maxTokens: responseTokenReserve)
            let applied = try apply(parseDescriptions(response), batch: batch, database: database)
            outcome.accepted += applied.accepted
            outcome.rejected += applied.rejected
        }
        return outcome
    }

    static func apply(
        _ descriptions: [Description], batch: [Dossier], database: ShifuDatabase,
        now: Date = Date()
    ) throws -> Described {
        let observedByID = Dictionary(uniqueKeysWithValues: batch.map {
            ($0.id, $0.candidate.weeklyMinutes)
        })
        let reaskAt = Int64(now.timeIntervalSince1970 * 1_000)
            + Int64(reaskDismissedAfterDays) * 86_400_000
        return try database.queue.write { db in
            var summary = Described()
            for item in descriptions {
                guard let observed = observedByID[item.id] else { continue }
                switch outcome(item, observedWeeklyMinutes: observed) {
                case .accepted(let saved):
                    try db.execute(sql: """
                        UPDATE suggestions
                        SET title = ?, suggestion = ?, teach = ?, setup_minutes = ?,
                            est_minutes_saved_weekly = ?, confidence = ?
                        WHERE id = ?
                        """, arguments: [item.title, item.suggestion, item.teach,
                                         item.setupMinutes, saved, item.confidence, item.id])
                    summary.accepted += 1
                case .rejected:
                    // Dismissed at its current recurrence *and* dated: the
                    // habit doubling brings it back, and so does the re-ask
                    // date, since this "no" is the model's and not the user's.
                    try db.execute(sql: """
                        UPDATE suggestions
                        SET status = 'dismissed', dismissed_at_occurrences = occurrences,
                            snoozed_until = ?, confidence = ?
                        WHERE id = ?
                        """, arguments: [reaskAt, item.confidence, item.id])
                    summary.rejected += 1
                case .unanswered:
                    continue
                }
            }
            return summary
        }
    }
}

import Foundation
import GRDB

/// A ranked automation suggestion (design.md §6.2).
public struct Suggestion: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "suggestions"

    public var id: Int64?
    public var createdAt: Int64
    public var patternKey: String
    public var kind: String
    public var evidence: String
    public var occurrences: Int
    public var avgMinutes: Double
    /// **Two meanings, one column.** Before the describer runs this holds the
    /// minutes the candidate *costs* per week — mechanical, used only to rank
    /// dossiers for the LLM budget. `Radar.describe` then overwrites it with
    /// the model's grounded estimate of what automating it would actually
    /// save, and only that estimate is ever shown or re-ranked on. Rows the
    /// describer never reached are hidden from `active`, so the mechanical
    /// number never reaches a human (§6.2).
    public var estMinutesSavedWeekly: Double
    public var title: String?
    public var suggestion: String?
    /// The model's own setup estimate, in minutes — half of the honest sizing
    /// the tab shows ("saves ≈45 min/wk · setup ≈30 min") and the input to the
    /// payback gate. Nil until described.
    public var setupMinutes: Double?
    /// One "did you know" sentence about the tool being recommended. The tab
    /// exists to teach the user automation surfaces they don't know about, and
    /// this is the line that does it.
    public var teach: String?
    public var confidence: Double?
    public var status: String                 // new | dismissed | snoozed
    public var dismissedAtOccurrences: Int?
    public var snoozedUntil: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case patternKey = "pattern_key"
        case kind
        case evidence
        case occurrences
        case avgMinutes = "avg_minutes"
        case estMinutesSavedWeekly = "est_minutes_saved_weekly"
        case title
        case suggestion
        case setupMinutes = "setup_minutes"
        case teach
        case confidence
        case status
        case dismissedAtOccurrences = "dismissed_at_occurrences"
        case snoozedUntil = "snoozed_until"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Rank: estimated time saved × confidence (§6.2).
    public var score: Double { estMinutesSavedWeekly * (confidence ?? 0.5) }

    /// The honest trailing line: an estimate labelled as one, next to what it
    /// costs to get. The old UI rendered "≈X min/week" as fact from a
    /// mechanical heuristic that assumed the whole ritual vanished.
    public var sizingLabel: String {
        var parts = ["saves ≈\(Int(estMinutesSavedWeekly.rounded())) min/wk (est.)"]
        if let setup = setupMinutes {
            parts.append(setup >= 120
                ? "setup ≈\(String(format: "%.1f", setup / 60)) h"
                : "setup ≈\(Int(setup.rounded())) min")
        }
        return parts.joined(separator: " · ")
    }

    /// The "Copy" action: a brief describing the workflow well enough that
    /// pasting it into Claude Code (or any agent) starts real work (§6.2).
    /// Built from persisted fields only — the dossier itself is in-memory and
    /// long gone by the time the user clicks.
    public var automationPrompt: String {
        var lines = [
            "I want to automate a repetitive part of my own workflow. The notes below",
            "come from a local screen-time ledger, so the observations are real.",
            "",
            "Workflow: \(title ?? patternKey)",
            "Observed: \(evidence)"
        ]
        if let suggestion { lines.append("My tooling notes: \(suggestion)") }
        if let teach { lines.append("Worth knowing: \(teach)") }
        lines.append("Rough sizing: \(sizingLabel)")
        lines.append(contentsOf: [
            "",
            "Interview me first — the data sources, the accounts and access involved, and",
            "the edge cases — then build it. Prefer the simplest thing that fully works,",
            "keep it local unless there's a real reason not to, and tell me if you think",
            "this isn't worth automating after all."
        ])
        return lines.joined(separator: "\n")
    }
}

/// The radar pipeline: mine → upsert (with dismissal memory) → describe.
/// The describer half lives in `RadarDescriber.swift`.
public enum Radar {
    /// How long a mined-but-never-described row is kept. Long enough to
    /// outlive an outage, short enough that keys which stop recurring don't
    /// accumulate: a row that still recurs is simply re-mined.
    static let pendingRowLifetimeDays = 60

    /// Upserts mined candidates. Dismissed candidates stay dismissed unless
    /// their recurrence doubles (§6.2); snoozes and the describer's own
    /// re-ask date expire by timestamp.
    @discardableResult
    public static func upsert(
        candidates: [PatternMiner.Candidate], database: ShifuDatabase, now: Date = Date()
    ) throws -> Int {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            // Rows nobody ever judged and nothing has re-mined for two months:
            // invisible either way, and they are not memory — a dismissal is,
            // and dismissals are kept.
            try db.execute(sql: """
                DELETE FROM suggestions
                WHERE suggestion IS NULL AND status = 'new' AND created_at < ?
                """, arguments: [nowMs - Int64(pendingRowLifetimeDays) * 86_400_000])
            var changed = 0
            for candidate in candidates {
                if var existing = try Suggestion
                    .filter(Column("pattern_key") == candidate.key).fetchOne(db) {
                    // Recurrence always tracks the fresh mine — the dismissal
                    // memory reads it. The *displayed* facts only move while
                    // the row is still undescribed: once a suggestion has been
                    // written from a given dossier, refreshing the evidence
                    // under it would leave the caption arguing with the advice
                    // and the sizing above it.
                    existing.occurrences = candidate.occurrences
                    if existing.suggestion == nil {
                        existing.evidence = candidate.evidenceLine
                        existing.avgMinutes = candidate.avgMinutes
                        existing.estMinutesSavedWeekly = candidate.weeklyMinutes
                    }
                    if existing.status == "dismissed", resurfaces(existing, candidate, now: nowMs) {
                        existing.status = "new"
                        existing.snoozedUntil = nil
                    }
                    if existing.status == "snoozed",
                       let until = existing.snoozedUntil, until <= nowMs {
                        existing.status = "new"
                    }
                    try existing.update(db)
                } else {
                    var fresh = Suggestion(
                        id: nil, createdAt: nowMs, patternKey: candidate.key,
                        kind: candidate.kind.rawValue, evidence: candidate.evidenceLine,
                        occurrences: candidate.occurrences, avgMinutes: candidate.avgMinutes,
                        estMinutesSavedWeekly: candidate.weeklyMinutes,
                        title: nil, suggestion: nil, setupMinutes: nil, teach: nil,
                        confidence: nil, status: "new",
                        dismissedAtOccurrences: nil, snoozedUntil: nil
                    )
                    try fresh.insert(db)
                    changed += 1
                }
            }
            return changed
        }
    }

    /// Whether a dismissed row comes back (§6.2). Two ways in:
    ///
    /// 1. The habit doubled — the rule for a *user's* dismissal, which is
    ///    permanent until then. Note the ceiling this has for tasks, where
    ///    recurrence is days active inside a 14-day window: a task dismissed
    ///    at 8 days can never double, and that is the intent. The user said no
    ///    to something they already do most days.
    /// 2. The describer's own "no" lapsed. An auto-dismissal is a model's
    ///    opinion, not the user's, and case 1 would make the frequent ones
    ///    permanent — so `describe` stamps a re-ask date and the row is judged
    ///    again, from scratch, when it passes.
    static func resurfaces(
        _ existing: Suggestion, _ candidate: PatternMiner.Candidate, now: Int64
    ) -> Bool {
        if let until = existing.snoozedUntil, until <= now { return true }
        guard let atDismissal = existing.dismissedAtOccurrences else { return false }
        return candidate.occurrences >= atDismissal * 2
    }

    /// Active suggestions, ranked by score. **Described rows only**: an
    /// undescribed row holds mined evidence and a mechanical number, and
    /// rendering that as advice is how "google.com visited 255×" ever reached
    /// the tab on a machine with no backend configured.
    public static func active(database: ShifuDatabase) throws -> [Suggestion] {
        try database.queue.read { db in
            try Suggestion
                .filter(sql: "status = 'new' AND suggestion IS NOT NULL")
                .fetchAll(db)
        }.sorted { $0.score > $1.score }
    }

    public static func dismiss(_ suggestion: Suggestion, database: ShifuDatabase) throws {
        guard let id = suggestion.id else { return }
        try database.queue.write { db in
            // A user's no clears any re-ask date the describer set: theirs is
            // the verdict that stands until the habit doubles.
            try db.execute(sql: """
                UPDATE suggestions
                SET status = 'dismissed', dismissed_at_occurrences = occurrences,
                    snoozed_until = NULL
                WHERE id = ?
                """, arguments: [id])
        }
    }

    public static func snooze(_ suggestion: Suggestion, days: Int = 30,
                              database: ShifuDatabase, now: Date = Date()) throws {
        guard let id = suggestion.id else { return }
        let until = Int64(now.timeIntervalSince1970 * 1_000) + Int64(days) * 86_400_000
        try database.queue.write { db in
            try db.execute(sql: "UPDATE suggestions SET status = 'snoozed', snoozed_until = ? WHERE id = ?",
                           arguments: [until, id])
        }
    }
}

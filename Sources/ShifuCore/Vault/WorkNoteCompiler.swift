import Foundation
import GRDB

/// Compiles work notes (vault-features.md §2.1): one Markdown note per
/// (task, local day), rebuilt idempotently like `TaskGrouper.rebuildLogs`.
/// Deterministic parts are always rewritten; the LLM `## Sessions` prose is
/// written once a day is over, and rewritten only when the day's underlying
/// activities changed (content-hash gate), so re-analysis never burns tokens
/// on unchanged days.
///
/// Inputs are non-private `activities` rows and the evidence their blocks
/// already carry — block cards, window titles, and only failing both a
/// little redacted text (`WorkNoteEvidence.swift`); never anything upstream
/// of the redaction choke point.
public enum WorkNoteCompiler {
    /// What one `run` did. `narrativesGenerated` is the count that cost tokens;
    /// `notesWritten` includes notes whose deterministic parts were rewritten
    /// while their prose carried over unchanged, so the two differ by design.
    public struct Summary: Equatable, Sendable {
        public var notesWritten: Int
        public var narrativesGenerated: Int
        /// Days that wanted prose and didn't get it. Counted and reported
        /// because the alternative is what happened on 2026-07-30..08-01: a
        /// `try?` swallowed every failure, the only log line fired on
        /// success, and thirteen calls a day bought nothing in silence.
        public var narrativesFailed: Int

        public init(notesWritten: Int = 0, narrativesGenerated: Int = 0,
                    narrativesFailed: Int = 0) {
            self.notesWritten = notesWritten
            self.narrativesGenerated = narrativesGenerated
            self.narrativesFailed = narrativesFailed
        }
    }

    /// Substance threshold (vault-features.md §2.1): task-days shorter than
    /// this (or with no evidence at all) get no narrative. Twenty minutes,
    /// raised from ten in the 2026-09 cost pass: on the dogfood ledger that
    /// keeps 3.6 narrated task-days a day of the 5.6 that cleared ten, and a
    /// quarter hour on a task reads fine as its session times and sources.
    public static let minMinutesKey = "worknotes.min_minutes"
    static let defaultMinMinutes = 20

    /// How long a finished day's prose stays open to rewriting. A day is
    /// written up once it is over and re-written while late grouping, merges
    /// and cards are still settling it; after this it is history, and prose
    /// it already has is carried whatever its hash says. That is what keeps
    /// `--rebuild` (and any recompile of old days) from re-billing a vault's
    /// worth of notes. A day that was *never* described is still written up
    /// however old it is — a hole, not a rewrite (`Narration.missingOnly`).
    static let narrationHorizonMs: Int64 = 3 * 86_400_000

    /// What a changed day may earn this pass.
    enum Narration {
        /// A finished day inside the horizon: prose is owed whenever its
        /// evidence changed.
        case now
        /// The day still in progress: nothing is owed until it is over, and
        /// the old prose *and the old hash* carry, so it still reads
        /// "changed" once it is.
        case deferred
        /// A day past the horizon: carried as it is, unless it has no prose
        /// at all.
        case missingOnly
    }

    /// Gap that splits a task's day into separate sessions. Wider than the
    /// sessionizer's 2-minute block gap on purpose: switching apps shouldn't
    /// fragment the story, a lunch break should.
    static let sessionGapMs: Int64 = 15 * 60_000
    static let narrativeResponseTokens = 400

    /// How much of a day-note the day earned (vault-features.md §2.1). The
    /// rule is the day's *dominant* category, not the presence of any work:
    /// an afternoon of email with ten minutes of reading in it is a light day.
    enum Tier {
        /// Session bullets only, 400 tokens — the pre-existing behaviour.
        case light
        /// Session bullets plus a `## Notes` document: what was worked on,
        /// what was learned or decided, problems and their fixes.
        case detailed

        var responseTokens: Int {
            switch self {
            case .light: return WorkNoteCompiler.narrativeResponseTokens
            case .detailed: return WorkNoteCompiler.detailedResponseTokens
            }
        }
    }

    /// What a documented day is allowed to cost in answer tokens.
    ///
    /// Flat, not scaled to the day's evidence, because the measurement says
    /// the answer barely tracks the evidence: across 19 stage-labelled calls
    /// spanning 1.3k-16.6k-token prompts, completions ran 137-950 tokens with
    /// no useful correlation — a 16.6k prompt answered in 184, a 9.5k one in
    /// 950. The prompt asks for a bounded artifact (at most six bullets and
    /// three sub-headings), so a reserve is a ceiling on that artifact, not a
    /// budget proportional to the day.
    ///
    /// 1,200 was nonetheless too low: on 2026-08-01 thirteen calls stopped
    /// exactly on it, all on 36k+ prompts, while other calls on 37-39k
    /// prompts finished naturally at 790 and 907. So the overflow is real but
    /// small — the answers wanted somewhat more than 1,200, not multiples of
    /// it. 2,500 is ~2.6x the largest complete answer ever measured here, and
    /// the headroom costs $0.0007 per call at the fast slot's output rate.
    /// A day that still overflows this is salvaged rather than discarded
    /// (`narrative`), so the ceiling stops being a cliff either way.
    static let detailedResponseTokens = 2_500
    /// The categories that earn the detailed tier.
    static let detailCategories: Set<Category> = [.work, .learning]

    struct Pending {
        var note: WorkNote
        /// The hash of *this* compile's evidence. Held here rather than
        /// written into `note` up front: for a day that is owed prose the
        /// note carries the previous pass's hash until the prose lands, so
        /// the hash means "this evidence has been described", never "this
        /// evidence was attempted" (see `gather` and `run`).
        var freshHash: Int64
        var needsNarrative: Bool
        var tier: Tier
        /// The rendered activity log the prompt carries (`renderEvidence`).
        var evidence: String
    }

    // MARK: - Entry points

    /// Full analyzer pass: compile every (task, day) the window touches.
    /// Runs after TaskGrouper (so `activities.task_id` is assigned). Works
    /// without a backend — notes ship deterministic-only.
    ///
    /// Prose is written for **finished** days only (the day containing `to`
    /// compiles its deterministic parts and waits for midnight), and
    /// rewritten only while a day is inside `narrationHorizonMs`. An
    /// actively-worked task's
    /// hash moves on every pass, so describing the day in progress used to
    /// re-bill it every few hours — about 2.8 narrations per task-day on the
    /// dogfood ledger for prose the next one replaced. Today's note reads as
    /// session times and sources until tomorrow's first pass writes it up.
    @discardableResult
    public static func run(
        database: ShifuDatabase, vault: VaultStore, backend: (any LLMBackend)?,
        from: Int64, to: Int64, calendar: Calendar = .current
    ) async throws -> Summary {
        let spans: [(start: Int64, end: Int64)] = try await database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at FROM activities
                WHERE ended_at > ? AND started_at < ?
                  AND task_id IS NOT NULL AND category != 'private'
                """, arguments: [from, to]
            ).map { ($0["started_at"], $0["ended_at"]) }
        }
        let days = TaskGrouper.affectedDays(of: spans, calendar: calendar)
        let minMs = minDurationMs(database: database)

        var summary = Summary()
        for day in days {
            let narration: Narration = day.end > to ? .deferred
                : to - day.end < narrationHorizonMs ? .now : .missingOnly
            let pendings = try gather(
                day: day, database: database, vault: vault, calendar: calendar,
                minMs: minMs, narration: narration)
            for var pending in pendings {
                if pending.needsNarrative, let backend {
                    // The hash moves with the prose, never ahead of it: a day
                    // is recorded as described only once it has been. A
                    // failure here leaves the note exactly as the last good
                    // pass left it, which keeps it eligible for the next one.
                    if let prose = try? await narrative(for: pending, backend: backend),
                       !prose.sessions.isEmpty {
                        pending.note.sessionsProse = prose.sessions
                        pending.note.detailProse = prose.detail
                        pending.note.contentHash = pending.freshHash
                        summary.narrativesGenerated += 1
                    } else {
                        summary.narrativesFailed += 1
                    }
                }
                try vault.saveWork(pending.note)
                summary.notesWritten += 1
            }
            try cleanupStale(day: day, keeping: Set(pendings.map(\.note.taskKey)),
                             vault: vault, calendar: calendar)
        }
        return summary
    }

    /// Deterministic-only recompile of specific days — DeletionTools calls
    /// this after a date-range forget. Notes whose (task, day) lost all
    /// activities are removed; unchanged days keep their prose (hash match).
    @discardableResult
    public static func recompile(
        days: [(start: Int64, end: Int64)], database: ShifuDatabase, vault: VaultStore,
        calendar: Calendar = .current
    ) throws -> Int {
        var written = 0
        for day in days {
            let pendings = try gather(day: day, database: database, vault: vault,
                                      calendar: calendar, minMs: 0)
            for pending in pendings {
                try vault.saveWork(pending.note)
                written += 1
            }
            try cleanupStale(day: day, keeping: Set(pendings.map(\.note.taskKey)),
                             vault: vault, calendar: calendar)
        }
        return written
    }

    // MARK: - Deterministic compile

    private struct ActivityRow {
        var id: Int64
        var taskID: Int64
        var startedAt: Int64
        var endedAt: Int64
        var appBundle: String
        var domain: String?
        var topic: String?
        var category: Category
        var taskKey: String
        var taskName: String
        var card: String?
    }

    /// Stable identity of one activity for the regeneration gate. Never row
    /// ids: LedgerBuilder's idempotent rebuild recreates the window's rows
    /// with fresh ids every run, but the spans and the evidence (cards carry
    /// across the rebuild by span identity) are reproduced byte-identically —
    /// so span + evidence hash is what "unchanged" means.
    struct HashEntry {
        var startedAt: Int64
        var endedAt: Int64
        var evidenceHash: Int64
    }

    private struct TaskAgg {
        var taskID: Int64
        var taskKey: String
        var taskName: String
        var durationMs: Int64 = 0
        var sources: [String] = []
        var topics: [String] = []
        var spans: [(start: Int64, end: Int64)] = []
        var entries: [HashEntry] = []
        var evidence: [EvidenceItem] = []
        var msByCategory: [Category: Int64] = [:]

        /// The tier this task-day earned: detailed when the biggest share of
        /// its time was work or learning.
        var tier: Tier {
            guard let dominant = msByCategory.max(by: { $0.value < $1.value })?.key,
                  detailCategories.contains(dominant) else { return .light }
            return .detailed
        }
    }

    private struct Fetched {
        var rows: [ActivityRow]
        var evidenceByID: [Int64: ActivityEvidence]
        var linksByTask: [Int64: [String]]
    }

    /// One read: the day's task activities, their evidence
    /// (`WorkNoteEvidence.swift`), and the day's indexed knowledge notes per
    /// task (for `## Captured`).
    private static func fetchDay(
        day: (start: Int64, end: Int64), database: ShifuDatabase
    ) throws -> Fetched {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.task_id, a.started_at, a.ended_at, a.app_bundle, a.domain,
                       a.topic, a.category, a.card, t.key AS task_key, t.name AS task_name
                FROM activities a
                JOIN tasks t ON t.id = a.task_id
                WHERE a.ended_at > ? AND a.started_at < ? AND a.category != 'private'
                ORDER BY a.started_at
                """, arguments: [day.start, day.end]
            ).map { row in
                ActivityRow(
                    id: row["id"], taskID: row["task_id"],
                    startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"],
                    topic: row["topic"],
                    category: Category(rawValue: row["category"]) ?? .unclassified,
                    taskKey: row["task_key"], taskName: row["task_name"], card: row["card"])
            }
            var evidence: [Int64: ActivityEvidence] = [:]
            for row in rows {
                evidence[row.id] = try activityEvidence(db, activityID: row.id, card: row.card)
            }
            var links: [Int64: [String]] = [:]
            for taskID in Set(rows.map(\.taskID)) {
                // Deck cards are excluded (`deck_key IS NULL`). They carry the
                // task key and are "captured" on the day their deck was built,
                // so without this a single deck build would file twenty cards
                // under one day's work as if that day had produced them.
                links[taskID] = try String.fetchAll(db, sql: """
                    SELECT path FROM vault_index
                    WHERE kind = 'knowledge' AND task_id = ? AND deck_key IS NULL
                      AND captured >= ? AND captured < ?
                    ORDER BY captured
                    """, arguments: [taskID, day.start, day.end])
            }
            return Fetched(rows: rows, evidenceByID: evidence, linksByTask: links)
        }
    }

    /// Folds the day's rows into per-task aggregates, first-seen order.
    private static func aggregate(
        _ fetched: Fetched, day: (start: Int64, end: Int64)
    ) -> (perTask: [Int64: TaskAgg], order: [Int64]) {
        var perTask: [Int64: TaskAgg] = [:]
        var order: [Int64] = []
        for row in fetched.rows {
            if perTask[row.taskID] == nil {
                order.append(row.taskID)
                perTask[row.taskID] = TaskAgg(
                    taskID: row.taskID, taskKey: row.taskKey, taskName: row.taskName)
            }
            var agg = perTask[row.taskID]!
            let clipped = min(row.endedAt, day.end) - max(row.startedAt, day.start)
            agg.durationMs += clipped
            agg.msByCategory[row.category, default: 0] += clipped
            let source = row.domain
                ?? (row.appBundle.split(separator: ".").last.map(String.init) ?? row.appBundle)
            if !agg.sources.contains(source) { agg.sources.append(source) }
            if let topic = row.topic, !agg.topics.contains(topic) { agg.topics.append(topic) }
            agg.spans.append((max(row.startedAt, day.start), min(row.endedAt, day.end)))
            let evidence = fetched.evidenceByID[row.id] ?? ActivityEvidence()
            agg.entries.append(HashEntry(
                startedAt: row.startedAt, endedAt: row.endedAt, evidenceHash: evidence.hash))
            if !evidence.isEmpty {
                agg.evidence.append(EvidenceItem(
                    startedAt: max(row.startedAt, day.start), durationMs: clipped,
                    appBundle: row.appBundle, evidence: evidence))
            }
            perTask[row.taskID] = agg
        }
        return (perTask, order)
    }

    /// Builds the day's pending notes: aggregates per task, computes the
    /// content hash, and decides prose carry-over vs regeneration.
    ///
    /// `narration` decides whether a changed day's prose is queued or
    /// deferred (see `Narration`). A deferred day carries the old prose *and
    /// the old hash*, so it still reads "changed" to whichever later pass is
    /// allowed to regenerate. Writing the new hash here would be the silent
    /// failure — the deferred regeneration would look already-done and never
    /// happen.
    static func gather(
        day: (start: Int64, end: Int64), database: ShifuDatabase, vault: VaultStore,
        calendar: Calendar, minMs: Int64, narration: Narration = .now
    ) throws -> [Pending] {
        let fetched = try fetchDay(day: day, database: database)
        guard !fetched.rows.isEmpty else { return [] }
        let (perTask, order) = aggregate(fetched, day: day)

        let dayStr = dayString(day.start, calendar: calendar)
        let times = timeFormatter(calendar)
        return order.compactMap { taskID in
            guard let agg = perTask[taskID] else { return nil }
            let hash = contentHash(entries: agg.entries)
            let old = vault.workNote(day: dayStr, taskKey: agg.taskKey)
            let tier = agg.tier
            let evidence = renderEvidence(agg.evidence, times: times)
            let substantial = agg.durationMs >= minMs && !evidence.isEmpty
            // Both prose sections carry on a hash match, not just the first.
            // Carrying only `sessionsProse` would silently delete `## Notes`
            // on every unchanged-day rebuild — and the hash gate would then
            // never regenerate it, because the day is by definition unchanged.
            //
            // A substantial day whose hash says "described" but which carries
            // no prose was never described: the hash is a receipt for prose,
            // so the two disagreeing means the receipt is wrong. Reading it
            // as changed is what heals the days blanked while a failed
            // narrative still stamped the hash — nothing else ever would,
            // because a completed day's evidence never changes again.
            let described = old?.sessionsProse?.isEmpty == false
            let unchanged = old?.contentHash == hash && (described || !substantial)
            let mayNarrate = narration == .now || (narration == .missingOnly && !described)
            let deferred = !unchanged && !mayNarrate
            // A day that has earned prose this pass is in exactly the same
            // position as a deferred one until that prose exists: the old
            // text is the best record there is, and the old hash is what
            // keeps the day eligible. Writing the new hash here was the
            // silent failure — a narrative that then failed left the day
            // stamped as described and its previous prose deleted, and
            // because a *completed* day's evidence never changes again, it
            // could never be retried. Three of the densest days in the
            // dogfood vault lost their notes that way.
            let owed = !unchanged && substantial && mayNarrate
            let carry = unchanged || deferred || owed
            let note = WorkNote(
                id: old?.id ?? Note.ulid(),
                taskKey: agg.taskKey,
                taskName: agg.taskName,
                day: dayStr,
                durationMs: agg.durationMs,
                sources: agg.sources,
                sessions: sessions(from: agg.spans, formatter: times),
                contentHash: deferred || owed ? (old?.contentHash ?? 0) : hash,
                summary: TaskGrouper.summaryLine(sources: agg.sources, topics: agg.topics),
                sessionsProse: carry ? old?.sessionsProse : nil,
                detailProse: carry ? old?.detailProse : nil,
                capturedLinks: wikiLinks(fetched.linksByTask[taskID] ?? []))
            return Pending(note: note, freshHash: hash, needsNarrative: owed,
                           tier: tier, evidence: evidence)
        }
    }

    /// Removes work notes for the day whose task no longer has activities —
    /// only deletions and task merges produce these.
    static func cleanupStale(
        day: (start: Int64, end: Int64), keeping: Set<String>, vault: VaultStore,
        calendar: Calendar
    ) throws {
        let dayStr = dayString(day.start, calendar: calendar)
        for file in vault.workNoteFiles(day: dayStr) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let note = WorkNote.parse(text) else { continue }
            if !keeping.contains(note.taskKey) {
                try vault.deleteWork(at: file, noteID: note.id)
            }
        }
    }

}

// MARK: - Helpers

extension WorkNoteCompiler {
    /// Hash of the sorted (span + evidence hash) entries: the regeneration
    /// gate. Order-independent, and stable across LedgerBuilder's
    /// delete-and-reinsert rebuilds — see HashEntry.
    static func contentHash(entries: [HashEntry]) -> Int64 {
        let joined = entries
            .sorted { ($0.startedAt, $0.endedAt) < ($1.startedAt, $1.endedAt) }
            .map { "\($0.startedAt)-\($0.endedAt):\($0.evidenceHash)" }
            .joined(separator: ";")
        return VaultIndexer.contentHash(joined)
    }

    /// Contiguous activity runs, split where the gap exceeds `sessionGapMs`.
    static func sessions(
        from spans: [(start: Int64, end: Int64)], formatter: DateFormatter
    ) -> [WorkNote.Session] {
        let sorted = spans.sorted { $0.start < $1.start }
        var runs: [(start: Int64, end: Int64)] = []
        for span in sorted {
            if var last = runs.last, span.start - last.end <= sessionGapMs {
                last.end = max(last.end, span.end)
                runs[runs.count - 1] = last
            } else {
                runs.append(span)
            }
        }
        return runs.map { run in
            WorkNote.Session(
                start: formatter.string(from: Date(timeIntervalSince1970: Double(run.start) / 1_000)),
                end: formatter.string(from: Date(timeIntervalSince1970: Double(run.end) / 1_000)))
        }
    }

    static func wikiLinks(_ paths: [String]) -> [String] {
        paths.compactMap { path in
            let base = path.split(separator: "/").last.map(String.init) ?? path
            guard base.hasSuffix(".md") else { return nil }
            return String(base.dropLast(3))
        }
    }

    static func minDurationMs(database: ShifuDatabase) -> Int64 {
        let raw = (try? Settings.get(minMinutesKey, database: database)) ?? nil
        let minutes = raw.flatMap(Int64.init) ?? Int64(defaultMinMinutes)
        return minutes * 60_000
    }

    static func dayString(_ dayStartMs: Int64, calendar: Calendar) -> String {
        formatter("yyyy-MM-dd", calendar: calendar)
            .string(from: Date(timeIntervalSince1970: Double(dayStartMs) / 1_000))
    }

    static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        formatter("HH:mm", calendar: calendar)
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let result = DateFormatter()
        result.dateFormat = format
        result.timeZone = calendar.timeZone
        return result
    }
}

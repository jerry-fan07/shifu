import Foundation
import GRDB

/// Compiles work notes (vault-features.md §2.1): one Markdown note per
/// (task, local day), rebuilt idempotently like `TaskGrouper.rebuildLogs`.
/// Deterministic parts are always rewritten; the LLM `## Sessions` prose is
/// regenerated only when the day's underlying activities changed
/// (content-hash gate), so re-analysis never burns tokens on unchanged days.
///
/// Inputs are non-private `activities` rows and their activities' redacted
/// text samples — the same rows KnowledgeExtractor reads; never anything
/// upstream of the redaction choke point.
public enum WorkNoteCompiler {
    /// What one `run` did. `narrativesGenerated` is the count that cost tokens;
    /// `notesWritten` includes notes whose deterministic parts were rewritten
    /// while their prose carried over unchanged, so the two differ by design.
    public struct Summary: Equatable, Sendable {
        public var notesWritten: Int
        public var narrativesGenerated: Int

        public init(notesWritten: Int = 0, narrativesGenerated: Int = 0) {
            self.notesWritten = notesWritten
            self.narrativesGenerated = narrativesGenerated
        }
    }

    /// Substance threshold (vault-features.md §2.1): task-days shorter than
    /// this (or with no text samples) get no narrative — a 45-second glance
    /// at a dashboard does not earn a paragraph.
    public static let minMinutesKey = "worknotes.min_minutes"
    static let defaultMinMinutes = 10

    /// Gap that splits a task's day into separate sessions. Wider than the
    /// sessionizer's 2-minute block gap on purpose: switching apps shouldn't
    /// fragment the story, a lunch break should.
    static let sessionGapMs: Int64 = 15 * 60_000
    static let narrativeResponseTokens = 400
    static let sampleCharsPerActivity = 800

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

        /// Evidence per activity. A document has to say what actually
        /// happened, which the light tier's 800 chars can't support; a light
        /// day's handful of bullets doesn't need more.
        var sampleChars: Int {
            switch self {
            case .light: return WorkNoteCompiler.sampleCharsPerActivity
            case .detailed: return WorkNoteCompiler.detailedSampleChars
            }
        }
    }

    static let detailedResponseTokens = 1_200
    static let detailedSampleChars = 2_000
    /// The categories that earn the detailed tier.
    static let detailCategories: Set<Category> = [.work, .learning]

    struct Pending {
        var note: WorkNote
        var needsNarrative: Bool
        var tier: Tier
        var samples: String
    }

    // MARK: - Entry points

    /// Full analyzer pass: compile every (task, day) the window touches.
    /// Runs after TaskGrouper (so `activities.task_id` is assigned) and after
    /// KnowledgeExtractor (so the day's knowledge notes are indexed for
    /// `## Captured`). Works without a backend — notes ship deterministic-only.
    ///
    /// `regenerateOpenDay: false` throttles the one day still in progress
    /// (the day containing `to`): an actively-worked task's hash changes on
    /// every hourly pass, so without the throttle its narrative re-bills up
    /// to ~14×/day to describe an afternoon that isn't over. Completed days
    /// keep the pure hash gate either way, so end-of-day prose is never
    /// skipped — the throttled day just reads a few hours stale until the
    /// caller's gate (main.swift, `LLMStageGate`) opens or the day completes.
    @discardableResult
    public static func run(
        database: ShifuDatabase, vault: VaultStore, backend: (any LLMBackend)?,
        from: Int64, to: Int64, regenerateOpenDay: Bool = true,
        calendar: Calendar = .current
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
            let pendings = try gather(
                day: day, database: database, vault: vault, calendar: calendar,
                minMs: minMs, throttleNarratives: !regenerateOpenDay && day.end > to)
            for var pending in pendings {
                if pending.needsNarrative, let backend,
                   let prose = try? await narrative(for: pending, backend: backend),
                   !prose.sessions.isEmpty {
                    pending.note.sessionsProse = prose.sessions
                    pending.note.detailProse = prose.detail
                    summary.narrativesGenerated += 1
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
    }

    /// Stable identity of one activity for the regeneration gate. Never row
    /// ids: LedgerBuilder's idempotent rebuild recreates the window's rows
    /// with fresh ids every run, but the spans and text are reproduced
    /// byte-identically — so span + sample hash is what "unchanged" means.
    struct HashEntry {
        var startedAt: Int64
        var endedAt: Int64
        var sampleHash: Int64
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
        var samples: [String] = []
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
        var samplesByID: [Int64: String]
        var linksByTask: [Int64: [String]]
    }

    /// One read: the day's task activities, their redacted text samples, and
    /// the day's indexed knowledge notes per task (for `## Captured`).
    private static func fetchDay(
        day: (start: Int64, end: Int64), database: ShifuDatabase
    ) throws -> Fetched {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.task_id, a.started_at, a.ended_at, a.app_bundle,
                       a.domain, a.topic, a.category, t.key AS task_key, t.name AS task_name
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
                    taskKey: row["task_key"], taskName: row["task_name"])
            }
            // Fetched at the detailed tier's size regardless of what the day
            // turns out to be: the tier isn't known until the rows are folded,
            // and a light day's prompt just truncates what it takes. Hashing
            // the *full* sample is the better gate anyway — it notices changes
            // in text a light prompt never sees.
            var samples: [Int64: String] = [:]
            for row in rows {
                // Ordered by id, not `started_at`: id order is what the
                // `idx_observations_session` walk already returns, so this
                // states today's bytes rather than changing them — every
                // work note's `contentHash` is a hash of these samples, and
                // a different order would re-hash all 400-odd of them and
                // re-bill their prose. It has to be *stated*, though: the
                // prompt's cacheable prefix is now these bytes (see
                // `WorkNoteCompiler.rules`), and an unordered query is a
                // silent licence for SQLite to break it later.
                let texts = try String.fetchAll(db, sql: """
                    SELECT text FROM observations
                    WHERE session_id = ? AND text IS NOT NULL ORDER BY id LIMIT 8
                    """, arguments: [row.id])
                if !texts.isEmpty {
                    samples[row.id] = String(
                        texts.joined(separator: "\n").prefix(detailedSampleChars))
                }
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
            return Fetched(rows: rows, samplesByID: samples, linksByTask: links)
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
            let sample = fetched.samplesByID[row.id]
            agg.entries.append(HashEntry(
                startedAt: row.startedAt, endedAt: row.endedAt,
                sampleHash: sample.map(VaultIndexer.contentHash) ?? 0))
            if let sample { agg.samples.append(sample) }
            perTask[row.taskID] = agg
        }
        return (perTask, order)
    }

    /// Builds the day's pending notes: aggregates per task, computes the
    /// content hash, and decides prose carry-over vs regeneration.
    ///
    /// `throttleNarratives` defers a changed day's prose instead of queueing
    /// it: the old prose *and the old hash* carry over, so the note still
    /// reads "changed" to whichever later pass is allowed to regenerate.
    /// Writing the new hash here would be the silent failure — the throttled
    /// regeneration would look already-done and never happen.
    static func gather(
        day: (start: Int64, end: Int64), database: ShifuDatabase, vault: VaultStore,
        calendar: Calendar, minMs: Int64, throttleNarratives: Bool = false
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
            // Both prose sections carry on a hash match, not just the first.
            // Carrying only `sessionsProse` would silently delete `## Notes`
            // on every unchanged-day rebuild — and the hash gate would then
            // never regenerate it, because the day is by definition unchanged.
            let unchanged = old?.contentHash == hash
            let deferred = !unchanged && throttleNarratives
            let tier = agg.tier
            let samples = agg.samples
                .map { String($0.prefix(tier.sampleChars)) }
                .joined(separator: "\n---\n")
            let note = WorkNote(
                id: old?.id ?? Note.ulid(),
                taskKey: agg.taskKey,
                taskName: agg.taskName,
                day: dayStr,
                durationMs: agg.durationMs,
                sources: agg.sources,
                sessions: sessions(from: agg.spans, formatter: times),
                contentHash: deferred ? (old?.contentHash ?? 0) : hash,
                summary: TaskGrouper.summaryLine(sources: agg.sources, topics: agg.topics),
                sessionsProse: unchanged || deferred ? old?.sessionsProse : nil,
                detailProse: unchanged || deferred ? old?.detailProse : nil,
                capturedLinks: wikiLinks(fetched.linksByTask[taskID] ?? []))
            let substantial = agg.durationMs >= minMs && !samples.isEmpty
            return Pending(note: note,
                           needsNarrative: !unchanged && substantial && !throttleNarratives,
                           tier: tier, samples: samples)
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
    /// Hash of the sorted (span + text-sample hash) entries: the regeneration
    /// gate. Order-independent, and stable across LedgerBuilder's
    /// delete-and-reinsert rebuilds — see HashEntry.
    static func contentHash(entries: [HashEntry]) -> Int64 {
        let joined = entries
            .sorted { ($0.startedAt, $0.endedAt) < ($1.startedAt, $1.endedAt) }
            .map { "\($0.startedAt)-\($0.endedAt):\($0.sampleHash)" }
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

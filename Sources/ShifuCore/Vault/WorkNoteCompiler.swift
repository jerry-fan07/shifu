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

    struct Pending {
        var note: WorkNote
        var needsNarrative: Bool
        var samples: String
    }

    // MARK: - Entry points

    /// Full analyzer pass: compile every (task, day) the window touches.
    /// Runs after TaskGrouper (so `activities.task_id` is assigned) and after
    /// KnowledgeExtractor (so the day's knowledge notes are indexed for
    /// `## Captured`). Works without a backend — notes ship deterministic-only.
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
            let pendings = try gather(day: day, database: database, vault: vault,
                                      calendar: calendar, minMs: minMs)
            for var pending in pendings {
                if pending.needsNarrative, let backend,
                   let prose = try? await narrative(for: pending, backend: backend),
                   !prose.isEmpty {
                    pending.note.sessionsProse = prose
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
        var taskKey: String
        var taskName: String
        var projectName: String?
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
        var projectName: String?
        var durationMs: Int64 = 0
        var sources: [String] = []
        var topics: [String] = []
        var spans: [(start: Int64, end: Int64)] = []
        var entries: [HashEntry] = []
        var samples: [String] = []
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
                       a.domain, a.topic, t.key AS task_key, t.name AS task_name,
                       p.name AS project_name
                FROM activities a
                JOIN tasks t ON t.id = a.task_id
                LEFT JOIN projects p ON p.id = t.project_id
                WHERE a.ended_at > ? AND a.started_at < ? AND a.category != 'private'
                ORDER BY a.started_at
                """, arguments: [day.start, day.end]
            ).map { row in
                ActivityRow(
                    id: row["id"], taskID: row["task_id"],
                    startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"],
                    topic: row["topic"], taskKey: row["task_key"],
                    taskName: row["task_name"], projectName: row["project_name"])
            }
            var samples: [Int64: String] = [:]
            for row in rows {
                let texts = try String.fetchAll(db, sql: """
                    SELECT text FROM observations
                    WHERE session_id = ? AND text IS NOT NULL LIMIT 4
                    """, arguments: [row.id])
                if !texts.isEmpty {
                    samples[row.id] = String(
                        texts.joined(separator: "\n").prefix(sampleCharsPerActivity))
                }
            }
            var links: [Int64: [String]] = [:]
            for taskID in Set(rows.map(\.taskID)) {
                links[taskID] = try String.fetchAll(db, sql: """
                    SELECT path FROM vault_index
                    WHERE kind = 'knowledge' AND task_id = ?
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
                    taskID: row.taskID, taskKey: row.taskKey,
                    taskName: row.taskName, projectName: row.projectName)
            }
            var agg = perTask[row.taskID]!
            agg.durationMs += min(row.endedAt, day.end) - max(row.startedAt, day.start)
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
    static func gather(
        day: (start: Int64, end: Int64), database: ShifuDatabase, vault: VaultStore,
        calendar: Calendar, minMs: Int64
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
            let carried = old?.contentHash == hash ? old?.sessionsProse : nil
            let samples = agg.samples.joined(separator: "\n---\n")
            let note = WorkNote(
                id: old?.id ?? Note.ulid(),
                taskKey: agg.taskKey,
                taskName: agg.taskName,
                day: dayStr,
                durationMs: agg.durationMs,
                sources: agg.sources,
                sessions: sessions(from: agg.spans, formatter: times),
                project: agg.projectName.map(TaskGrouper.slug),
                contentHash: hash,
                summary: TaskGrouper.summaryLine(sources: agg.sources, topics: agg.topics),
                sessionsProse: carried,
                capturedLinks: wikiLinks(fetched.linksByTask[taskID] ?? []))
            let substantial = agg.durationMs >= minMs && !samples.isEmpty
            return Pending(note: note,
                           needsNarrative: old?.contentHash != hash && substantial,
                           samples: samples)
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

    // MARK: - Narrative (LLM, optional — vault-features.md §2.1)

    static func prompt(taskName: String, day: String,
                       sessions: [WorkNote.Session], samples: String) -> String {
        let spans = sessions.map { "\($0.start)–\($0.end)" }.joined(separator: ", ")
        return """
        Summarize one day (\(day)) of work on the task "\(taskName)".
        Session times: \(spans)
        Write 1-3 markdown bullets, each formatted
        "**HH:MM–HH:MM** — what happened, what was accomplished."
        Use ONLY the screen-text samples below as evidence. Respond with ONLY the bullets.

        Screen-text samples:
        \(samples)
        """
    }

    /// One prompt per task-day, sized to the backend's window (invariant 7):
    /// samples are truncated rather than the day split — quality over
    /// coverage, the deterministic line 1 always exists.
    static func narrative(for pending: Pending, backend: any LLMBackend) async throws -> String {
        var samples = pending.samples
        var text = prompt(taskName: pending.note.taskName, day: pending.note.day,
                          sessions: pending.note.sessions, samples: samples)
        while !samples.isEmpty,
              LLMTokens.estimate(text) + narrativeResponseTokens > backend.contextWindowTokens {
            samples = String(samples.prefix(samples.count * 2 / 3))
            text = prompt(taskName: pending.note.taskName, day: pending.note.day,
                          sessions: pending.note.sessions, samples: samples)
        }
        let response = try await backend.complete(prompt: text, maxTokens: narrativeResponseTokens)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
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

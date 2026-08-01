import Foundation
import GRDB

/// Compiles the per-task overview document (vault-features.md §2.1): one
/// living Markdown file per task, replaced wholesale each time the task's
/// completed days change.
///
/// The day notes are the diary; this is the documentation. A task that ran
/// for three weeks has twenty day notes and no single place that says what it
/// *is* — what state it's in, what was learned along the way, what is still
/// open. That is what this file answers, and why it is a complete replacement
/// rather than an append: the answer changes as the task goes on.
///
/// Only *completed* days feed the hash, so today's still-growing note can't
/// trigger a regeneration on every hourly run — at most one per task per day
/// (the discipline `ThemeClusterer.refreshNarratives` uses).
public enum TaskOverviewCompiler {
    /// An overview is prose over up to `maxDayNotes` days, not a JSON verdict,
    /// so it is the longest answer any stage asks for. 1,500 was never enough
    /// — a real task cut off at 6,925 characters mid-sentence — and it went
    /// unnoticed because the backend used to raise every call to 16k of
    /// thinking headroom, and because a truncated reply was returned as if it
    /// had succeeded rather than raised.
    public static let responseTokens = 3_000
    public static let maxDayNotes = 30
    /// Tasks per run. The gate below means a steady state is a handful, but a
    /// first run over a mature vault would otherwise generate for everything
    /// at once.
    public static let maxTasksPerRun = 6
    public static let minTotalMinutes = 30

    public struct Summary: Equatable, Sendable {
        public var written: Int

        public init(written: Int = 0) { self.written = written }
    }

    /// One eligible task and the notes its overview is compiled from.
    struct Candidate {
        var taskKey: String
        var taskName: String
        var gist: String?
        var days: [DayNote]
        var inputHash: Int64
    }

    struct DayNote {
        var day: String
        var summary: String
        var sessionsProse: String?
        var detailProse: String?

        /// What the prompt sees — the deterministic line plus whatever prose
        /// the day earned.
        var rendered: String {
            var text = "### \(day)\n\(summary)"
            if let sessionsProse, !sessionsProse.isEmpty { text += "\n\(sessionsProse)" }
            if let detailProse, !detailProse.isEmpty { text += "\n\(detailProse)" }
            return text
        }
    }

    // MARK: - Prompt (pure, testable)

    /// Assembled back-to-front for the same reason as the day-note prompt
    /// (`WorkNoteNarrative.rules`): DeepSeek bills the cache rate only for the
    /// byte-identical *prefix* a request shares with a recent one, so the day
    /// notes — which only ever gain an entry at the end — have to sit above
    /// everything that moves. They used to sit below both the task name and
    /// `previous`, and `previous` is by construction a different document on
    /// every single call, so nothing here ever cached: 9 of 10 measured calls
    /// came back at exactly zero.
    ///
    /// `previous` still lands last, but the rewrite instruction lands after
    /// it. A prior draft immediately before generation is a standing
    /// invitation to reproduce it verbatim, which is the one thing this stage
    /// must not do — so the final thing the model reads is the order to
    /// replace it, not the thing being replaced.
    static func prompt(
        taskName: String, gist: String?, previous: String?, days: [DayNote]
    ) -> String {
        let intro = gist.map { "What it is about: \($0)\n" } ?? ""
        let prior = previous.map {
            "\nThe current overview, to revise:\n\($0)\n"
        } ?? "\nThere is no current overview yet; write the first one.\n"
        return """
        Maintain the living overview document for one task, from its day notes.
        Write the document as a complete replacement, not an addition — it is rewritten
        in full every time, so restate whatever still holds and drop whatever no longer
        does.
        Documentation, not a diary: the day notes below are already the diary. Say what
        this task *is*, where it stands, and what someone would need to know to pick it
        up. No flashcards, no quiz questions.
        Use these sections, in this order, omitting any you have nothing real to say for:
        "## Status" — 2-4 sentences: where the task stands right now.
        "## Timeline" — bullets of the phases it went through, not a day-by-day replay.
        "## Key knowledge" — what was learned that outlives the task, with the why.
        "## Open threads" — what is unfinished, unanswered, or waiting.
        Use ONLY the day notes and the current overview as evidence. Respond with ONLY the document.

        Day notes, oldest first:
        \(days.map(\.rendered).joined(separator: "\n\n"))

        The task: "\(taskName)"
        \(intro)\(prior)
        Now rewrite it in full, as a complete replacement: restate what still holds,
        drop what no longer does, and never copy the draft above back verbatim.
        """
    }

    // MARK: - Selection

    /// Tasks that have earned an overview and whose completed days changed
    /// since the last one. Eligibility mirrors the day-note tier rule —
    /// dominant category work or learning — so the tasks with documentation
    /// worth compiling are exactly the ones whose days are documented.
    static func candidates(
        database: ShifuDatabase, vault: VaultStore, now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [Candidate] {
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        let eligible = try eligibleTasks(database: database, todayStart: todayStart)

        return eligible.compactMap { task in
            let days = dayNotes(for: task, vault: vault, calendar: calendar)
            guard !days.isEmpty else { return nil }
            let hash = VaultIndexer.contentHash(days.map(\.rendered).joined(separator: "\n"))
            // Unchanged completed days ⇒ the document would say the same
            // thing, so it isn't worth a call (ThemeClusterer discipline).
            guard vault.taskOverview(taskKey: task.key)?.inputHash != hash else { return nil }
            return Candidate(taskKey: task.key, taskName: task.name, gist: task.gist,
                             days: days, inputHash: hash)
        }
    }

    struct EligibleTask {
        var key: String
        var name: String
        var gist: String?
        var days: [String]      // "YYYY-MM-DD", oldest first, completed only
    }

    /// Tasks with enough logged time whose dominant category is work or
    /// learning, most recently active first, with their completed day strings.
    static func eligibleTasks(
        database: ShifuDatabase, todayStart: Int64
    ) throws -> [EligibleTask] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.key, t.name, t.gist, a.category,
                       SUM(a.ended_at - a.started_at) AS ms,
                       MAX(t.last_active_at) AS last_active
                FROM tasks t JOIN activities a ON a.task_id = t.id
                WHERE a.category != 'private'
                GROUP BY t.key, a.category
                """)
            struct Agg {
                var name = ""
                var gist: String?
                var lastActive: Int64 = 0
                var msByCategory: [String: Int64] = [:]
                var totalMs: Int64 = 0
            }
            var byTask: [String: Agg] = [:]
            for row in rows {
                let key: String = row["key"]
                var agg = byTask[key] ?? Agg()
                agg.name = row["name"]
                agg.gist = row["gist"]
                agg.lastActive = max(agg.lastActive, row["last_active"] as Int64)
                let ms: Int64 = row["ms"]
                agg.msByCategory[row["category"], default: 0] += ms
                agg.totalMs += ms
                byTask[key] = agg
            }
            let minMs = Int64(minTotalMinutes) * 60_000
            let ordered = byTask
                .filter { $0.value.totalMs >= minMs && isFocusDominant($0.value.msByCategory) }
                .sorted { $0.value.lastActive > $1.value.lastActive }
                .prefix(maxTasksPerRun)

            return try ordered.map { key, agg in
                let days = try String.fetchAll(db, sql: """
                    SELECT DISTINCT l.day_start FROM task_logs l JOIN tasks t ON t.id = l.task_id
                    WHERE t.key = ? AND l.day_start < ? ORDER BY l.day_start DESC LIMIT ?
                    """, arguments: [key, todayStart, maxDayNotes])
                return EligibleTask(key: key, name: agg.name, gist: agg.gist,
                                    days: days.reversed())
            }
        }
    }

    /// Shared with `DeckSuggester` in spirit, restated here on raw category
    /// strings because that is what the grouped query returns.
    static func isFocusDominant(_ msByCategory: [String: Int64]) -> Bool {
        guard let dominant = msByCategory.max(by: { $0.value < $1.value })?.key else { return false }
        return dominant == Category.work.rawValue || dominant == Category.learning.rawValue
    }

    private static func dayNotes(
        for task: EligibleTask, vault: VaultStore, calendar: Calendar
    ) -> [DayNote] {
        task.days.compactMap { dayMs in
            guard let ms = Int64(dayMs) else { return nil }
            let day = WorkNoteCompiler.dayString(ms, calendar: calendar)
            guard let note = vault.workNote(day: day, taskKey: task.key) else { return nil }
            return DayNote(day: day, summary: note.summary,
                           sessionsProse: note.sessionsProse, detailProse: note.detailProse)
        }
    }

    // MARK: - Run

    @discardableResult
    public static func run(
        database: ShifuDatabase, vault: VaultStore, backend: any LLMBackend,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Summary {
        var summary = Summary()
        for candidate in try candidates(database: database, vault: vault,
                                        now: now, calendar: calendar) {
            let previous = vault.taskOverview(taskKey: candidate.taskKey)
            // Prose, like the day notes: an overview that outgrows its
            // reserve keeps whatever whole lines it wrote. This document is
            // a *replacement*, so throwing the answer away leaves the task
            // showing the previous one until the next change — and this
            // stage has been bitten by silent truncation before (see
            // `responseTokens`).
            let body = try await backend.completeProse(
                prompt: budgeted(candidate, previous: previous?.body, backend: backend),
                maxTokens: responseTokens
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            try vault.saveOverview(TaskOverview(
                id: previous?.id ?? Note.ulid(),
                taskKey: candidate.taskKey, taskName: candidate.taskName,
                updated: now, inputHash: candidate.inputHash, body: body))
            summary.written += 1
        }
        return summary
    }

    /// Sized to the backend's window (invariant 7): drop the oldest days
    /// rather than fail. The recent ones say where the task stands, which is
    /// the question the document mostly answers.
    static func budgeted(
        _ candidate: Candidate, previous: String?, backend: any LLMBackend
    ) -> String {
        var days = candidate.days
        func render() -> String {
            prompt(taskName: candidate.taskName, gist: candidate.gist,
                   previous: previous, days: days)
        }
        var text = render()
        while days.count > 1,
              LLMTokens.estimate(text) + backend.responseReserve(responseTokens)
                > backend.contextWindowTokens {
            days.removeFirst()
            text = render()
        }
        return text
    }
}

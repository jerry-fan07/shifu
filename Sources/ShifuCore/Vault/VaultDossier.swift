import Foundation
import GRDB

/// Everything Shifu knows about one note — the answer to "I remember this,
/// but what *was* it?".
///
/// A note on its own is a paragraph with a date on it. What makes the vault a
/// memory rather than a folder is the second question the reader always asks
/// next: which effort was this, what was I doing around it, what else came out
/// of that stretch of time. So opening a note reads its collections too — the
/// task it belongs to and that task's living overview, the other notes from
/// the same day, the note before and after it in the same effort, the cards it
/// captured (or the day that captured it), and, while the raw blocks are still
/// inside the retention window (design.md §3.5), the exact apps and minutes
/// underneath.
///
/// One read, off the Markdown file plus the index. Nothing here is stored: a
/// dossier is recomputed on open, so it can never drift from the tree.
extension VaultLibrary {

    /// The wall-clock stretches behind a note. For a work note these are read
    /// straight from its `sessions:` frontmatter, which is written for a human
    /// and outlives the raw blocks by design (vault-features.md §7).
    public struct Stretch: Identifiable, Sendable, Hashable {
        public var start: String        // "HH:MM", local
        public var end: String

        public var id: String { "\(start)-\(end)" }
    }

    public struct Dossier: Sendable {
        public var entry: Entry
        /// The note's Markdown body, as written. Nil when the file has gone
        /// since it was indexed — the next reconcile drops the row.
        public var body: String?
        public var stretches: [Stretch]
        /// Apps and domains the day was spent in, from the note's frontmatter.
        public var sources: [String]

        /// The task's living overview document (§2.1b) — the one page that
        /// says what this effort *is*, as opposed to what one day of it was.
        public var overview: Entry?
        /// Total time and days logged against the task, so a single day's
        /// note can say what share of the effort it was.
        public var taskTotalMs: Int64
        public var taskDayCount: Int

        /// The same effort's notes around this one, newest first — the
        /// timeline a single day is a point on.
        public var timeline: [Entry]
        /// Everything else captured on this note's local day, across tasks:
        /// what else was going on when this memory was made.
        public var sameDay: [Entry]
        /// Notes this one links to (`## Captured`), or — for a card — the work
        /// note of the day that captured it. The collection either way.
        public var related: [Entry]
        /// The raw blocks underneath, if the day is still inside the
        /// observation retention window. Empty for older notes, which is not
        /// an error: the note is the durable record, the blocks are not.
        public var blocks: [TaskStore.ActivityLine]
    }

    /// Reads one note's full context. Nil when the id isn't in the index.
    public static func dossier(
        noteID: String, database: ShifuDatabase, vault: VaultStore,
        calendar: Calendar = .current
    ) throws -> Dossier? {
        guard let entry = try entry(noteID: noteID, database: database) else { return nil }
        let file = vault.root.appendingPathComponent(entry.path)
        let text = try? String(contentsOf: file, encoding: .utf8)
        let document = text.flatMap(FrontMatter.parse)
        let day = dayBounds(of: entry, document: document, calendar: calendar)

        var dossier = Dossier(
            entry: entry,
            body: document?.body,
            stretches: stretches(of: document),
            sources: document?.fields["sources"].map(WorkNote.parseInlineList) ?? [],
            taskTotalMs: 0,
            taskDayCount: 0,
            timeline: [],
            sameDay: [],
            related: [],
            blocks: [])

        if let taskID = entry.taskID {
            let totals = try taskTotals(taskID: taskID, database: database)
            dossier.taskTotalMs = totals.ms
            dossier.taskDayCount = totals.days
            dossier.overview = try shelf(
                filter: Filter(kind: .taskOverview, taskID: taskID, limit: 1),
                database: database).first
            dossier.timeline = try shelf(
                filter: Filter(kind: .work, taskID: taskID, limit: 60), database: database)
                .filter { $0.noteID != entry.noteID }
        }
        if let day {
            // Biggest first, not newest: within a single day "what took the
            // most of it" is the useful order, and every one of these shares
            // the same local-midnight capture instant anyway, so recency
            // sorts them arbitrarily.
            dossier.sameDay = try shelf(
                filter: Filter(since: day.start, until: day.end, limit: 40),
                database: database)
                .filter { $0.noteID != entry.noteID && $0.kind != .taskOverview }
                .sorted { ($0.durationMs ?? 0, $0.noteID) > ($1.durationMs ?? 0, $1.noteID) }
            dossier.blocks = try blocks(
                taskID: entry.taskID, day: day, database: database)
        }
        dossier.related = try related(
            entry: entry, document: document, day: day, database: database)
        return dossier
    }

    // MARK: - Pieces

    /// The local day a note belongs to. Work notes carry `day:` outright;
    /// everything else is placed by its capture instant.
    static func dayBounds(
        of entry: Entry, document: FrontMatter.Document?, calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let anchor = document?.fields["day"].flatMap(dayFormatter(calendar).date(from:))
            ?? entry.captured
        guard let anchor else { return nil }
        let start = calendar.startOfDay(for: anchor)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    static func stretches(of document: FrontMatter.Document?) -> [Stretch] {
        guard let raw = document?.fields["sessions"] else { return [] }
        return WorkNote.parseSessions(raw).map { Stretch(start: $0.start, end: $0.end) }
    }

    /// A note's collection: what it links to, or what links to it. A work note
    /// names the cards its day produced; a card carries no back-link of its
    /// own, so the day that captured it is found the same way the compiler
    /// filed it — by (task, day).
    static func related(
        entry: Entry, document: FrontMatter.Document?,
        day: (start: Date, end: Date)?, database: ShifuDatabase
    ) throws -> [Entry] {
        if let body = document?.body {
            let links = WorkNote.parseBody(body).links
            if !links.isEmpty {
                return try entries(linkTargets: links, database: database)
            }
        }
        guard entry.kind == .knowledge, let taskID = entry.taskID, let day else { return [] }
        return try shelf(
            filter: Filter(kind: .work, taskID: taskID,
                           since: day.start, until: day.end, limit: 2),
            database: database)
    }

    static func taskTotals(
        taskID: Int64, database: ShifuDatabase
    ) throws -> (ms: Int64, days: Int) {
        try database.queue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(duration_ms), 0) AS ms, COUNT(*) AS days
                FROM task_logs WHERE task_id = ?
                """, arguments: [taskID])
            return ((row?["ms"] as Int64?) ?? 0, (row?["days"] as Int?) ?? 0)
        }
    }

    /// The blocks behind the note: the note's own task if it has one, the
    /// whole day otherwise (a card's day is worth seeing in full — it is the
    /// context the card was torn out of).
    static func blocks(
        taskID: Int64?, day: (start: Date, end: Date), database: ShifuDatabase
    ) throws -> [TaskStore.ActivityLine] {
        let startMs = Int64(day.start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(day.end.timeIntervalSince1970 * 1_000)
        var conditions = ["a.ended_at > ?", "a.started_at < ?", "a.category != 'private'"]
        var arguments: [any DatabaseValueConvertible] = [startMs, endMs]
        if let taskID {
            conditions.append("a.task_id = ?")
            arguments.append(taskID)
        }
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.started_at, a.ended_at, a.app_bundle, a.domain,
                       a.topic, a.category
                FROM activities a
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY a.started_at
                LIMIT 200
                """, arguments: StatementArguments(arguments)
            ).map { row in
                let bundle: String = row["app_bundle"]
                return TaskStore.ActivityLine(
                    id: row["id"],
                    startedAt: row["started_at"],
                    endedAt: row["ended_at"],
                    source: (row["domain"] as String?)
                        ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle),
                    topic: row["topic"],
                    category: row["category"])
            }
        }
    }

    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}

import Foundation
import GRDB

/// The vault as a **library** rather than a search box (vault-features.md §4,
/// §6): every note the tree holds, browsable by kind, task, theme and date,
/// each row carrying the provenance that says where the memory came from.
///
/// The Notes place used to show a count of 21 — `VaultStore.allNotes()`, which
/// only parses `kind: knowledge` — over a tree of nearly seven hundred
/// documents, and drew nothing at all until you typed. What it did draw was
/// dominated by the work-note stub: `WorkNoteCompiler` writes one note per
/// (task, day) whatever happened, so a nine-second glance at arxiv.org leaves
/// a file whose entire body is the word "arxiv.org". Six hundred of the
/// dogfood vault's six hundred and fifty work notes are that shape.
///
/// So the library is built on three ideas:
///
/// 1. **Everything counts.** One row model (`Entry`) for all three kinds, read
///    from `vault_index` alone — no file opened until a note is actually read.
/// 2. **Depth is a first-class fact.** `Depth` grades a body by what it is
///    made of, so stubs can be ranked below, filtered out, or shown as the
///    thin receipts they are, instead of impersonating notes.
/// 3. **A note is never orphaned.** Every entry resolves its task, its theme,
///    and its day, which is what lets a half-remembered phrase lead back to
///    the exact stretch of time that produced it (`VaultLibrary.Dossier`).
public enum VaultLibrary {

    // MARK: - The row model

    /// How much of a document a note actually is. Derived from the body's
    /// shape rather than declared, so it survives an edit in Obsidian.
    public enum Depth: String, Sendable, Comparable {
        /// The deterministic "where — what" line and nothing else — the
        /// receipt for a stretch of time too short or too quiet to write up.
        case trace
        /// Prose: a card's Q/A, a day's session bullets.
        case note
        /// A compiled document — `## Notes`, or an overview's four sections.
        case document

        var rank: Int {
            switch self {
            case .trace: return 0
            case .note: return 1
            case .document: return 2
            }
        }

        public static func < (lhs: Depth, rhs: Depth) -> Bool { lhs.rank < rhs.rank }

        /// Two sections is the line between "the model said something" and
        /// "the model wrote it up": `## Sessions` alone is a paragraph of
        /// bullets, `## Sessions` + `## Notes` is the detailed tier
        /// (vault-features.md §2.1). The word floor catches knowledge cards,
        /// which are substantial and carry no headings at all.
        ///
        /// **Only a work note can be a trace.** The compiler writes one per
        /// (task, day) whatever happened, so a short body there means nothing
        /// happened. A card exists because the user asked for the deck and an
        /// overview because the task earned one — a terse one is still a thing
        /// somebody meant to have, and hiding it would be the same mistake in
        /// the other direction.
        static func of(kind: FrontMatter.Kind?, sections: Int, words: Int) -> Depth {
            if sections >= 2 || words >= 220 { return .document }
            if sections >= 1 || words >= 45 || kind != .work { return .note }
            return .trace
        }
    }

    /// One note as the library lists it: what it is, what it says, and where
    /// it came from. Read entirely from `vault_index` — the Markdown file is
    /// opened only when the note is read (`Dossier`).
    public struct Entry: Identifiable, Sendable, Hashable {
        public var noteID: String
        /// Relative to the vault root; `ShifuPaths.vault` + this is the file.
        public var path: String
        /// Nil when a newer binary wrote a kind this one doesn't know
        /// (vault-features.md §2) — `rawKind` still round-trips it.
        public var kind: FrontMatter.Kind?
        public var rawKind: String
        public var title: String
        /// Body line 1: the deterministic summary for a work note, the opening
        /// sentence for a card.
        public var summary: String
        /// When this is *about* — see `occurredSQL`. For a task overview that
        /// is the task's last activity, not the file's `updated:` stamp.
        public var captured: Date?
        /// The task-day's length, for work notes. Nil for everything else.
        public var durationMs: Int64?
        public var words: Int
        public var sections: Int
        public var taskID: Int64?
        public var taskKey: String?
        public var taskName: String?
        public var themeKey: String?
        public var themeName: String?
        public var deckKey: String?

        public var id: String { noteID }

        public var depth: Depth { Depth.of(kind: kind, sections: sections, words: words) }

        /// What the row calls this note. Kind is the honest answer for the two
        /// compiled kinds; a knowledge note is only ever a card now (§2.3).
        public var kindLabel: String {
            switch kind {
            case .work: return "work log"
            case .taskOverview: return "overview"
            case .knowledge: return deckKey == nil ? "captured" : "card"
            case nil: return rawKind
            }
        }

        public init(
            noteID: String, path: String, kind: FrontMatter.Kind?, rawKind: String,
            title: String, summary: String = "", captured: Date? = nil,
            durationMs: Int64? = nil, words: Int = 0, sections: Int = 0,
            taskID: Int64? = nil, taskKey: String? = nil, taskName: String? = nil,
            themeKey: String? = nil, themeName: String? = nil, deckKey: String? = nil
        ) {
            self.noteID = noteID
            self.path = path
            self.kind = kind
            self.rawKind = rawKind
            self.title = title
            self.summary = summary
            self.captured = captured
            self.durationMs = durationMs
            self.words = words
            self.sections = sections
            self.taskID = taskID
            self.taskKey = taskKey
            self.taskName = taskName
            self.themeKey = themeKey
            self.themeName = themeName
            self.deckKey = deckKey
        }
    }

    // MARK: - Browsing

    /// What the shelf is narrowed to. Every field is a facet the Notes page
    /// exposes, so a filter that can be expressed here is one the user can
    /// undo by looking at the page.
    public struct Filter: Sendable, Hashable {
        /// Nil admits every kind, including one a newer binary wrote.
        public var kind: FrontMatter.Kind?
        public var taskID: Int64?
        /// The same scope the task list narrows by, so "themed *Shifu*" means
        /// one thing in the app whichever page you say it on.
        public var themeScope: TaskStore.ThemeScope
        public var since: Date?
        public var until: Date?
        /// The floor a note's body must clear. `.trace` admits everything;
        /// the page defaults to `.note`, which is what hides six hundred
        /// one-line receipts without deleting them.
        public var minimumDepth: Depth
        public var limit: Int

        public init(
            kind: FrontMatter.Kind? = nil, taskID: Int64? = nil,
            themeScope: TaskStore.ThemeScope = .any,
            since: Date? = nil, until: Date? = nil,
            minimumDepth: Depth = .trace, limit: Int = 200
        ) {
            self.kind = kind
            self.taskID = taskID
            self.themeScope = themeScope
            self.since = since
            self.until = until
            self.minimumDepth = minimumDepth
            self.limit = limit
        }
    }

    /// How much the vault holds, by kind and by depth — the Notes head's line,
    /// and the numbers on its facet chips. Counted over the whole index, never
    /// over the current filter: a facet whose count moves when you use it
    /// can't tell you what turning it on would do.
    public struct Census: Sendable, Equatable {
        public var total = 0
        public var work = 0
        public var knowledge = 0
        public var overviews = 0
        /// Notes with a body past the trace floor — the honest "how much is
        /// actually written down" number.
        public var substantial = 0
        public var traces = 0

        public init() {}
    }

    public static func census(database: ShifuDatabase) throws -> Census {
        try database.queue.read { db in
            var census = Census()
            for row in try Row.fetchAll(db, sql: """
                SELECT kind, words, sections, COUNT(*) AS n
                FROM vault_index GROUP BY kind, words, sections
                """) {
                let count: Int = row["n"]
                let kind = FrontMatter.Kind(rawValue: row["kind"])
                census.total += count
                switch kind {
                case .work: census.work += count
                case .knowledge: census.knowledge += count
                case .taskOverview: census.overviews += count
                case nil: break
                }
                let depth = Depth.of(kind: kind, sections: row["sections"], words: row["words"])
                if depth == .trace { census.traces += count } else { census.substantial += count }
            }
            return census
        }
    }

    /// The shelf: notes matching `filter`, most recently captured first. This
    /// is what the Notes page shows *before* anything is typed — a library you
    /// can walk, which is the half the old page was missing entirely.
    public static func shelf(
        filter: Filter = Filter(), database: ShifuDatabase
    ) throws -> [Entry] {
        let scope = Scope(filter)
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                \(entrySQL)
                \(scope.whereClause)
                ORDER BY captured DESC, vi.note_id DESC
                LIMIT ?
                """, arguments: StatementArguments(scope.arguments + [filter.limit])
            ).map(entry(from:))
        }
    }

    /// One note by id — the route target, so a link into the library survives
    /// a rename or a move of the file behind it.
    public static func entry(noteID: String, database: ShifuDatabase) throws -> Entry? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: "\(entrySQL) WHERE vi.note_id = ?", arguments: [noteID])
                .map(entry(from:))
        }
    }

    /// Entries by path stem — how `## Captured` wiki-links resolve. Links are
    /// written without the `.md`, and the stem carries the ULID prefix, so a
    /// prefix match on `path` is exact without a second column.
    public static func entries(linkTargets: [String], database: ShifuDatabase) throws -> [Entry] {
        guard !linkTargets.isEmpty else { return [] }
        let clause = linkTargets.map { _ in "vi.path LIKE ?" }.joined(separator: " OR ")
        let patterns = linkTargets.map { "%\($0).md" }
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: "\(entrySQL) WHERE \(clause)",
                             arguments: StatementArguments(patterns)).map(entry(from:))
        }
    }

    // MARK: - SQL

    /// When the note is *about*, which for two of the three kinds is simply
    /// when it was captured.
    ///
    /// A task overview is the exception: it is rewritten in full every time
    /// the task moves (§2.1b), so its `updated:` is a build timestamp, not a
    /// date. Dating eleven overviews of months-old efforts "today" put them
    /// all at the head of the shelf under a *Today* heading — true of the
    /// file, false of the work. The task's last activity is the honest answer.
    static let occurredSQL = """
        (CASE WHEN vi.kind = 'task_overview'
              THEN COALESCE(t.last_active_at, vi.captured)
              ELSE vi.captured END)
        """

    /// Exactly what `entry(from:)` reads, so the two can't drift. Split from
    /// the joins because search selects these same columns alongside an FTS
    /// snippet and off a different driving table.
    static let entryColumns = """
        vi.note_id, vi.path, vi.kind, vi.title, vi.summary,
        \(occurredSQL) AS captured,
        vi.duration_ms, vi.words, vi.sections, vi.task_id, vi.task_key,
        vi.deck_key, t.name AS task_name,
        dt.theme_key AS theme_key, th.name AS theme_name
        """

    /// The task and its dominant theme. A task's theme is derived from its
    /// blocks, not stored (design.md §5.3), so the library resolves it the
    /// same way the task list does — one definition of "which theme is this",
    /// shared, and `Scope` filters on `dt.theme_key` because of it.
    static let entryJoins = """
        LEFT JOIN tasks t ON t.id = vi.task_id
        LEFT JOIN \(TaskStore.dominantThemeSQL) dt ON dt.task_id = vi.task_id AND dt.rank = 1
        LEFT JOIN themes th ON th.key = dt.theme_key
        """

    static let entrySQL = "SELECT \(entryColumns) FROM vault_index vi \(entryJoins)"

    /// A `Filter` as SQL. Shared by the shelf and by search's filtered ranking
    /// so the two can never admit different sets.
    struct Scope {
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        /// Whether any condition names a table `entryJoins` brings in.
        ///
        /// The vector scan (`VaultSearch.cosineHits`) is otherwise a bare walk
        /// of `vault_vectors` with no `LIMIT`, and hanging the dominant-theme
        /// window function off every row of it costs **49 ms against 0.5 ms**
        /// on the dogfood database — a hundred times the work of the thing it
        /// is filtering, on every keystroke. Unfiltered search is the common
        /// case, so it pays nothing.
        private(set) var needsJoins = false

        init(_ filter: Filter) {
            if let kind = filter.kind {
                conditions.append("vi.kind = ?")
                arguments.append(kind.rawValue)
            }
            if let taskID = filter.taskID {
                conditions.append("vi.task_id = ?")
                arguments.append(taskID)
            }
            switch filter.themeScope {
            case .any:
                break
            case .theme(let key):
                conditions.append("dt.theme_key = ?")
                arguments.append(key)
                needsJoins = true
            case .unassigned:
                conditions.append("dt.theme_key IS NULL")
                needsJoins = true
            }
            // Against `occurredSQL`, not `vi.captured`: a range filter that
            // disagreed with the date on the row would be the same bug in
            // reverse — an overview shown under June and excluded by "June".
            // It reads `tasks`, so it needs the joins too.
            if let since = filter.since {
                conditions.append("\(occurredSQL) >= ?")
                arguments.append(Int64(since.timeIntervalSince1970 * 1_000))
                needsJoins = true
            }
            if let until = filter.until {
                conditions.append("\(occurredSQL) < ?")
                arguments.append(Int64(until.timeIntervalSince1970 * 1_000))
                needsJoins = true
            }
            // Expressed against the stored columns rather than a computed
            // depth so it stays an indexable predicate — `Depth.of` and this
            // clause are the same rule written twice, which the depth tests
            // pin together.
            switch filter.minimumDepth {
            case .trace:
                break
            case .note:
                conditions.append(
                    "(vi.kind != 'work' OR vi.sections >= 1 OR vi.words >= 45)")
            case .document:
                conditions.append("(vi.sections >= 2 OR vi.words >= 220)")
            }
        }

        var whereClause: String {
            conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        }

        /// The same conditions for a query that already opened its `WHERE`.
        var andClause: String {
            conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")
        }
    }

    static func entry(from row: Row) -> Entry {
        let rawKind: String = row["kind"]
        return Entry(
            noteID: row["note_id"],
            path: row["path"],
            kind: FrontMatter.Kind(rawValue: rawKind),
            rawKind: rawKind,
            title: (row["title"] as String?) ?? "Untitled",
            summary: (row["summary"] as String?) ?? "",
            captured: (row["captured"] as Int64?).map(date),
            durationMs: row["duration_ms"],
            words: (row["words"] as Int?) ?? 0,
            sections: (row["sections"] as Int?) ?? 0,
            taskID: row["task_id"],
            taskKey: row["task_key"],
            taskName: row["task_name"],
            themeKey: row["theme_key"],
            themeName: row["theme_name"],
            deckKey: row["deck_key"])
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }
}

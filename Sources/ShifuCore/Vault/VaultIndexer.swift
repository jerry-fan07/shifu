import Foundation
import GRDB

/// Maintains the disposable SQLite search index over the vault's Markdown
/// tree (vault-features.md §4). Write-through from VaultStore keeps Shifu's
/// own writes indexed immediately; `reconcile` is the safety net that picks
/// up external edits (Obsidian, any editor) and deletions. Losing the index
/// loses nothing — `reconcile` rebuilds it from the files.
public enum VaultIndexer {
    /// What one `reconcile` did. `unchanged` files were skipped on a content
    /// hash match; a healthy steady state is all-unchanged, which is what the
    /// §V8 perf budget measures.
    public struct Summary: Equatable, Sendable {
        public var indexed: Int
        public var removed: Int
        public var unchanged: Int
    }

    /// Exact 64-bit FNV-1a over the file content. Deterministic across
    /// launches (unlike `Hasher`), exact (unlike SimHash) — a one-character
    /// edit must invalidate the row.
    static func contentHash(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    // MARK: - Write-through (VaultStore.save / .discard)

    /// Indexes one file Shifu just wrote. The file is re-read rather than
    /// trusting the caller's model object so this is the same code path
    /// reconcile uses — one parser, one truth.
    public static func indexFile(at url: URL, root: URL, database: ShifuDatabase) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate).map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        try database.queue.write { db in
            try upsert(text: text, relativePath: relativePath(of: url, root: root),
                       mtime: mtime, db: db)
        }
    }

    public static func remove(noteID: String, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try delete(noteIDs: [noteID], db: db)
        }
    }

    // MARK: - Reconcile

    private struct FileEntry {
        var path: String
        var url: URL
        var mtime: Int64
    }

    private static func markdownFiles(under root: URL) -> [FileEntry] {
        var files: [FileEntry] = []
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator where url.pathExtension == "md" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate).map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
                files.append(FileEntry(path: relativePath(of: url, root: root), url: url, mtime: mtime))
            }
        }
        return files
    }

    /// Brings the index in line with the tree: new/changed files re-indexed
    /// (mtime short-circuit, then hash short-circuit), vanished files removed.
    /// O(files) stat, O(changed) parse — cheap enough for every analyzer run.
    /// With an embedder, changed notes are re-embedded and notes indexed
    /// without one (write-through has no embedder) are backfilled.
    @discardableResult
    public static func reconcile(
        root: URL, database: ShifuDatabase, embedder: (any Embedder)? = nil
    ) throws -> Summary {
        let files = markdownFiles(under: root)

        struct IndexRow { var noteID: String; var hash: Int64; var mtime: Int64 }
        let known: [String: IndexRow] = try database.queue.read { db in
            var rows: [String: IndexRow] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT note_id, path, content_hash, mtime FROM vault_index") {
                rows[row["path"]] = IndexRow(
                    noteID: row["note_id"], hash: row["content_hash"], mtime: row["mtime"])
            }
            return rows
        }

        var summary = Summary(indexed: 0, removed: 0, unchanged: 0)
        var seenNoteIDs: Set<String> = []
        try database.queue.write { db in
            for file in files {
                if let existing = known[file.path], existing.mtime == file.mtime {
                    seenNoteIDs.insert(existing.noteID)
                    summary.unchanged += 1
                    continue
                }
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                if let existing = known[file.path], existing.hash == contentHash(text) {
                    // Touched but not edited: refresh mtime so the next pass
                    // short-circuits before reading the file again.
                    try db.execute(sql: "UPDATE vault_index SET mtime = ? WHERE path = ?",
                                   arguments: [file.mtime, file.path])
                    seenNoteIDs.insert(existing.noteID)
                    summary.unchanged += 1
                    continue
                }
                if let noteID = try upsert(
                    text: text, relativePath: file.path, mtime: file.mtime, db: db,
                    embedder: embedder) {
                    seenNoteIDs.insert(noteID)
                    summary.indexed += 1
                }
            }
            // Vanished files (and files whose frontmatter lost its id).
            let stale = try String.fetchAll(db, sql: "SELECT note_id FROM vault_index")
                .filter { !seenNoteIDs.contains($0) }
            try delete(noteIDs: stale, db: db)
            summary.removed = stale.count
        }
        if embedder != nil {
            try backfillVectors(root: root, database: database, embedder: embedder)
        }
        return summary
    }

    /// Embeds indexed notes that have no vector yet — notes written through
    /// VaultStore.save (no embedder on that path) pick theirs up on the next
    /// analyzer reconcile.
    private static func backfillVectors(
        root: URL, database: ShifuDatabase, embedder: (any Embedder)?
    ) throws {
        let missing: [(noteID: String, path: String)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT vi.note_id, vi.path FROM vault_index vi
                LEFT JOIN vault_vectors vv ON vv.note_id = vi.note_id
                WHERE vv.note_id IS NULL
                """).map { ($0["note_id"], $0["path"]) }
        }
        guard !missing.isEmpty else { return }
        try database.queue.write { db in
            for entry in missing {
                let file = root.appendingPathComponent(entry.path)
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let doc = FrontMatter.parse(text) else { continue }
                try embedVector(noteID: entry.noteID, doc: doc, db: db, embedder: embedder)
            }
        }
    }

    // MARK: - Row plumbing

    /// Parses and writes one file's index + FTS rows. Returns the note id,
    /// or nil for files that aren't vault notes (no frontmatter / no id) —
    /// stray Markdown in the folder is ignored, never an error.
    @discardableResult
    static func upsert(
        text: String, relativePath: String, mtime: Int64, db: Database,
        embedder: (any Embedder)? = nil
    ) throws -> String? {
        guard let doc = FrontMatter.parse(text), let noteID = doc.fields["id"] else { return nil }

        // Each kind dates itself differently (vault-features.md §2): knowledge
        // notes carry `captured:`, work notes `day:` (local midnight of it
        // serves), task overviews only `updated:` — which is the one that was
        // missing, so every overview sorted and displayed as undated.
        let captured = doc.fields["captured"]
            .flatMap { Note.iso.date(from: $0) }
            .map { Int64($0.timeIntervalSince1970 * 1_000) }
            ?? doc.fields["day"].flatMap(dayMs)
            ?? doc.fields["updated"]
                .flatMap { Note.iso.date(from: $0) }
                .map { Int64($0.timeIntervalSince1970 * 1_000) }
        // task_key resolves against the tasks table at index time, so a task
        // renamed or re-grouped later is picked up by the next reconcile
        // without rewriting files (vault-features.md §4).
        var taskID: Int64?
        if let taskKey = doc.fields["task_key"] {
            taskID = try Int64.fetchOne(
                db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [taskKey])
        }

        let shape = Shape(of: doc)
        try db.execute(sql: """
            INSERT INTO vault_index
                (note_id, path, kind, task_id, task_key, deck_key, captured,
                 title, summary, duration_ms, words, sections, content_hash, mtime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(note_id) DO UPDATE SET
                path = excluded.path, kind = excluded.kind, task_id = excluded.task_id,
                task_key = excluded.task_key, deck_key = excluded.deck_key,
                captured = excluded.captured, title = excluded.title,
                summary = excluded.summary, duration_ms = excluded.duration_ms,
                words = excluded.words, sections = excluded.sections,
                content_hash = excluded.content_hash, mtime = excluded.mtime
            """, arguments: [
                noteID, relativePath, doc.rawKind, taskID, doc.fields["task_key"],
                doc.fields["deck"], captured, title(of: doc), shape.summary,
                doc.fields["duration_ms"].flatMap(Int64.init), shape.words, shape.sections,
                contentHash(text), mtime
            ])
        let rowID = try Int64.fetchOne(
            db, sql: "SELECT id FROM vault_index WHERE note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM vault_fts WHERE rowid = ?", arguments: [rowID])
        try db.execute(
            sql: "INSERT INTO vault_fts (rowid, title, body) VALUES (?, ?, ?)",
            arguments: [rowID, title(of: doc), doc.body])
        try embedVector(noteID: noteID, doc: doc, db: db, embedder: embedder)
        return noteID
    }

    /// Title + the body's first ~500 chars → unit vector (vault-features.md
    /// §4). No embedder (or a nil embedding) leaves the vector row absent —
    /// hybrid search silently degrades to bm25-only for that note.
    static func embedVector(
        noteID: String, doc: FrontMatter.Document, db: Database, embedder: (any Embedder)?
    ) throws {
        guard let embedder else { return }
        let text = "\(title(of: doc)) \(doc.body.prefix(500))"
        guard let vector = embedder.embed(text) else { return }
        try db.execute(sql: """
            INSERT INTO vault_vectors (note_id, embedding) VALUES (?, ?)
            ON CONFLICT(note_id) DO UPDATE SET embedding = excluded.embedding
            """, arguments: [noteID, EmbedMath.blob(from: vector)])
    }

    private static func delete(noteIDs: [String], db: Database) throws {
        for noteID in noteIDs {
            if let rowID = try Int64.fetchOne(
                db, sql: "SELECT id FROM vault_index WHERE note_id = ?", arguments: [noteID]) {
                try db.execute(sql: "DELETE FROM vault_fts WHERE rowid = ?", arguments: [rowID])
                try db.execute(sql: "DELETE FROM vault_index WHERE id = ?", arguments: [rowID])
            }
            try db.execute(sql: "DELETE FROM vault_vectors WHERE note_id = ?",
                           arguments: [noteID])
        }
    }

    /// What a body is *made of*, as three numbers the browse queries can sort
    /// and filter on without opening the file (vault-features.md §4). The one
    /// that earns its keep is `sections`: a work note with none of them is the
    /// deterministic "where — what" line and nothing else, which is most of
    /// them, and a library that ranks those beside compiled documents reads as
    /// though it holds nothing.
    struct Shape {
        /// Body line 1 — for a work note the deterministic summary, for a card
        /// the opening sentence. Trimmed to a display length here so the row
        /// doesn't carry a whole paragraph it will never draw.
        var summary: String
        var words: Int
        /// `## ` headings. The compiler's own sections (`Sessions`, `Notes`,
        /// `Captured`) and an overview's four, so it counts the tiers a note
        /// earned rather than its prose length.
        var sections: Int

        init(of doc: FrontMatter.Document) { self.init(body: doc.body) }

        /// Body-only, so the v24 migration can backfill the columns from the
        /// FTS copy of the body it already has instead of leaving the whole
        /// library ungraded until the first reconcile finishes.
        init(body: String) {
            let lines = body.components(separatedBy: "\n")
            // Headings are skipped, not stripped: an overview opens on
            // "## Status", and a summary of "Status" says nothing at all.
            let lead = lines.first {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            } ?? ""
            summary = String(lead.trimmingCharacters(in: .whitespaces).prefix(240))
            words = body.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
            sections = lines.count { $0.hasPrefix("## ") }
        }
    }

    /// What the note is *called*: a knowledge note's topic, otherwise the task
    /// it belongs to, otherwise the first body line.
    ///
    /// The task name is what makes the compiled kinds readable. A work note's
    /// body opens on the deterministic source list, so titling it by line one
    /// gave rows reading "claudefordesktop, app, ghostty — researchi…"; an
    /// overview opens on `## Status`, so all eleven of them were called
    /// "Status". Both are the same note *of* something, and its name is the
    /// task's. The summary line still carries the "where — what", one line
    /// down, where it reads as a subtitle instead of a heading.
    static func title(of doc: FrontMatter.Document) -> String {
        if let topic = doc.fields["topic"] { return topic }
        if let task = doc.fields["task"], !task.isEmpty { return task }
        let firstLine = doc.body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    /// "YYYY-MM-DD" → local midnight in unix ms. DateFormatter is documented
    /// thread-safe on macOS 10.9+; config is never mutated.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayMs(_ day: String) -> Int64? {
        dayFormatter.date(from: day).map { Int64($0.timeIntervalSince1970 * 1_000) }
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let fullPath = url.standardizedFileURL.path
        return fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : fullPath
    }
}

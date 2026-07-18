import Foundation
import GRDB

/// Maintains the disposable SQLite search index over the vault's Markdown
/// tree (vault-features.md §4). Write-through from VaultStore keeps Shifu's
/// own writes indexed immediately; `reconcile` is the safety net that picks
/// up external edits (Obsidian, any editor) and deletions. Losing the index
/// loses nothing — `reconcile` rebuilds it from the files.
public enum VaultIndexer {
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
    @discardableResult
    public static func reconcile(root: URL, database: ShifuDatabase) throws -> Summary {
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
                    text: text, relativePath: file.path, mtime: file.mtime, db: db) {
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
        return summary
    }

    // MARK: - Row plumbing

    /// Parses and writes one file's index + FTS rows. Returns the note id,
    /// or nil for files that aren't vault notes (no frontmatter / no id) —
    /// stray Markdown in the folder is ignored, never an error.
    @discardableResult
    static func upsert(
        text: String, relativePath: String, mtime: Int64, db: Database
    ) throws -> String? {
        guard let doc = FrontMatter.parse(text), let noteID = doc.fields["id"] else { return nil }

        let captured = doc.fields["captured"]
            .flatMap { Note.iso.date(from: $0) }
            .map { Int64($0.timeIntervalSince1970 * 1_000) }
        // task_key resolves against the tasks table at index time, so a later
        // project assignment is picked up by the next reconcile without
        // rewriting files (vault-features.md §4).
        var taskID: Int64?
        var projectID: Int64?
        if let taskKey = doc.fields["task_key"] {
            if let task = try Row.fetchOne(
                db, sql: "SELECT id, project_id FROM tasks WHERE key = ?", arguments: [taskKey]) {
                taskID = task["id"]
                projectID = task["project_id"]
            }
        }

        try db.execute(sql: """
            INSERT INTO vault_index
                (note_id, path, kind, task_id, project_id, captured, content_hash, mtime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(note_id) DO UPDATE SET
                path = excluded.path, kind = excluded.kind, task_id = excluded.task_id,
                project_id = excluded.project_id, captured = excluded.captured,
                content_hash = excluded.content_hash, mtime = excluded.mtime
            """, arguments: [
                noteID, relativePath, doc.kind.rawValue, taskID, projectID,
                captured, contentHash(text), mtime
            ])
        let rowID = try Int64.fetchOne(
            db, sql: "SELECT id FROM vault_index WHERE note_id = ?", arguments: [noteID])
        try db.execute(sql: "DELETE FROM vault_fts WHERE rowid = ?", arguments: [rowID])
        try db.execute(
            sql: "INSERT INTO vault_fts (rowid, title, body) VALUES (?, ?, ?)",
            arguments: [rowID, title(of: doc), doc.body])
        return noteID
    }

    private static func delete(noteIDs: [String], db: Database) throws {
        for noteID in noteIDs {
            if let rowID = try Int64.fetchOne(
                db, sql: "SELECT id FROM vault_index WHERE note_id = ?", arguments: [noteID]) {
                try db.execute(sql: "DELETE FROM vault_fts WHERE rowid = ?", arguments: [rowID])
                try db.execute(sql: "DELETE FROM vault_index WHERE id = ?", arguments: [rowID])
            }
        }
    }

    /// Searchable title: the topic for knowledge notes; first body line
    /// (minus Markdown heading markers) otherwise.
    static func title(of doc: FrontMatter.Document) -> String {
        if let topic = doc.fields["topic"] { return topic }
        let firstLine = doc.body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let fullPath = url.standardizedFileURL.path
        return fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : fullPath
    }
}

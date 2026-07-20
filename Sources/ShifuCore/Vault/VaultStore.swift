import Foundation
import GRDB

/// The vault: plain Markdown notes in `~/Shifu/vault/YYYY/MM/` (design.md §5.1).
/// This type owns file layout, triage, dedupe, and review bookkeeping.
public struct VaultStore: Sendable {
    public let root: URL
    private let database: ShifuDatabase?

    public init(root: URL = ShifuPaths.vault, database: ShifuDatabase? = nil) {
        self.root = root
        self.database = database
    }

    // MARK: - Files

    public func url(for note: Note) -> URL {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: note.captured)
        let dir = root
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0), isDirectory: true)
        let slug = note.topic.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch != "-" || acc.last != "-" { acc.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return dir.appendingPathComponent("\(note.id.lowercased())-\(slug.prefix(40)).md")
    }

    @discardableResult
    public func save(_ note: Note) throws -> URL {
        let target = try existingURL(id: note.id) ?? url(for: note)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.serialize().write(to: target, atomically: true, encoding: .utf8)
        // Write-through to the search index (vault-features.md §4); reconcile
        // in the analyzer covers external edits.
        if let database {
            try VaultIndexer.indexFile(at: target, root: root, database: database)
        }
        return target
    }

    public func allNotes() throws -> [Note] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var notes: [Note] = []
        for case let file as URL in enumerator where file.pathExtension == "md" {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let note = Note.parse(text) {
                notes.append(note)
            }
        }
        return notes.sorted { $0.captured > $1.captured }
    }

    public func inbox() throws -> [Note] {
        try allNotes().filter { $0.state == .inbox }
    }

    /// Kept notes with a Q/A pair whose SRS due date has arrived (§5.2).
    public func due(asOf date: Date = Date()) throws -> [Note] {
        try allNotes().filter { note in
            note.state == .kept && note.questionAnswer != nil
                && (note.srs.map { $0.due <= date } ?? true)
        }
    }

    // MARK: - Work notes (vault-features.md §2.1)

    /// `work/YYYY/MM/DD-<task-slug>.md`. The slug comes from the task *key*
    /// (stable across renames), so file identity survives display renames.
    public func workNoteURL(day: String, taskKey: String) -> URL {
        let parts = day.split(separator: "-").map(String.init)
        let year = parts.isEmpty ? "0000" : parts[0]
        let month = parts.count > 1 ? parts[1] : "00"
        let dayNum = parts.count > 2 ? parts[2] : "00"
        let suffix = taskKey.split(separator: ":", maxSplits: 1)
            .last.map(String.init) ?? taskKey
        let slug = TaskGrouper.slug(suffix)
        return root
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("\(dayNum)-\(slug.prefix(40)).md")
    }

    public func workNote(day: String, taskKey: String) -> WorkNote? {
        let file = workNoteURL(day: day, taskKey: taskKey)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return WorkNote.parse(text)
    }

    @discardableResult
    public func saveWork(_ note: WorkNote) throws -> URL {
        let target = workNoteURL(day: note.day, taskKey: note.taskKey)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.serialize().write(to: target, atomically: true, encoding: .utf8)
        if let database {
            try VaultIndexer.indexFile(at: target, root: root, database: database)
        }
        return target
    }

    /// Removes one work-note file and its index rows immediately (deletion
    /// must not wait for the next reconcile — vault-features.md §V7).
    public func deleteWork(at url: URL, noteID: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if let database {
            try VaultIndexer.remove(noteID: noteID, database: database)
        }
    }

    /// All work-note files for one local day, wherever their task slug landed.
    public func workNoteFiles(day: String) -> [URL] {
        let parts = day.split(separator: "-").map(String.init)
        guard parts.count == 3 else { return [] }
        let dir = root
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(parts[0], isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("\(parts[2])-")
        }
    }

    // MARK: - Project notes (vault-features.md §2.2)

    public struct ProjectNoteFile: Sendable {
        public var id: String
        public var contentHash: Int64
        public var status: String?
    }

    public func projectNoteURL(slug: String) -> URL {
        root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("\(slug.prefix(60)).md")
    }

    /// The existing compiled note's carry-over state (id, hash, status
    /// paragraph) — enough for ProjectNoteCompiler's idempotent rewrite.
    public func projectNote(slug: String) -> ProjectNoteFile? {
        guard let text = try? String(contentsOf: projectNoteURL(slug: slug), encoding: .utf8),
              let doc = FrontMatter.parse(text), doc.kind == .project,
              let id = doc.fields["id"] else { return nil }
        var status: String?
        if let range = doc.body.range(of: "\n## Status\n") {
            status = String(doc.body[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ProjectNoteFile(
            id: id,
            contentHash: doc.fields["content_hash"].flatMap(Int64.init) ?? 0,
            status: status)
    }

    @discardableResult
    public func saveProject(slug: String, text: String) throws -> URL {
        let target = projectNoteURL(slug: slug)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let database {
            try VaultIndexer.indexFile(at: target, root: root, database: database)
        }
        return target
    }

    func existingURL(id: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator
        where file.lastPathComponent.hasPrefix(id.lowercased()) {
            return file
        }
        return nil
    }

    // MARK: - Triage (§5.1: nothing enters the review queue unconfirmed)

    public func keep(_ note: Note) throws {
        var kept = note
        kept.state = .kept
        // Entering the queue: due immediately, scheduled by the first review.
        if kept.questionAnswer != nil && kept.srs == nil {
            kept.srs = FSRS.State(due: Date())
        }
        try save(kept)
    }

    public func discard(_ note: Note) throws {
        if let file = existingURL(id: note.id) {
            try FileManager.default.removeItem(at: file)
        }
        if let database {
            try VaultIndexer.remove(noteID: note.id, database: database)
        }
    }

    // MARK: - Review

    /// Applies a grade, persists the note, and logs to `srs_reviews` for later
    /// FSRS parameter fitting (implementation.md Phase 4 item 3).
    @discardableResult
    public func review(_ note: Note, grade: FSRS.Grade, now: Date = Date()) throws -> Note {
        var updated = note
        updated.srs = FSRS.review(note.srs ?? FSRS.State(due: now), grade: grade, now: now)
        try save(updated)
        if let database {
            let ms = Int64(now.timeIntervalSince1970 * 1_000)
            try database.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO srs_reviews (note_id, reviewed_at, grade, interval_days)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [note.id, ms, grade.rawValue, updated.srs?.intervalDays])
            }
        }
        return updated
    }

    // MARK: - Dedupe (minimal, §13.4 deferred)

    /// If a candidate matches an existing note's topic with near-duplicate
    /// content, bump `seen_count` (re-encounter is itself an SRS signal) and
    /// return true instead of creating a new note.
    public func mergeIfDuplicate(of candidate: Note) throws -> Bool {
        let candidateHash = SimHash.hash(candidate.body)
        for existing in try allNotes()
        where existing.topic.lowercased() == candidate.topic.lowercased() {
            if SimHash.isNearDuplicate(SimHash.hash(existing.body), candidateHash) {
                var bumped = existing
                bumped.seenCount += 1
                try save(bumped)
                return true
            }
        }
        return false
    }
}

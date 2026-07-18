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

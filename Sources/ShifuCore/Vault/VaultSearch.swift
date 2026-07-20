import Foundation
import GRDB

/// Full-text search over the vault index (vault-features.md §4): bm25-ranked,
/// filterable by kind/task/project/date. Hybrid semantic ranking is V4.
public enum VaultSearch {
    public struct Hit: Identifiable, Sendable {
        public var noteID: String
        public var path: String          // relative to the vault root
        public var kind: FrontMatter.Kind
        public var title: String
        public var snippet: String
        public var captured: Date?

        public var id: String { noteID }

        public init(noteID: String, path: String, kind: FrontMatter.Kind,
                    title: String, snippet: String, captured: Date?) {
            self.noteID = noteID
            self.path = path
            self.kind = kind
            self.title = title
            self.snippet = snippet
            self.captured = captured
        }
    }

    /// A user query becomes a conjunction of quoted FTS5 tokens, the last one
    /// prefix-matched (search-as-you-type). Nil when nothing searchable
    /// remains — the caller shows no results, never an FTS syntax error.
    static func ftsQuery(from raw: String) -> String? {
        let tokens = raw.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        var quoted = tokens.map { "\"\($0)\"" }
        quoted[quoted.count - 1] += "*"
        return quoted.joined(separator: " ")
    }

    /// The task's most recent note of one kind — the Vault tab's "open the
    /// latest work note" query (vault-features.md §2.1). The caller supplies
    /// the display title (typically the task name); snippet stays empty.
    public static func latest(
        kind: FrontMatter.Kind, taskID: Int64, title: String, database: ShifuDatabase
    ) throws -> Hit? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT note_id, path, captured FROM vault_index
                WHERE kind = ? AND task_id = ?
                ORDER BY captured DESC LIMIT 1
                """, arguments: [kind.rawValue, taskID]
            ).map { row in
                Hit(
                    noteID: row["note_id"], path: row["path"], kind: kind,
                    title: title, snippet: "",
                    captured: (row["captured"] as Int64?).map {
                        Date(timeIntervalSince1970: Double($0) / 1_000)
                    })
            }
        }
    }

    /// Shared filter clauses over `vi` (vault_index).
    struct Filters {
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        init(kind: FrontMatter.Kind?, taskID: Int64?, projectID: Int64?, since: Date?) {
            if let kind {
                conditions.append("vi.kind = ?")
                arguments.append(kind.rawValue)
            }
            if let taskID {
                conditions.append("vi.task_id = ?")
                arguments.append(taskID)
            }
            if let projectID {
                conditions.append("vi.project_id = ?")
                arguments.append(projectID)
            }
            if let since {
                conditions.append("vi.captured >= ?")
                arguments.append(Int64(since.timeIntervalSince1970 * 1_000))
            }
        }
    }

    /// Hybrid search (vault-features.md §4, V4): reciprocal-rank fusion of
    /// bm25 top-k and cosine top-k over `vault_vectors`. No embedder (or a
    /// query that can't embed) ⇒ bm25-only, silently — byte-compatible with
    /// the V1 behavior.
    public static func search(
        _ query: String,
        kind: FrontMatter.Kind? = nil,
        taskID: Int64? = nil,
        projectID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 20,
        database: ShifuDatabase,
        embedder: (any Embedder)? = nil
    ) throws -> [Hit] {
        let filters = Filters(kind: kind, taskID: taskID, projectID: projectID, since: since)
        let poolSize = max(limit, 20)
        let lexical = try bm25Hits(query, filters: filters, limit: poolSize, database: database)
        guard let queryVector = embedder?.embed(query) else {
            return Array(lexical.prefix(limit))
        }
        let semantic = try cosineHits(queryVector, filters: filters,
                                      limit: poolSize, database: database)
        return fuse(lexical, semantic, limit: limit)
    }

    static func bm25Hits(
        _ query: String, filters: Filters, limit: Int, database: ShifuDatabase
    ) throws -> [Hit] {
        guard let match = ftsQuery(from: query) else { return [] }
        let conditions = ["vault_fts MATCH ?"] + filters.conditions
        let arguments = [match] + filters.arguments + [limit]
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT vi.note_id, vi.path, vi.kind, vi.captured, vault_fts.title,
                       snippet(vault_fts, 1, '«', '»', '…', 12) AS snip
                FROM vault_fts
                JOIN vault_index vi ON vi.id = vault_fts.rowid
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY bm25(vault_fts)
                LIMIT ?
                """, arguments: StatementArguments(arguments)
            ).map(hit(from:))
        }
    }

    /// Brute-force scan of vault_vectors — at 10k notes × 512 dims this is a
    /// few ms; no ANN index until measured otherwise (§V8). Two phases so
    /// the scan touches only (note_id, blob): full hit rows are fetched for
    /// the top-k survivors alone.
    static func cosineHits(
        _ queryVector: [Float], filters: Filters, limit: Int, database: ShifuDatabase
    ) throws -> [Hit] {
        let whereClause = filters.conditions.isEmpty
            ? "" : "WHERE " + filters.conditions.joined(separator: " AND ")
        let ranked: [String] = try database.queue.read { db in
            var scored: [(String, Float)] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT vv.note_id, vv.embedding
                FROM vault_vectors vv
                JOIN vault_index vi ON vi.note_id = vv.note_id
                \(whereClause)
                """, arguments: StatementArguments(filters.arguments))
            while let row = try cursor.next() {
                let blob: Data = row["embedding"]
                let score = blob.withUnsafeBytes { raw -> Float in
                    let floats = raw.bindMemory(to: Float.self)
                    guard floats.count == queryVector.count else { return -2 }
                    var sum: Float = 0
                    for index in queryVector.indices { sum += floats[index] * queryVector[index] }
                    return sum
                }
                scored.append((row["note_id"], score))
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
        guard !ranked.isEmpty else { return [] }

        let marks = ranked.map { _ in "?" }.joined(separator: ",")
        let byID: [String: Hit] = try database.queue.read { db in
            var out: [String: Hit] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT vi.note_id, vi.path, vi.kind, vi.captured, vault_fts.title,
                       substr(vault_fts.body, 1, 160) AS snip
                FROM vault_index vi
                JOIN vault_fts ON vault_fts.rowid = vi.id
                WHERE vi.note_id IN (\(marks))
                """, arguments: StatementArguments(ranked)) {
                out[row["note_id"]] = hit(from: row)
            }
            return out
        }
        return ranked.compactMap { byID[$0] }  // preserve cosine order
    }

    /// Reciprocal-rank fusion: score = Σ 1/(60 + rank). When both lists carry
    /// a note, the bm25 hit wins the display slot (its snippet is query-aware).
    static func fuse(_ lexical: [Hit], _ semantic: [Hit], limit: Int) -> [Hit] {
        var scores: [String: Double] = [:]
        var byID: [String: Hit] = [:]
        for (rank, hit) in lexical.enumerated() {
            scores[hit.noteID, default: 0] += 1.0 / Double(61 + rank)
            byID[hit.noteID] = hit
        }
        for (rank, hit) in semantic.enumerated() {
            scores[hit.noteID, default: 0] += 1.0 / Double(61 + rank)
            if byID[hit.noteID] == nil { byID[hit.noteID] = hit }
        }
        return scores
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .compactMap { byID[$0.key] }
    }

    private static func hit(from row: Row) -> Hit {
        Hit(
            noteID: row["note_id"],
            path: row["path"],
            kind: FrontMatter.Kind(rawValue: row["kind"]) ?? .knowledge,
            title: row["title"],
            snippet: row["snip"],
            captured: (row["captured"] as Int64?).map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            })
    }
}

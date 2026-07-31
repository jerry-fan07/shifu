import Foundation
import GRDB

/// Full-text search over the vault index (vault-features.md §4): bm25-ranked,
/// filterable by kind/task/date. Hybrid semantic ranking is V4.
public enum VaultSearch {
    /// One search result: a library entry plus the text that matched. Points
    /// at a file rather than carrying its content — the Markdown tree is the
    /// source of truth, so readers re-read from `path`. A hit can outlive its
    /// file if it was deleted since indexing; callers handle a nil read, and
    /// the next reconcile drops the row.
    ///
    /// The entry is the whole row model (`VaultLibrary.Entry`), so a result
    /// arrives already knowing its task, its theme and its depth — a hit list
    /// that can only say "note, kind, date" is exactly the one you can't tell
    /// a compiled document from a nine-second stub in.
    public struct Hit: Identifiable, Sendable {
        public var entry: VaultLibrary.Entry
        /// Match context for display, may span lines. Not valid Markdown.
        public var snippet: String

        public var id: String { entry.noteID }
        public var noteID: String { entry.noteID }
        public var path: String { entry.path }
        public var kind: FrontMatter.Kind? { entry.kind }
        public var title: String { entry.title }
        public var captured: Date? { entry.captured }

        public init(entry: VaultLibrary.Entry, snippet: String) {
            self.entry = entry
            self.snippet = snippet
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

    /// Hybrid search (vault-features.md §4, V4): reciprocal-rank fusion of
    /// bm25 top-k and cosine top-k over `vault_vectors`. No embedder (or a
    /// query that can't embed) ⇒ bm25-only, silently — byte-compatible with
    /// the V1 behavior.
    public static func search(
        _ query: String,
        kind: FrontMatter.Kind? = nil,
        taskID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 20,
        database: ShifuDatabase,
        embedder: (any Embedder)? = nil
    ) throws -> [Hit] {
        try search(
            query,
            filter: VaultLibrary.Filter(kind: kind, taskID: taskID, since: since),
            limit: limit, database: database, embedder: embedder)
    }

    /// The same search under the library's full facet set — the Notes page
    /// narrows by theme and by depth too, and a query that ignored the facets
    /// on screen would be a filter bar that lies.
    public static func search(
        _ query: String,
        filter: VaultLibrary.Filter,
        limit: Int = 20,
        database: ShifuDatabase,
        embedder: (any Embedder)? = nil
    ) throws -> [Hit] {
        let scope = VaultLibrary.Scope(filter)
        // Three times the display limit, because re-ranking can only reorder
        // what it was given. A term that appears in a hundred one-line traces
        // and one written-up day puts that day past rank 40 on bm25 alone, and
        // a pool of 40 would drop it before the depth weight ever saw it.
        // bm25 sorts the whole match set regardless of LIMIT, so a deeper pool
        // is very nearly free (measured: 2 ms either way).
        let poolSize = max(limit * 3, 60)
        let lexical = try bm25Hits(query, scope: scope, limit: poolSize, database: database)
        guard let queryVector = embedder?.embed(query) else {
            // Still through `fuse`, with nothing to fuse against: it is what
            // applies the depth weight, and bm25-only is the path a machine
            // with no sentence model takes — the one that most needs the
            // one-line traces kept off the top.
            return fuse(lexical, [], limit: limit)
        }
        let semantic = try cosineHits(queryVector, scope: scope,
                                      limit: poolSize, database: database)
        return fuse(lexical, semantic, limit: limit)
    }

    static func bm25Hits(
        _ query: String, scope: VaultLibrary.Scope, limit: Int, database: ShifuDatabase
    ) throws -> [Hit] {
        guard let match = ftsQuery(from: query) else { return [] }
        let arguments: [any DatabaseValueConvertible] = [match] + scope.arguments + [limit]
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(VaultLibrary.entryColumns),
                       snippet(vault_fts, 1, '«', '»', '…', 12) AS snip
                FROM vault_fts
                JOIN vault_index vi ON vi.id = vault_fts.rowid
                \(VaultLibrary.entryJoins)
                WHERE vault_fts MATCH ?\(scope.andClause)
                ORDER BY bm25(vault_fts)
                LIMIT ?
                """, arguments: StatementArguments(arguments)
            ).map(hit(from:))
        }
    }

    /// Brute-force scan of vault_vectors. Two phases so the scan touches only
    /// (note_id, blob): full hit rows are fetched for the top-k survivors
    /// alone, and the scope's joins are hung on the scan only when a condition
    /// actually names them (`Scope.needsJoins`).
    ///
    /// **Measured, since the estimate here was wrong:** 32 ms over 686 notes
    /// on an M-series Mac — decoding one `Data` per row dominates, not the dot
    /// product — so "a few ms at 10k notes" was optimistic by ~50×, and this
    /// is what puts hybrid search at ~37 ms per keystroke. It is unchanged
    /// from V4 and inside the §8 budget at today's size; an ANN index or a
    /// packed single-blob matrix is the fix when a vault reaches thousands.
    static func cosineHits(
        _ queryVector: [Float], scope: VaultLibrary.Scope, limit: Int, database: ShifuDatabase
    ) throws -> [Hit] {
        let ranked: [String] = try database.queue.read { db in
            var scored: [(String, Float)] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT vv.note_id, vv.embedding
                FROM vault_vectors vv
                JOIN vault_index vi ON vi.note_id = vv.note_id
                \(scope.needsJoins ? VaultLibrary.entryJoins : "")
                \(scope.whereClause)
                """, arguments: StatementArguments(scope.arguments))
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
                SELECT \(VaultLibrary.entryColumns),
                       substr(vault_fts.body, 1, 160) AS snip
                FROM vault_index vi
                JOIN vault_fts ON vault_fts.rowid = vi.id
                \(VaultLibrary.entryJoins)
                WHERE vi.note_id IN (\(marks))
                """, arguments: StatementArguments(ranked)) {
                out[row["note_id"]] = hit(from: row)
            }
            return out
        }
        return ranked.compactMap { byID[$0] }  // preserve cosine order
    }

    /// Reciprocal-rank fusion: score = Σ 1/(60 + rank), then scaled by how
    /// much of a note there is to have matched.
    ///
    /// The depth weight is what keeps the result list honest. bm25 rewards a
    /// short document for containing the term, and the vault's shortest
    /// documents are the ~600 one-line work-note traces the compiler writes
    /// for every task-day — so a search for "arxiv" ranked a nine-second
    /// glance above the afternoon that was written up. Weighting by depth
    /// (¼ for a trace, 1 for a note, 1¼ for a compiled document) reorders
    /// within the pool without removing anything: a trace is still findable,
    /// it just stops out-ranking the document that says what happened.
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
            .map { (id: $0.key, score: $0.value * weight(byID[$0.key])) }
            .sorted { ($0.score, $1.id) > ($1.score, $0.id) }
            .prefix(limit)
            .compactMap { byID[$0.id] }
    }

    static func weight(_ hit: Hit?) -> Double {
        switch hit?.entry.depth {
        case .trace: return 0.25
        case .document: return 1.25
        case .note, nil: return 1
        }
    }

    private static func hit(from row: Row) -> Hit {
        Hit(entry: VaultLibrary.entry(from: row), snippet: (row["snip"] as String?) ?? "")
    }
}

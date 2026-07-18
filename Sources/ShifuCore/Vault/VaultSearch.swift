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

    public static func search(
        _ query: String,
        kind: FrontMatter.Kind? = nil,
        taskID: Int64? = nil,
        projectID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 20,
        database: ShifuDatabase
    ) throws -> [Hit] {
        guard let match = ftsQuery(from: query) else { return [] }

        var conditions = ["vault_fts MATCH ?"]
        var arguments: [DatabaseValueConvertible] = [match]
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
        arguments.append(limit)

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
            ).map { row in
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
    }
}

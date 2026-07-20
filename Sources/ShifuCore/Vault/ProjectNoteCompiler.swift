import Foundation
import GRDB

/// Compiles one Markdown note per project (vault-features.md §2.2): time
/// totals, active tasks wiki-linked to their latest work notes, and an
/// optional LLM status paragraph built from the last week's log summaries.
/// Idempotent full rewrite; the `## Status` paragraph is content-hash gated
/// exactly like work-note narratives (zero tokens on unchanged weeks).
public enum ProjectNoteCompiler {
    static let statusResponseTokens = 300
    static let recentDays = 7

    private struct TaskRow {
        var id: Int64
        var key: String
        var name: String
        var totalMs: Int64
    }

    private struct Fetched {
        var name: String
        var tasks: [TaskRow]
        var recentMs: Int64
        var logLines: [String]
    }

    struct Pending {
        var projectID: Int64
        var slug: String
        var noteID: String        // carried from the existing file, or fresh
        var name: String
        var contentHash: Int64
        var body: String          // deterministic part, sans ## Status
        var carriedStatus: String?
        var logSummaries: [String]
    }

    // MARK: - Entry points

    /// All projects; weekly from the analyzer (with a backend) and on demand
    /// from CLI/UI (usually without one).
    @discardableResult
    public static func run(
        database: ShifuDatabase, vault: VaultStore, backend: (any LLMBackend)?,
        now: Date = Date()
    ) async throws -> Int {
        var written = 0
        for summary in try TaskStore.projects(database: database) {
            guard let projectID = summary.project.id else { continue }
            var pending = try gather(projectID: projectID, database: database,
                                     vault: vault, now: now)
            if pending.carriedStatus == nil, let backend, !pending.logSummaries.isEmpty,
               let status = try? await statusParagraph(for: pending, backend: backend),
               !status.isEmpty {
                pending.carriedStatus = status
            }
            try write(pending, vault: vault)
            written += 1
        }
        return written
    }

    /// Deterministic-only compile of one project — the UI's accept path.
    /// A hash match still carries the existing status paragraph over.
    public static func compileDeterministic(
        projectID: Int64, database: ShifuDatabase, vault: VaultStore, now: Date = Date()
    ) throws {
        let pending = try gather(projectID: projectID, database: database,
                                 vault: vault, now: now)
        try write(pending, vault: vault)
    }

    // MARK: - Deterministic compile

    static func gather(
        projectID: Int64, database: ShifuDatabase, vault: VaultStore, now: Date
    ) throws -> Pending {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(recentDays) * 86_400_000
        let fetched: Fetched = try database.queue.read { db in
            let name = try String.fetchOne(
                db, sql: "SELECT name FROM projects WHERE id = ?",
                arguments: [projectID]) ?? "project-\(projectID)"
            let tasks = try Row.fetchAll(db, sql: """
                SELECT t.id, t.key, t.name,
                       COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                 FROM activities a WHERE a.task_id = t.id), 0) AS total_ms
                FROM tasks t WHERE t.project_id = ?
                ORDER BY t.last_active_at DESC
                """, arguments: [projectID]
            ).map { row in
                TaskRow(id: row["id"], key: row["key"], name: row["name"],
                        totalMs: row["total_ms"])
            }
            let recentMs = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(l.duration_ms), 0) FROM task_logs l
                JOIN tasks t ON t.id = l.task_id
                WHERE t.project_id = ? AND l.day_start >= ?
                """, arguments: [projectID, cutoff]) ?? 0
            let logLines = try String.fetchAll(db, sql: """
                SELECT t.key || '|' || l.day_start || '|' || l.duration_ms
                       || '|' || l.summary
                FROM task_logs l JOIN tasks t ON t.id = l.task_id
                WHERE t.project_id = ? AND l.day_start >= ?
                ORDER BY l.day_start, t.key
                """, arguments: [projectID, cutoff])
            return Fetched(name: name, tasks: tasks, recentMs: recentMs, logLines: logLines)
        }

        let hash = VaultIndexer.contentHash(
            (fetched.tasks.map { "\($0.key)|\($0.totalMs)" } + fetched.logLines)
                .joined(separator: ";"))
        let slug = TaskGrouper.slug(fetched.name)
        let existing = vault.projectNote(slug: slug)
        return Pending(
            projectID: projectID, slug: slug,
            noteID: existing?.id ?? Note.ulid(), name: fetched.name, contentHash: hash,
            body: deterministicBody(fetched, database: database),
            carriedStatus: existing?.contentHash == hash ? existing?.status : nil,
            logSummaries: fetched.logLines.map { $0.components(separatedBy: "|").last ?? $0 })
    }

    /// The always-rewritten part: time totals line + `## Tasks` with a
    /// wiki-link to each task's latest work note.
    private static func deterministicBody(_ fetched: Fetched, database: ShifuDatabase) -> String {
        let totalMs = fetched.tasks.reduce(0) { $0 + $1.totalMs }
        var lines = [String(format: "%.1f h all time · %.1f h last %d days",
                            Double(totalMs) / 3_600_000, Double(fetched.recentMs) / 3_600_000,
                            recentDays)]
        guard !fetched.tasks.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append("## Tasks")
        for task in fetched.tasks {
            let link = (try? VaultSearch.latest(
                kind: .work, taskID: task.id, title: task.name, database: database))
                .flatMap { $0 }
                .map { " [[\(wikiLink($0.path))]]" } ?? ""
            lines.append(String(format: "- %@ — %.1f h%@", task.name,
                                Double(task.totalMs) / 3_600_000, link))
        }
        return lines.joined(separator: "\n")
    }

    static func write(_ pending: Pending, vault: VaultStore) throws {
        var body = pending.body
        if let status = pending.carriedStatus, !status.isEmpty {
            body += "\n\n## Status\n\(status)"
        }
        let text = [
            "---", "id: \(pending.noteID)", "kind: project",
            "project: \(pending.slug)", "name: \(pending.name)",
            "content_hash: \(pending.contentHash)", "---"
        ].joined(separator: "\n") + "\n\n" + body + "\n"
        try vault.saveProject(slug: pending.slug, text: text)
    }

    static func wikiLink(_ path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.hasSuffix(".md") ? String(base.dropLast(3)) : base
    }

    // MARK: - Status paragraph (LLM, optional)

    static func prompt(name: String, summaries: [String]) -> String {
        """
        Write a 2-4 sentence status paragraph for the project "\(name)" —
        where this effort stands, based only on the last week's work log lines
        below. Plain prose, no headings, no bullets.

        Work log lines:
        \(summaries.joined(separator: "\n"))
        """
    }

    /// Token-budgeted like work-note narratives (invariant 7): log lines are
    /// dropped from the tail rather than splitting the prompt.
    static func statusParagraph(
        for pending: Pending, backend: any LLMBackend
    ) async throws -> String {
        var summaries = pending.logSummaries
        var text = prompt(name: pending.name, summaries: summaries)
        while summaries.count > 1,
              LLMTokens.estimate(text) + statusResponseTokens > backend.contextWindowTokens {
            summaries.removeLast(max(1, summaries.count / 3))
            text = prompt(name: pending.name, summaries: summaries)
        }
        let response = try await backend.complete(prompt: text, maxTokens: statusResponseTokens)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

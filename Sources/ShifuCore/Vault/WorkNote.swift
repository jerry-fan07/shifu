import Foundation

/// One work note: the Markdown twin of a `task_logs` row (vault-features.md
/// §2.1) — same (task, day) granularity, same idempotent rebuild. Body
/// contract, enforced here: line 1 is the deterministic "where — what"
/// summary; `## Sessions` (LLM prose), `## Notes` (the detailed tier's
/// multi-section prose) and `## Captured` (wiki-links to the day's knowledge
/// notes) are optional sections the compiler can replace independently.
public struct WorkNote: Equatable, Sendable {
    /// One contiguous stretch of work within a task-day, rendered as local
    /// wall-clock strings rather than timestamps — these are written into
    /// Markdown for a human to read, not parsed back.
    public struct Session: Equatable, Sendable {
        public var start: String    // "HH:MM", local time
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public var id: String           // ULID; survives rebuilds (file identity)
    public var taskKey: String      // TaskGrouper key — stable across renames
    public var taskName: String     // display name; refreshed on rebuild
    public var day: String          // "YYYY-MM-DD", local
    public var durationMs: Int64
    public var sources: [String]
    public var sessions: [Session]
    /// Hash of (sorted activity ids + per-activity text-sample hashes): when
    /// unchanged, the `## Sessions` prose carries over verbatim — zero tokens
    /// spent on unchanged days.
    public var contentHash: Int64
    public var summary: String      // body line 1, deterministic
    public var sessionsProse: String?
    /// The `## Notes` section: multi-section prose for a day whose time was
    /// dominantly work or learning (vault-features.md §2.1). Nil on light-tier
    /// days, which get session bullets and nothing else — an afternoon of
    /// admin does not earn a document.
    public var detailProse: String?
    public var capturedLinks: [String]  // wiki-link targets, no brackets

    public init(
        id: String = Note.ulid(), taskKey: String, taskName: String, day: String,
        durationMs: Int64, sources: [String] = [], sessions: [Session] = [],
        contentHash: Int64 = 0, summary: String,
        sessionsProse: String? = nil, detailProse: String? = nil,
        capturedLinks: [String] = []
    ) {
        self.id = id
        self.taskKey = taskKey
        self.taskName = taskName
        self.day = day
        self.durationMs = durationMs
        self.sources = sources
        self.sessions = sessions
        self.contentHash = contentHash
        self.summary = summary
        self.sessionsProse = sessionsProse
        self.detailProse = detailProse
        self.capturedLinks = capturedLinks
    }

    // MARK: - Serialization

    public func serialize() -> String {
        var front = ["---", "id: \(id)", "kind: work", "task_key: \(taskKey)",
                     "task: \(taskName)", "day: \(day)", "duration_ms: \(durationMs)"]
        if !sources.isEmpty {
            front.append("sources: [\(sources.joined(separator: ", "))]")
        }
        if !sessions.isEmpty {
            let spans = sessions
                .map { "{start: \"\($0.start)\", end: \"\($0.end)\"}" }
                .joined(separator: ", ")
            front.append("sessions: [\(spans)]")
        }
        front.append("content_hash: \(contentHash)")
        front.append("---")

        var body = summary
        if let sessionsProse, !sessionsProse.isEmpty {
            body += "\n\n## Sessions\n\(sessionsProse)"
        }
        if let detailProse, !detailProse.isEmpty {
            body += "\n\n## Notes\n\(detailProse)"
        }
        if !capturedLinks.isEmpty {
            body += "\n\n## Captured\n" + capturedLinks.map { "- [[\($0)]]" }.joined(separator: "\n")
        }
        return front.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// Parses a work-note file. Nil for other vault kinds or missing fields.
    public static func parse(_ text: String) -> WorkNote? {
        guard let doc = FrontMatter.parse(text), doc.kind == .work else { return nil }
        let fields = doc.fields
        guard let id = fields["id"], let taskKey = fields["task_key"],
              let day = fields["day"] else { return nil }

        let body = parseBody(doc.body)
        return WorkNote(
            id: id,
            taskKey: taskKey,
            taskName: fields["task"] ?? taskKey,
            day: day,
            durationMs: fields["duration_ms"].flatMap(Int64.init) ?? 0,
            sources: fields["sources"].map(parseInlineList) ?? [],
            sessions: fields["sessions"].map(parseSessions) ?? [],
            contentHash: fields["content_hash"].flatMap(Int64.init) ?? 0,
            summary: body.summary,
            sessionsProse: body.prose,
            detailProse: body.detail,
            capturedLinks: body.links
        )
    }

    struct ParsedBody {
        var summary: String
        var prose: String?
        var detail: String?
        var links: [String]
    }

    /// Splits the body per the body contract. Unknown sections are dropped —
    /// the compiler owns this file and rewrites it wholesale.
    static func parseBody(_ body: String) -> ParsedBody {
        var prose: String?
        var detail: String?
        var links: [String] = []
        let chunks = body.components(separatedBy: "\n## ")
        let summary = chunks[0].trimmingCharacters(in: .whitespacesAndNewlines)
        for chunk in chunks.dropFirst() {
            let lines = chunk.components(separatedBy: "\n")
            let header = lines[0].trimmingCharacters(in: .whitespaces)
            let content = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch header {
            case "Sessions":
                prose = content.isEmpty ? nil : content
            case "Notes":
                detail = content.isEmpty ? nil : content
            case "Captured":
                links = content.components(separatedBy: "\n").compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("- [[") && trimmed.hasSuffix("]]") else { return nil }
                    return String(trimmed.dropFirst(4).dropLast(2))
                }
            default:
                break
            }
        }
        return ParsedBody(summary: summary, prose: prose, detail: detail, links: links)
    }

    /// `[Xcode, github.com]` → ["Xcode", "github.com"]
    static func parseInlineList(_ raw: String) -> [String] {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
        trimmed = String(trimmed.dropFirst().dropLast())
        return trimmed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `[{start: "09:12", end: "10:41"}, …]` → sessions. Values are scanned
    /// key-first because the times themselves contain colons.
    static func parseSessions(_ raw: String) -> [Session] {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
        trimmed = String(trimmed.dropFirst().dropLast())
        return trimmed.components(separatedBy: "}").compactMap { part in
            guard let open = part.firstIndex(of: "{") else { return nil }
            var fields: [String: String] = [:]
            for pair in part[part.index(after: open)...].split(separator: ",") {
                guard let colon = pair.firstIndex(of: ":") else { continue }
                let key = pair[..<colon].trimmingCharacters(in: .whitespaces)
                let value = pair[pair.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fields[key] = value
            }
            guard let start = fields["start"], let end = fields["end"] else { return nil }
            return Session(start: start, end: end)
        }
    }
}

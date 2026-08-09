import Foundation
import GRDB

/// The Markdown note a snip writes into the vault (design.md §3.6).
///
/// A snip is two things on disk: the frame, which lives with every other frame
/// under `~/Shifu/rewind/`, and this — the words filed beside it, under
/// whatever task or theme was running when it was taken. The split is
/// deliberate: **the vault stays text.** It is the folder the user opens in
/// Obsidian and syncs wherever they like, and putting screenshots in it would
/// silently move pixels somewhere Shifu never promised they'd stay.
///
/// The cost is that the image link is an absolute path rather than an
/// embeddable relative one, so Obsidian shows a link instead of a preview.
/// That is the right way round: a link the user can follow, against a rule
/// about where pixels live that holds no matter what they do with the vault.
///
/// Written into its own folder rather than appended to a work note, because
/// `WorkNoteCompiler` and `TaskOverviewCompiler` rewrite theirs wholesale every
/// hour — anything appended there is gone by the next analyzer run.
public struct SnipNote: Equatable, Sendable {
    public var id: String
    public var title: String
    /// ISO-8601 instant the frame was taken.
    public var captured: String
    /// The frame, absolute on disk.
    public var framePath: String
    /// What was on screen — the app, and the window title if there was one.
    public var source: String
    public var taskKey: String?
    public var taskName: String?
    public var themeKey: String?
    /// The user's own line, when they had one. Snips are usually wordless.
    public var body: String?

    public init(
        id: String = Note.ulid(), title: String, captured: String, framePath: String,
        source: String, taskKey: String? = nil, taskName: String? = nil,
        themeKey: String? = nil, body: String? = nil
    ) {
        self.id = id
        self.title = title
        self.captured = captured
        self.framePath = framePath
        self.source = source
        self.taskKey = taskKey
        self.taskName = taskName
        self.themeKey = themeKey
        self.body = body
    }

    /// The `captured:` stamp, in the one format `VaultIndexer` reads dates in
    /// (`Note.iso`, which is internal — this is the public door to it, and the
    /// reason a caller outside `ShifuCore` never has to know the format).
    public static func stamp(_ date: Date) -> String { Note.iso.string(from: date) }

    /// Where in the vault this note goes, relative to the vault root. Dated
    /// folders like the knowledge notes, under `snips/` so a tree full of them
    /// never crowds the year folders the cards live in.
    public var relativePath: String {
        let month = String(captured.prefix(7)).replacingOccurrences(of: "-", with: "/")
        return "snips/\(month)/\(id).md"
    }

    public func serialize() -> String {
        var front = ["---", "id: \(id)", "kind: snip", "title: \(title)",
                     "captured: \(captured)", "source: \(source)",
                     "frame: \(framePath)"]
        if let taskKey { front.append("task_key: \(taskKey)") }
        if let taskName { front.append("task: \(taskName)") }
        if let themeKey { front.append("theme_key: \(themeKey)") }
        front.append("---")

        var lines = ["Kept from \(source)."]
        if let body, !body.isEmpty { lines.append(body) }
        lines.append("[Open the frame](\(framePath))")
        return front.joined(separator: "\n") + "\n\n" + lines.joined(separator: "\n\n") + "\n"
    }

    /// Parses a snip note. Nil for every other vault kind, which is what keeps
    /// snips out of the review queue and the knowledge counts.
    public static func parse(_ text: String) -> SnipNote? {
        guard let doc = FrontMatter.parse(text), doc.kind == .snip,
              let id = doc.fields["id"], let captured = doc.fields["captured"]
        else { return nil }
        return SnipNote(
            id: id,
            title: doc.fields["title"] ?? "Frame",
            captured: captured,
            framePath: doc.fields["frame"] ?? "",
            source: doc.fields["source"] ?? "",
            taskKey: doc.fields["task_key"],
            taskName: doc.fields["task"],
            themeKey: doc.fields["theme_key"])
    }
}

/// What Shifu currently believes you are working on (design.md §3.6).
///
/// Best effort on purpose. A snip is taken *now*, and the block containing now
/// has usually not been sessionized yet — the analyzer runs hourly — so the
/// honest answer comes from the most recent block that already has a task, not
/// from the one in progress. An unattached snip is a fine outcome and much
/// better than one filed under the wrong thing.
public struct RewindContext: Sendable, Equatable {
    public var taskID: Int64?
    public var taskKey: String?
    public var taskName: String?
    public var themeKey: String?
    public var themeName: String?

    public init(
        taskID: Int64? = nil, taskKey: String? = nil, taskName: String? = nil,
        themeKey: String? = nil, themeName: String? = nil
    ) {
        self.taskID = taskID
        self.taskKey = taskKey
        self.taskName = taskName
        self.themeKey = themeKey
        self.themeName = themeName
    }

    /// How far back a block may be and still count as "what I am doing".
    /// Beyond this the honest answer is nothing — an hour-old task is not the
    /// one this frame belongs to.
    public static let staleAfterMs: Int64 = 30 * 60_000

    public static func current(
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), database: ShifuDatabase
    ) -> RewindContext {
        let row = try? database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT a.task_id, a.theme_key, t.key AS task_key, t.name AS task_name,
                       th.name AS theme_name
                FROM activities a
                LEFT JOIN tasks t ON t.id = a.task_id
                LEFT JOIN themes th ON th.key = a.theme_key
                WHERE a.task_id IS NOT NULL AND a.ended_at >= ?
                ORDER BY a.ended_at DESC LIMIT 1
                """, arguments: [now - staleAfterMs])
        }
        guard let row = row ?? nil else { return RewindContext() }
        return RewindContext(
            taskID: row["task_id"], taskKey: row["task_key"], taskName: row["task_name"],
            themeKey: row["theme_key"], themeName: row["theme_name"])
    }
}

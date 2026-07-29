import Foundation

/// One task's living overview document (vault-features.md §2.1): a single
/// Markdown file per task, replaced wholesale each time the task's completed
/// day notes change. Documentation, not a diary — the day notes are the diary.
///
/// Unlike `Note` and `WorkNote` this kind never enters inbox or review
/// queries: `kind: task_overview` fails both parsers' kind guards, which is
/// exactly what keeps a compiled document out of the flashcard queue.
public struct TaskOverview: Equatable, Sendable {
    public var id: String           // ULID; survives rebuilds (file identity)
    public var taskKey: String      // TaskGrouper key — stable across renames
    public var taskName: String     // display name; refreshed on rebuild
    public var updated: Date
    /// Hash of the day notes the current body was compiled from — the
    /// regeneration gate, same discipline as `WorkNote.contentHash`.
    public var inputHash: Int64
    public var body: String

    public init(
        id: String = Note.ulid(), taskKey: String, taskName: String,
        updated: Date = Date(), inputHash: Int64 = 0, body: String
    ) {
        self.id = id
        self.taskKey = taskKey
        self.taskName = taskName
        self.updated = updated
        self.inputHash = inputHash
        self.body = body
    }

    // MARK: - Serialization

    public func serialize() -> String {
        let front = ["---", "id: \(id)", "kind: \(FrontMatter.Kind.taskOverview.rawValue)",
                     "task_key: \(taskKey)", "task: \(taskName)",
                     "updated: \(Note.iso.string(from: updated))",
                     "input_hash: \(inputHash)", "---"]
        return front.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// Parses an overview file. Nil for other vault kinds or missing fields.
    public static func parse(_ text: String) -> TaskOverview? {
        guard let doc = FrontMatter.parse(text), doc.kind == .taskOverview else { return nil }
        let fields = doc.fields
        guard let id = fields["id"], let taskKey = fields["task_key"] else { return nil }
        return TaskOverview(
            id: id,
            taskKey: taskKey,
            taskName: fields["task"] ?? taskKey,
            updated: fields["updated"].flatMap { Note.iso.date(from: $0) } ?? Date(),
            inputHash: fields["input_hash"].flatMap(Int64.init) ?? 0,
            body: doc.body)
    }
}

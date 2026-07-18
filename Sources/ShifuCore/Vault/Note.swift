import Foundation

/// One knowledge note: plain Markdown with YAML frontmatter (design.md §5.1).
/// The vault stays readable and portable without Shifu — Obsidian-compatible.
public struct Note: Equatable, Sendable {
    public enum State: String, Sendable {
        case inbox      // candidate awaiting keep/discard triage
        case kept       // confirmed; in the review queue if it has a Q/A
    }

    public var id: String
    public var captured: Date
    public var sourceApp: String?
    public var sourceURL: String?
    public var topic: String
    public var taskKey: String?    // grouping key of the source activity's task (§5.3)
    public var confidence: Double?
    public var state: State
    public var seenCount: Int
    public var srs: FSRS.State?
    public var body: String        // markdown; may contain "Q: …" / "A: …" lines

    public init(
        id: String = Note.ulid(), captured: Date = Date(), sourceApp: String? = nil,
        sourceURL: String? = nil, topic: String, taskKey: String? = nil,
        confidence: Double? = nil, state: State = .inbox, seenCount: Int = 1,
        srs: FSRS.State? = nil, body: String
    ) {
        self.id = id
        self.captured = captured
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.topic = topic
        self.taskKey = taskKey
        self.confidence = confidence
        self.state = state
        self.seenCount = seenCount
        self.srs = srs
        self.body = body
    }

    /// The Q/A pair, if the note is reviewable (§5.1: notes without one are
    /// reference notes, excluded from the SRS queue).
    public var questionAnswer: (question: String, answer: String)? {
        var question: String?
        var answer: String?
        for line in body.split(separator: "\n") {
            if line.hasPrefix("Q: ") { question = String(line.dropFirst(3)) }
            if line.hasPrefix("A: ") { answer = String(line.dropFirst(3)) }
        }
        guard let question, let answer else { return nil }
        return (question, answer)
    }

    // MARK: - Serialization

    // ISO8601DateFormatter is documented thread-safe; config is never mutated.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public func serialize() -> String {
        var front = ["---", "id: \(id)", "captured: \(Self.iso.string(from: captured))"]
        if let sourceApp { front.append("source_app: \(sourceApp)") }
        if let sourceURL { front.append("source_url: \(sourceURL)") }
        front.append("topic: \(topic)")
        if let taskKey { front.append("task_key: \(taskKey)") }
        if let confidence { front.append("confidence: \(String(format: "%.2f", confidence))") }
        front.append("state: \(state.rawValue)")
        if seenCount > 1 { front.append("seen_count: \(seenCount)") }
        if let srs {
            front.append("srs: {stability: \(String(format: "%.4f", srs.stability)), "
                + "difficulty: \(String(format: "%.4f", srs.difficulty)), "
                + "interval_days: \(String(format: "%.1f", srs.intervalDays)), "
                + "due: \(Self.iso.string(from: srs.due)), reps: \(srs.reps)"
                + (srs.lastReview.map { ", last_review: \(Self.iso.string(from: $0))" } ?? "")
                + "}")
        }
        front.append("---")
        return front.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// Parses a knowledge-note file. Nil when there's no valid frontmatter
    /// block, or when the file is another vault kind (work/project notes,
    /// vault-features.md §2 — they must never enter inbox/review queries).
    public static func parse(_ text: String) -> Note? {
        guard let doc = FrontMatter.parse(text), doc.kind == .knowledge else { return nil }
        let fields = doc.fields
        guard let id = fields["id"], let topic = fields["topic"] else { return nil }

        return Note(
            id: id,
            captured: fields["captured"].flatMap { iso.date(from: $0) } ?? Date(),
            sourceApp: fields["source_app"],
            sourceURL: fields["source_url"],
            topic: topic,
            taskKey: fields["task_key"],
            confidence: fields["confidence"].flatMap(Double.init),
            state: fields["state"].flatMap(State.init(rawValue:)) ?? .kept,
            seenCount: fields["seen_count"].flatMap(Int.init) ?? 1,
            srs: fields["srs"].flatMap(parseSRS),
            body: doc.body
        )
    }

    /// Parses the inline-map form: `{stability: 2.5, due: 2026-07-18T…, reps: 0}`.
    static func parseSRS(_ raw: String) -> FSRS.State? {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { return nil }
        trimmed = String(trimmed.dropFirst().dropLast())
        var fields: [String: String] = [:]
        for pair in trimmed.split(separator: ",") {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let due = fields["due"].flatMap({ iso.date(from: $0) }) else { return nil }
        return FSRS.State(
            stability: fields["stability"].flatMap(Double.init) ?? 0,
            difficulty: fields["difficulty"].flatMap(Double.init) ?? 0,
            intervalDays: fields["interval_days"].flatMap(Double.init) ?? 0,
            due: due,
            reps: fields["reps"].flatMap(Int.init) ?? 0,
            lastReview: fields["last_review"].flatMap { iso.date(from: $0) }
        )
    }

    // MARK: - ULID (sortable id, design.md §5.1)

    static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func ulid(now: Date = Date()) -> String {
        var chars = [Character](repeating: "0", count: 26)
        var timestamp = UInt64(now.timeIntervalSince1970 * 1_000)
        for index in stride(from: 9, through: 0, by: -1) {
            chars[index] = crockford[Int(timestamp & 0x1F)]
            timestamp >>= 5
        }
        for index in 10..<26 {
            chars[index] = crockford[Int.random(in: 0..<32)]
        }
        return String(chars)
    }
}

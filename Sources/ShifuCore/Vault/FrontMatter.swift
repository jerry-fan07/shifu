import Foundation

/// Shared YAML-frontmatter scanning for vault note types (Note, and V2's
/// WorkNote — vault-features.md §2). Line-oriented `key: value` only; nested
/// structures stay strings for the caller to interpret (Note.parseSRS).
public enum FrontMatter {
    /// Every note kind in the vault tree (vault-features.md §2). Absent
    /// `kind:` in frontmatter means `.knowledge` — pre-V1 notes never wrote it.
    public enum Kind: String, Sendable {
        case knowledge
        case work
        case taskOverview = "task_overview"
    }

    /// A parsed note file: frontmatter as flat strings, plus the trimmed body.
    /// Values are never coerced here — nested forms like `srs: {…}` stay
    /// strings for the caller to interpret (`Note.parseSRS`).
    public struct Document {
        public var fields: [String: String]
        public var body: String

        /// The declared kind, or nil when `kind:` names something this binary
        /// doesn't know. Only an *absent* field means `.knowledge` (the pre-V1
        /// rationale above); an unrecognized *string* is deliberately not
        /// knowledge, so `doc.kind == .knowledge` guards reject a newer
        /// binary's note instead of leaking it into the inbox and review
        /// queues until every binary catches up.
        public var kind: Kind? {
            guard let raw = fields["kind"] else { return .knowledge }
            return Kind(rawValue: raw)
        }

        /// The `kind:` string as written in the file — what the index stores,
        /// so an older binary's reconcile round-trips a kind it can't parse
        /// rather than relabeling it `knowledge`.
        public var rawKind: String {
            fields["kind"] ?? Kind.knowledge.rawValue
        }
    }

    /// Splits a note file into frontmatter fields and body. Nil when there is
    /// no valid `---` block.
    public static func parse(_ text: String) -> Document? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Document(fields: fields, body: body)
    }
}

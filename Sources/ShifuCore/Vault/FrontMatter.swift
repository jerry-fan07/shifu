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
        case project
    }

    public struct Document {
        public var fields: [String: String]
        public var body: String

        public var kind: Kind {
            fields["kind"].flatMap(Kind.init(rawValue:)) ?? .knowledge
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

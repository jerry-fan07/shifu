import Foundation

/// One piece of writing the user handed over (voice.md §2.1): plain Markdown
/// with YAML frontmatter, in the vault's own file idiom so the corpus is
/// readable and editable without Shifu.
///
/// Deliberately not a `Note`. A sample is raw material, never reviewed, never
/// indexed, and it lives outside the vault root so `VaultStore.allNotes()` and
/// the library census never see it (voice.md §2.1).
public struct VoiceSample: Equatable, Sendable, Identifiable {
    /// How the text got here. Only ever the user's own doing — nothing in
    /// Shifu writes a sample from captured screen text, and voice.md §2.3
    /// says why that is a refusal rather than a gap.
    public enum Source: String, Sendable {
        case paste
        case importedFile = "import"
    }

    public var id: String
    public var title: String
    public var source: Source
    public var added: Date
    public var text: String

    public init(
        id: String = Note.ulid(), title: String, source: Source = .paste,
        added: Date = Date(), text: String
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.added = added
        self.text = text
    }

    /// Whitespace-separated words. The one length measure the file, the page
    /// and the ingest floor all quote, so they can never disagree.
    public var wordCount: Int { VoiceSample.words(in: text) }

    public static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Serialization

    public func serialize() -> String {
        let front = [
            "---",
            "id: \(id)",
            "kind: voice_sample",
            "title: \(title.replacingOccurrences(of: "\n", with: " "))",
            "source: \(source.rawValue)",
            "added: \(Note.iso.string(from: added))",
            "words: \(wordCount)",
            "---"
        ]
        return front.joined(separator: "\n") + "\n\n" + text + "\n"
    }

    /// Nil when the file has no frontmatter block, or declares itself some
    /// other kind — the same guard the vault's note kinds use, so a stray
    /// document in `~/Shifu/voice/samples/` is skipped rather than read as
    /// writing the user claims as theirs.
    public static func parse(_ text: String) -> VoiceSample? {
        guard let doc = FrontMatter.parse(text),
              doc.fields["kind"] == "voice_sample",
              let id = doc.fields["id"] else { return nil }
        return VoiceSample(
            id: id,
            title: doc.fields["title"] ?? "Untitled",
            source: doc.fields["source"].flatMap(Source.init(rawValue:)) ?? .paste,
            added: doc.fields["added"].flatMap { Note.iso.date(from: $0) } ?? Date(),
            text: doc.body
        )
    }
}

import Foundation

/// The corpus on disk (voice.md §2): `~/Shifu/voice/samples/*.md`, plus the
/// derived `profile.md` beside it. This type owns file layout, the ingest
/// door, and the fingerprint that decides when the profile is stale.
///
/// It takes no database. Samples are the user's own files — the one thing in
/// Shifu that exists *only* because they put it there — and nothing about them
/// needs an index, a status or a join.
public struct VoiceStore: Sendable {
    /// Shorter than this and a sample says nothing about how someone writes,
    /// so it is refused at the door with a reason rather than stored and
    /// quietly ignored by every measurement downstream (voice.md §2.3).
    public static let minimumSampleWords = 25
    /// One file's ceiling. A novel dropped into the picker would be read into
    /// memory, hashed on every fingerprint, and then truncated to an excerpt
    /// anyway (`VoiceDrafter.excerptCharCap`).
    public static let maxSampleChars = 400_000

    public let root: URL

    public init(root: URL = ShifuPaths.voice) {
        self.root = root
    }

    public var samplesDirectory: URL {
        root.appendingPathComponent("samples", isDirectory: true)
    }

    public var profileURL: URL {
        root.appendingPathComponent("profile.md")
    }

    /// Why a piece of text was turned away. Every case carries something the
    /// page can say out loud — an ingest that fails silently reads as a bug in
    /// the button.
    public enum IngestError: Error, CustomStringConvertible {
        case tooShort(words: Int)
        case tooLong(characters: Int)
        case unreadable(name: String)
        /// A PDF with no text layer — a scan. Its own case rather than
        /// `unreadable` because what the user can do about it is different,
        /// and because Shifu deliberately will not OCR it (voice.md §2.3).
        case noTextLayer(name: String)
        /// A PDF that opened but is password-protected. Also its own case: the
        /// fix is to unlock it, which is nothing like "it's a scan".
        case locked(name: String)

        public var description: String {
            switch self {
            case .tooShort(let words):
                return "\(words) words is too short to measure — "
                    + "\(VoiceStore.minimumSampleWords) is the floor."
            case .tooLong(let characters):
                return "\(characters / 1_000)k characters is past the "
                    + "\(VoiceStore.maxSampleChars / 1_000)k limit for one sample."
            case .unreadable(let name):
                return "Couldn't read \(name) as text."
            case .noTextLayer(let name):
                return "\(name) has no text layer — it looks scanned. "
                    + "Shifu won't OCR it: that would measure the transcriber's "
                    + "habits as yours."
            case .locked(let name):
                return "\(name) is password-protected. Unlock it and try again."
            }
        }
    }

    // MARK: - Ingest

    /// Adds one sample. Redaction happens here and nowhere else on this path
    /// (invariant 2): a pasted email is exactly where a card number or an API
    /// key turns up, and a sample is the one kind of user text that later
    /// ships verbatim to a model.
    @discardableResult
    public func add(
        title: String, text: String, source: VoiceSample.Source = .paste, now: Date = Date()
    ) throws -> VoiceSample {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxSampleChars else {
            throw IngestError.tooLong(characters: trimmed.count)
        }
        let words = VoiceSample.words(in: trimmed)
        guard words >= Self.minimumSampleWords else {
            throw IngestError.tooShort(words: words)
        }
        let sample = VoiceSample(
            id: Note.ulid(now: now),
            title: cleanTitle(title, fallback: trimmed),
            source: source, added: now, text: Redactor.redact(trimmed))
        let target = url(for: sample)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sample.serialize().write(to: target, atomically: true, encoding: .utf8)
        return sample
    }

    /// One file from the importer. The filename becomes the title, because it
    /// is the only thing the user has already named it.
    @discardableResult
    public func importFile(at file: URL, now: Date = Date()) throws -> VoiceSample {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw IngestError.unreadable(name: file.lastPathComponent)
        }
        return try add(
            title: file.deletingPathExtension().lastPathComponent,
            text: text, source: .importedFile, now: now)
    }

    // MARK: - Reading

    /// Newest first — the order the page lists them in, and the order
    /// `VoiceDrafter` takes excerpts in (voice.md §4.3).
    public func samples() -> [VoiceSample] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: samplesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return VoiceSample.parse(text)
            }
            .sorted { $0.added > $1.added }
    }

    /// How many samples the corpus holds, without reading any of them. The
    /// rail's badge is recomputed on every dashboard refresh, and parsing the
    /// whole corpus for a number nobody clicks would put the walk the Voice
    /// page does on every other page too.
    public func sampleCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: samplesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.count
    }

    public func delete(id: String) throws {
        guard let file = existingURL(id: id) else { return }
        try FileManager.default.removeItem(at: file)
    }

    // MARK: - Fingerprint (voice.md §3.3)

    /// A stable digest of the whole corpus. The profile stores the one it was
    /// built from, so a rebuild happens when the samples change and never on a
    /// timer.
    ///
    /// FNV-1a rather than `Hasher`: Swift seeds `hashValue` per process, so a
    /// fingerprint written by the analyzer would differ from the one the app
    /// computes a second later and the profile would rebuild forever.
    public func fingerprint() -> String {
        Self.digest(of: samples())
    }

    public static func digest(of samples: [VoiceSample]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples.sorted(by: { $0.id < $1.id }) {
            for byte in (sample.id + "\u{1}" + sample.text + "\u{2}").utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    // MARK: - Profile

    public func profile() -> VoiceProfile? {
        guard let text = try? String(contentsOf: profileURL, encoding: .utf8) else { return nil }
        return VoiceProfile.parse(text)
    }

    public func saveProfile(_ profile: VoiceProfile) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try profile.serialize().write(to: profileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - File layout

    func url(for sample: VoiceSample) -> URL {
        let slug = sample.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { accumulated, character in
                if character != "-" || accumulated.last != "-" { accumulated.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return samplesDirectory
            .appendingPathComponent("\(sample.id.lowercased())-\(slug.prefix(40)).md")
    }

    func existingURL(id: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: samplesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(id.lowercased()) }
    }

    /// A title the file name can survive. An untitled paste is named after its
    /// own first few words, which is what the user would have typed anyway.
    private func cleanTitle(_ title: String, fallback body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.isEmpty else { return String(trimmed.prefix(80)) }
        let opening = VoiceMetrics.words(in: body).prefix(7).joined(separator: " ")
        return opening.isEmpty ? "Untitled" : String(opening.prefix(80))
    }
}

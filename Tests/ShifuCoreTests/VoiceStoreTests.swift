import Foundation
import Testing
@testable import ShifuCore

/// The corpus on disk (voice.md §2): the ingest door, the redaction that
/// happens there, and the fingerprint the profile's staleness rests on.
@Suite struct VoiceStoreTests {
    private func scratch() throws -> VoiceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-voice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VoiceStore(root: dir)
    }

    private func passage(_ words: Int) -> String {
        (0..<words).map { "word\($0 % 40)" }.joined(separator: " ") + "."
    }

    // MARK: - Ingest

    @Test func roundTripsASampleThroughTheFile() throws {
        let store = try scratch()
        let saved = try store.add(title: "Reply to Sam", text: passage(60))
        let loaded = try #require(store.samples().first)
        #expect(loaded.id == saved.id)
        #expect(loaded.title == "Reply to Sam")
        #expect(loaded.source == .paste)
        #expect(loaded.text == saved.text)
        #expect(loaded.wordCount >= 60)
    }

    @Test func refusesSamplesUnderTheFloorWithAReason() throws {
        let store = try scratch()
        #expect(throws: VoiceStore.IngestError.self) {
            try store.add(title: "Too short", text: "Three words only.")
        }
        #expect(store.samples().isEmpty)
        #expect(store.sampleCount() == 0)
    }

    @Test func redactsAtTheDoorSoTheFileItselfIsClean() throws {
        // Invariant 2, and the reason it is here rather than in prompt
        // assembly: a redaction the user can see is one they can act on.
        let store = try scratch()
        let text = passage(50) + " My card is 4111 1111 1111 1111 and the key is "
            + "sk-abcdefghijklmnop."
        try store.add(title: "Leaky", text: text)
        let loaded = try #require(store.samples().first)
        #expect(loaded.text.contains("[REDACTED:CARD]"))
        #expect(loaded.text.contains("[REDACTED:KEY]"))
        #expect(!loaded.text.contains("4111"))
    }

    @Test func namesAnUntitledPasteAfterItsOwnOpeningWords() throws {
        let store = try scratch()
        let sample = try store.add(title: "   ", text: "Right, here is the thing I keep "
            + "meaning to say about the release. " + passage(40))
        #expect(sample.title.hasPrefix("Right, here is"))
    }

    @Test func importsAFileAndTitlesItFromTheFilename() throws {
        let store = try scratch()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("standup-notes-\(UUID().uuidString).md")
        try passage(80).write(to: file, atomically: true, encoding: .utf8)
        let sample = try store.importFile(at: file)
        #expect(sample.source == .importedFile)
        #expect(sample.title.hasPrefix("standup-notes"))
        #expect(store.sampleCount() == 1)
    }

    @Test func deletesTheFileItself() throws {
        let store = try scratch()
        let sample = try store.add(title: "Gone soon", text: passage(60))
        try store.delete(id: sample.id)
        #expect(store.samples().isEmpty)
        #expect(store.sampleCount() == 0)
    }

    @Test func skipsFilesThatAreNotSamples() throws {
        // The corpus directory is the user's; a stray document in it must not
        // be read as writing they claimed as theirs.
        let store = try scratch()
        try store.add(title: "Real", text: passage(60))
        try FileManager.default.createDirectory(
            at: store.samplesDirectory, withIntermediateDirectories: true)
        try "no frontmatter here at all".write(
            to: store.samplesDirectory.appendingPathComponent("stray.md"),
            atomically: true, encoding: .utf8)
        #expect(store.samples().count == 1)
    }

    // MARK: - Fingerprint (voice.md §3.3)

    @Test func fingerprintMovesOnlyWhenTheCorpusDoes() throws {
        let store = try scratch()
        let first = try store.add(title: "One", text: passage(60))
        let before = store.fingerprint()
        #expect(store.fingerprint() == before)          // stable across reads
        try store.add(title: "Two", text: passage(70))
        let after = store.fingerprint()
        #expect(after != before)
        try store.delete(id: first.id)
        #expect(store.fingerprint() != after)
    }

    @Test func fingerprintIsOrderIndependentAndProcessStable() throws {
        // FNV-1a rather than `Hasher`: Swift seeds `hashValue` per process, so
        // a per-process digest would rebuild the profile forever.
        let one = VoiceSample(id: "AAA", title: "a", text: "first text")
        let two = VoiceSample(id: "BBB", title: "b", text: "second text")
        #expect(VoiceStore.digest(of: [one, two]) == VoiceStore.digest(of: [two, one]))
        #expect(VoiceStore.digest(of: [one]) != VoiceStore.digest(of: [two]))
        // A literal, deliberately: this is the one assertion that would still
        // pass if the digest were per-process, and it is the failure that
        // rebuilds the profile on every analyzer run forever.
        #expect(VoiceStore.digest(of: [one, two]) == "3316eeb592493038")
    }

    // MARK: - The profile document

    @Test func profileRoundTripsThroughItsFile() throws {
        let store = try scratch()
        try store.add(title: "One", text: passage(60))
        let metrics = VoiceMetrics.measure(store.samples().map(\.text))
        let profile = VoiceProfile(
            built: Date(timeIntervalSince1970: 1_760_000_000),
            fingerprint: store.fingerprint(), sampleCount: 1, wordCount: metrics.words,
            card: "## Register\nBlunt, unhedged.\n\n## Avoid\nExclamation marks.",
            measured: metrics.readings)
        try store.saveProfile(profile)
        let loaded = try #require(store.profile())
        #expect(loaded.fingerprint == profile.fingerprint)
        #expect(loaded.sampleCount == 1)
        #expect(loaded.card == profile.card)
        #expect(loaded.measured == profile.measured)
        #expect(!loaded.isStale(against: store.fingerprint()))
    }

    @Test func aProfileWithNoCardDoesNotReadBackAsDescribed() throws {
        // The file writes a placeholder line where the card would be, and
        // round-tripping that as a card would make a never-described profile
        // look described — and put "no description yet" into the prompt.
        let store = try scratch()
        let profile = VoiceProfile(fingerprint: "abc", sampleCount: 0, wordCount: 0)
        try store.saveProfile(profile)
        let loaded = try #require(store.profile())
        #expect(!loaded.hasCard)
        #expect(loaded.card.isEmpty)
    }

    @Test func addingASampleMakesAnExistingProfileStale() throws {
        let store = try scratch()
        try store.add(title: "One", text: passage(60))
        try store.saveProfile(VoiceProfile(
            fingerprint: store.fingerprint(), sampleCount: 1, wordCount: 60, card: "## Register"))
        #expect(store.profile()?.isStale(against: store.fingerprint()) == false)
        try store.add(title: "Two", text: passage(60))
        #expect(store.profile()?.isStale(against: store.fingerprint()) == true)
    }
}

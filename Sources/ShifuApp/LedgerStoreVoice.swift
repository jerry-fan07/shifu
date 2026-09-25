import Foundation
import ShifuCore

/// The Voice place's half of the read-side model (voice.md §5): the corpus
/// walk, the ingest door, and the draft request. Split out of
/// LedgerStore.swift for length only; `refreshVoice` stays there because it
/// writes the store's own `private(set)` state.
@MainActor
extension LedgerStore {
    var voice: VoiceStore { VoiceStore() }

    /// Everything one corpus walk yields, so the walk can live out here.
    struct VoiceSnapshot {
        var samples: [VoiceSample] = []
        var metrics = VoiceMetrics()
        var profile: VoiceProfile?
    }

    func voiceSnapshot() -> VoiceSnapshot {
        let store = voice
        var snapshot = VoiceSnapshot()
        snapshot.samples = store.samples()
        snapshot.metrics = VoiceMetrics.measure(snapshot.samples.map(\.text))
        snapshot.profile = store.profile()
        return snapshot
    }

    /// Whether the described half of the profile is out of date — the corpus
    /// has moved since the card was written, or no card exists yet. The page
    /// says so rather than presenting a stale description as current.
    var voiceProfileIsStale: Bool {
        guard !voiceSamples.isEmpty else { return false }
        guard let profile = voiceProfile, profile.hasCard else { return true }
        return profile.isStale(against: VoiceStore.digest(of: voiceSamples))
    }

    // MARK: - The corpus (voice.md §2.2)

    /// Adds a pasted sample. Refusals come back on `voiceNotice` rather than
    /// as a thrown error: the user is looking at the button they pressed, and
    /// "25 words is the floor" is an answer, not a failure.
    func addVoiceSample(title: String, text: String) {
        do {
            try voice.add(title: title, text: text)
            voiceNotice = nil
        } catch let error as VoiceStore.IngestError {
            voiceNotice = error.description
        } catch {
            voiceNotice = "\(error)"
        }
        refreshVoice()
    }

    /// The file importer's drop. Each file is judged on its own — one short
    /// file must not throw away the four good ones beside it — and the notice
    /// names the ones that didn't make it.
    func importVoiceSamples(_ files: [URL]) {
        var refused: [String] = []
        for file in files {
            // Harmless outside a sandbox (Shifu ships Developer ID), and the
            // difference between working and silently reading nothing inside
            // one. Both reads below happen inside this window — the PDF one
            // especially, since PDFKit opens the file lazily.
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                if file.pathExtension.lowercased() == "pdf" {
                    try voice.add(
                        title: file.deletingPathExtension().lastPathComponent,
                        text: try VoicePDF.prose(at: file), source: .importedFile)
                } else {
                    try voice.importFile(at: file)
                }
            } catch {
                refused.append("\(file.lastPathComponent): \(error)")
            }
        }
        voiceNotice = refused.isEmpty ? nil : refused.joined(separator: "  ·  ")
        refreshVoice()
    }

    func deleteVoiceSample(id: String) {
        try? voice.delete(id: id)
        voiceNotice = nil
        refreshVoice()
    }

    // MARK: - Drafting (voice.md §4.1)

    /// Records the request and asks the analyzer to write it. Only that binary
    /// may reach the network (§8), so pressing Draft is a launch of it.
    ///
    /// Like `buildDeck` this carries no throttle: the row's own
    /// compare-and-set is the guard, and it holds across processes where a
    /// timestamp in this object only knows about the launches it made itself.
    /// Unlike `buildDeck` it does not stand down for an already-running
    /// process either — a deck build is asked for once per deck and can wait
    /// for the hourly drain, where a draft has someone watching the button.
    func requestDraft(prompt: String) {
        guard let database = try? db(),
              let id = try? VoiceDrafts.request(prompt: prompt, database: database)
        else { return }
        voiceNotice = nil
        launchDrafter(id: id)
        refreshVoice()
    }

    /// One analyzer run per request. `voiceDraftProcess` holds only the newest
    /// — it is there to keep the object alive to its exit, not to gate a
    /// second launch.
    private func launchDrafter(id: Int64) {
        guard let analyzerURL = ShifuPaths.helper("shifu-analyzer") else { return }
        let process = Process()
        process.executableURL = analyzerURL
        process.arguments = ["--force", "--draft", String(id)]
        process.qualityOfService = .userInitiated
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        do {
            try process.run()
            voiceDraftProcess = process
        } catch {
            report(error)
        }
    }

    func deleteDraft(id: Int64) {
        if let database = try? db() {
            try? VoiceDrafts.delete(id: id, database: database)
        }
        refreshSoon()
    }
}

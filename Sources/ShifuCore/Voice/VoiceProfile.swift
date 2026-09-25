import Foundation

/// The derived profile on disk — `~/Shifu/voice/profile.md` (voice.md §3).
///
/// Two halves. The **measured** block is a rendering of `VoiceMetrics`, kept
/// in the file so the document reads as a document; nothing depends on parsing
/// it back, because metrics are pure and recomputed from the corpus whenever
/// anything needs them. The **described** block is the LLM's voice card, and
/// it is the only thing here that cannot be regenerated for free — which is
/// what the file exists to persist, alongside the `fingerprint` that says
/// which corpus it was written from.
public struct VoiceProfile: Equatable, Sendable {
    public var built: Date
    /// The corpus digest this was written from (`VoiceStore.fingerprint`).
    /// Different from the corpus's current digest means stale, and staleness
    /// is the only thing that triggers a rebuild — never a timer (§3.3).
    public var fingerprint: String
    public var sampleCount: Int
    public var wordCount: Int
    /// The LLM's voice card, markdown. Empty when no backend has described the
    /// corpus yet — a legitimate, permanent state on an install with the
    /// backend set to `off`, where the measured half stands alone.
    public var card: String
    public var measured: [VoiceMetrics.Reading]

    public init(
        built: Date = Date(), fingerprint: String, sampleCount: Int, wordCount: Int,
        card: String = "", measured: [VoiceMetrics.Reading] = []
    ) {
        self.built = built
        self.fingerprint = fingerprint
        self.sampleCount = sampleCount
        self.wordCount = wordCount
        self.card = card
        self.measured = measured
    }

    public func isStale(against current: String) -> Bool { fingerprint != current }

    public var hasCard: Bool { !card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Serialization

    public func serialize() -> String {
        var lines = [
            "---",
            "kind: voice_profile",
            "built: \(Note.iso.string(from: built))",
            "fingerprint: \(fingerprint)",
            "samples: \(sampleCount)",
            "words: \(wordCount)",
            "---",
            "",
            "## Measured"
        ]
        lines.append("")
        for reading in measured {
            lines.append("- **\(reading.label)** — \(reading.value)")
        }
        lines.append("")
        lines.append("## Described")
        lines.append("")
        lines.append(hasCard
            ? card.trimmingCharacters(in: .whitespacesAndNewlines)
            : "_No description yet — this half needs an LLM backend (Settings)._")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) -> VoiceProfile? {
        guard let doc = FrontMatter.parse(text),
              doc.fields["kind"] == "voice_profile",
              let fingerprint = doc.fields["fingerprint"] else { return nil }
        let halves = doc.body.components(separatedBy: "\n## Described")
        let described = halves.count > 1
            ? halves[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return VoiceProfile(
            built: doc.fields["built"].flatMap { Note.iso.date(from: $0) } ?? Date(),
            fingerprint: fingerprint,
            sampleCount: doc.fields["samples"].flatMap(Int.init) ?? 0,
            wordCount: doc.fields["words"].flatMap(Int.init) ?? 0,
            // The placeholder is not a card. Round-tripping it would make a
            // never-described profile look described, and the drafting prompt
            // would then carry a line saying there is no description.
            card: described.hasPrefix("_No description") ? "" : described,
            measured: readings(in: halves.first ?? "")
        )
    }

    private static func readings(in measured: String) -> [VoiceMetrics.Reading] {
        measured.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- **"),
                  let close = line.range(of: "** — ") else { return nil }
            let label = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
            return VoiceMetrics.Reading(
                label: label, value: String(line[close.upperBound...]))
        }
    }
}

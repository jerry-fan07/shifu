import ShifuCore
import SwiftUI
import UniformTypeIdentifiers

// The right-hand column of the Voice place, and the two doors text comes in
// through (voice.md §2.2, §5). Split from VoiceView.swift for length only.

/// What Shifu knows about how the user writes: the measurements, the described
/// card, and the samples both are drawn from. Shown whether or not a backend
/// exists — the measured half needs nothing but the files.
struct VoiceCorpusColumn: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            measured
            described
            samples
            VoiceAddRow()
                .padding(.top, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Your writing")
            Figure("\(store.voiceSamples.count) sample"
                + (store.voiceSamples.count == 1 ? "" : "s")
                + " · \(store.voiceMetrics.words) words")
            if !store.voiceMetrics.isMeaningful {
                Text(floorNote)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// What a short corpus is and isn't used for. Two floors, so two messages:
    /// a length *spread* holds up on twenty sentences, where a rate or an
    /// absence needs the whole corpus before it stops being a guess.
    private var floorNote: String {
        let head = "Under \(VoiceMetrics.meaningfulWords) words. "
        guard store.voiceMetrics.sentences >= VoiceMetrics.rhythmSentences else {
            return head + "Measured below, but none of it is told to the model yet — "
                + "habits drawn from this little text would be invented, and obeyed."
        }
        return head + "The sentence spread and rhythm below are told to the model — "
            + "those hold up at this size. The rates and absences are not, because "
            + "habits drawn from this little text would be invented, and obeyed."
    }

    // MARK: Measured

    private var measured: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule(weight: .section)
            Eyebrow("Measured")
                .padding(.top, 11)
                .padding(.bottom, 6)
            ForEach(store.voiceMetrics.readings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(reading.label)
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.faint)
                        .frame(width: 104, alignment: .leading)
                    Text(reading.value)
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.bottom, 13)
    }

    // MARK: Described

    private var described: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule(weight: .section)
            Eyebrow("Described")
                .padding(.top, 11)
                .padding(.bottom, 6)
            if let profile = store.voiceProfile, profile.hasCard {
                CardTextView(text: profile.card, baseSize: 12)
                if store.voiceProfileIsStale {
                    Text("Written before your last change to the samples — the next "
                        + "draft rebuilds it.")
                        .font(Instrument.sans(11))
                        .foregroundStyle(Instrument.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }
            } else {
                Text(store.hasLLMBackend
                    ? "Not written yet. The next draft, or the next hourly analysis, "
                        + "describes what the numbers above cannot — how you open, how "
                        + "you hedge, how you end."
                    : "This half needs a backend (Settings). The measurements above "
                        + "stand on their own.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 13)
    }

    // MARK: Samples

    private var samples: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule(weight: .section)
            Eyebrow("Samples")
                .padding(.top, 11)
                .padding(.bottom, 2)
            ForEach(store.voiceSamples) { sample in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.title)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                        Figure("\(sample.wordCount) words · "
                            + sample.added.formatted(.dateTime.month().day()),
                               size: 10.5, color: Instrument.ghost)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.deleteVoiceSample(id: sample.id)
                    } label: {
                        Text("✕")
                            .font(Instrument.sans(11))
                            .foregroundStyle(Instrument.faint)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(sample.title)")
                }
                .padding(.vertical, 7)
                Rule()
            }
        }
    }
}

// MARK: - Getting text in

/// The two doors (voice.md §2.2). Both are explicit, because the corpus is
/// only ever what the user chose to hand over.
struct VoiceAddRow: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var pasting = false
    @State private var importing = false

    var body: some View {
        HStack(spacing: 12) {
            SolidButton(title: "Paste writing") { pasting = true }
            OutlineButton(title: "Import files…") { importing = true }
        }
        .padding(.top, 12)
        .sheet(isPresented: $pasting) {
            VoicePasteSheet { title, text in
                store.addVoiceSample(title: title, text: text)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: VoiceAddRow.readableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let files) = result { store.importVoiceSamples(files) }
        }
    }

    /// Plain text, Markdown, and PDF. PDFs go through `VoicePDF` and the
    /// reflow pass in `VoiceImportText`, because raw extraction "would put
    /// layout artefacts into the corpus the metrics then measure as style" —
    /// which was this list's reason for excluding them, and is now the spec for
    /// the pass that lets them in.
    ///
    /// Still not `.rtf` or `.docx`. `NSAttributedString` reads both in two
    /// lines, so this is a minimalism call rather than a technical one — nobody
    /// has asked yet (voice.md §9).
    static let readableTypes: [UTType] = {
        var types: [UTType] = [.plainText, .pdf]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }()
}

/// Pasting one piece of writing. A title field and a box — the title is
/// optional, because the common case is a mail the user already has in the
/// clipboard and does not want to name.
struct VoicePasteSheet: View {
    let add: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add writing")
                .font(Instrument.sans(15, .semibold))
                .foregroundStyle(Instrument.ink)
            Text("Something you wrote yourself, in the register you want drafts in. "
                + "Card numbers and keys are removed before it is saved.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.plain)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
                .padding(.top, 14)
            TextEditor(text: $text)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 260)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
                .padding(.top, 8)
            HStack(spacing: 12) {
                Figure("\(VoiceSample.words(in: text)) / "
                    + "\(VoiceStore.minimumSampleWords) words",
                       size: 11, color: Instrument.ghost)
                Spacer(minLength: 0)
                OutlineButton(title: "Cancel") { dismiss() }
                SolidButton(title: "Add") {
                    add(title, text)
                    dismiss()
                }
                .opacity(canAdd ? 1 : 0.35)
                .allowsHitTesting(canAdd)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 520)
        .background(Instrument.ground)
    }

    private var canAdd: Bool {
        VoiceSample.words(in: text) >= VoiceStore.minimumSampleWords
    }
}

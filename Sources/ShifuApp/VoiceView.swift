import AppKit
import ShifuCore
import SwiftUI

/// The *Voice* place (voice.md §5): writing the user has handed over, what it
/// measures, and a desk that drafts in the same register.
///
/// Two columns, on the `NewDeckPage` pattern — what you are asking for on the
/// left, what Shifu knows about you on the right. The right column is not
/// decoration: without a backend it is the whole page, and it is still worth
/// arriving at.
struct VoiceView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "Voice",
                subtitle: "Shifu reads writing you have already done, and drafts new "
                    + "writing that sounds like it came from the same hand."
            ) {
                if !store.hasLLMBackend {
                    // Without a backend nothing could write the draft, and the
                    // request would sit "Drafting…" forever — the same gate
                    // the deck form uses.
                    Text("Drafting needs DeepSeek (Settings)")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.ghost)
                }
            }
            PageBody {
                if let notice = store.voiceNotice {
                    Text(notice)
                        .font(Instrument.sans(12))
                        .foregroundStyle(Instrument.alert)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                if store.voiceSamples.isEmpty {
                    BlankSlate(
                        "Nothing to go on yet. Hand over a few pieces of your own "
                            + "writing — a mail you sent, a message, a page of notes — "
                            + "and Shifu will measure how you write and draft in the "
                            + "same voice. Nothing is taken from your screen: this "
                            + "corpus is only what you put in it.")
                    VoiceAddRow()
                } else {
                    HStack(alignment: .top, spacing: 36) {
                        VoiceDesk()
                        VoiceCorpusColumn()
                            .frame(width: 330)
                    }
                }
            }
        }
        .onAppear { store.refreshVoice() }
    }
}

// MARK: - The desk

/// Ask for something, get it back in your own register. The prompt box is the
/// page's one real control; everything under it is history.
private struct VoiceDesk: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var request = ""
    @State private var copied: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("What to write")
                .padding(.top, 16)
                .padding(.bottom, 7)
            TextEditor(text: $request)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 104)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
            Text("Say what it is and who it is for — \"reply to Sam declining the "
                + "Thursday call\". Paste something in to have it rewritten in your "
                + "own words.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            actions
            ForEach(Array(store.voiceDrafts.enumerated()), id: \.element.id) { index, draft in
                Rule(weight: index == 0 ? .section : .row)
                draftBlock(draft, latest: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if store.hasLLMBackend {
                SolidButton(title: running ? "Drafting…" : "Draft") { send() }
                    .opacity(canSend ? 1 : 0.35)
                    .allowsHitTesting(canSend)
            }
            if running {
                Text("The analyzer is writing it — this page updates when it lands.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.faint)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The *newest* request only. Deliberately not "any request is running":
    /// a row whose analyzer died sits `drafting` until the stale-claim window
    /// passes and the hourly drain takes it, and a queue-wide test would read
    /// that as "still working" for an hour.
    private var running: Bool { store.voiceDrafts.first?.isRunning == true }

    /// Asking for something else while one draft is in flight is intentional
    /// and safe — each row is claimed separately (`VoiceDrafts.claim`), so a
    /// second request cannot collide with the first. What is *not* intentional
    /// is pressing Draft twice on the same text, so that is the only thing
    /// blocked: without it, a request stuck `pending` (an analyzer that never
    /// launched) would leave this button inert until the next hourly pass.
    private var canSend: Bool {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let newest = store.voiceDrafts.first, newest.isRunning else { return true }
        return newest.prompt != trimmed
    }

    private func send() {
        store.requestDraft(prompt: request)
    }

    /// One request and whatever became of it. The latest is open; the ones
    /// behind it keep their text too — a desk with four drafts on it is the
    /// normal way this gets used, and collapsing them would mean re-asking.
    private func draftBlock(_ draft: VoiceDrafts.Draft, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(draft.prompt)
                    .font(Instrument.sans(12.5, latest ? .medium : .regular))
                    .foregroundStyle(latest ? Instrument.ink : Instrument.secondary)
                    .lineLimit(latest ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Figure(stamp(draft), size: 11, color: Instrument.ghost)
                    .fixedSize()
            }
            switch draft.status {
            case .pending, .drafting:
                Text("Drafting…")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
                    .padding(.top, 8)
            case .failed:
                Text(draft.error ?? "Failed.")
                    .font(Instrument.sans(12))
                    .foregroundStyle(Instrument.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            case .ready:
                CardTextView(text: draft.result ?? "", baseSize: 13)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.top, 9)
            }
            HStack(spacing: 14) {
                if draft.status == .ready, let result = draft.result {
                    SolidButton(title: copied == draft.id ? "Copied ✓" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                        copied = draft.id
                    }
                }
                OutlineButton(title: "Delete") { store.deleteDraft(id: draft.id) }
            }
            .padding(.top, 11)
        }
        .padding(.top, 15)
        .padding(.bottom, 14)
    }

    private func stamp(_ draft: VoiceDrafts.Draft) -> String {
        let moment = Date(timeIntervalSince1970: Double(draft.createdAt) / 1_000)
        return moment.formatted(.dateTime.hour().minute())
    }
}

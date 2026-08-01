import ShifuCore
import SwiftUI

/// The review session (design.md §5.2), in its own window: one card at a time,
/// centred, with nothing on screen but the card and the four grades. The
/// session snapshots its queue up front — "Again" cards rotate to the back
/// instead of blocking the front, and a background refresh can't shuffle the
/// card out from under the user.
struct ReviewSessionView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var queue: [String] = []
    @State private var reviewed = 0
    @State private var revealed = false
    @State private var editing: Note?
    @State private var confirmingDelete = false

    /// First queued card that is still due — edits, deletions, and external
    /// changes drop out naturally instead of showing a stale card.
    private var current: Note? {
        let due = store.deckDueNotes
        for noteID in queue {
            if let note = due.first(where: { $0.id == noteID }) { return note }
        }
        return nil
    }

    private var remaining: Int {
        let dueIDs = Set(store.deckDueNotes.map(\.id))
        return queue.filter(dueIDs.contains).count
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            Rule(weight: .section)
            if let note = current, let pair = note.questionAnswer {
                card(note: note, question: pair.question, answer: pair.answer)
                Rule(weight: .section)
                controls(note: note)
            } else {
                done
            }
        }
        .background(Instrument.ground)
        .frame(minWidth: 480, minHeight: 440)
        .onAppear {
            store.refresh()
            start()
        }
        // A new card on screen must never start revealed.
        .onChange(of: current?.id) { _, _ in revealed = false }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
        .confirmationDialog(
            "Delete this card permanently?", isPresented: $confirmingDelete
        ) {
            Button("Delete card", role: .destructive) { deleteCurrent() }
        }
    }

    /// The deck, and how far along you are — which a bare "n left" never says.
    private var progress: some View {
        HStack(spacing: 10) {
            Text(store.reviewDeck.label)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .lineLimit(1)
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Capsule().fill(Instrument.well)
                Capsule()
                    .fill(Instrument.accent)
                    .frame(width: 120 * fraction)
            }
            .frame(width: 120, height: 4)
            Figure("\(reviewed) done · \(remaining) left", size: 11, color: Instrument.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Instrument.rail)
    }

    private var fraction: CGFloat {
        let total = max(1, reviewed + remaining)
        return CGFloat(reviewed) / CGFloat(total)
    }

    /// Centred in whatever room is left, but still scrollable: a card can
    /// carry a code block taller than the window (§5.2).
    private func card(note: Note, question: String, answer: String) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    Eyebrow(note.topic)
                    CardTextView(
                        text: question, baseSize: 19, alignment: .center,
                        color: Instrument.ink)
                    if revealed {
                        Rectangle()
                            .fill(Instrument.edge)
                            .frame(width: 120, height: 1)
                        CardTextView(text: answer, baseSize: 14.5, alignment: .center)
                        if let source = note.sourceURL, let url = URL(string: source) {
                            Link(destination: url) {
                                Figure(url.host() ?? source, size: 11,
                                       color: Instrument.accentText)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    private func controls(note: Note) -> some View {
        VStack(spacing: 10) {
            if revealed {
                HStack(spacing: 8) {
                    ForEach(FSRS.Grade.allCases, id: \.rawValue) { grade in
                        gradeButton(grade, note: note)
                    }
                }
            } else {
                Button("Reveal answer") { revealed = true }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.plain)
                    .font(Instrument.sans(12.5, .medium))
                    .foregroundStyle(Instrument.solidInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Instrument.solidFill, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                sessionAction("Edit", key: "e") { editing = note }
                sessionAction("Skip", key: "s") { skip(note) }
                sessionAction("Delete", key: nil) { confirmingDelete = true }
                Spacer()
                Figure(
                    revealed ? "1–4 grades · E edits · S skips" : "space reveals",
                    size: 10.5, color: Instrument.ghost)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sessionAction(
        _ title: String, key: Character?, action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
        }
        .buttonStyle(.plain)
        return Group {
            if let key {
                button.keyboardShortcut(KeyEquivalent(key), modifiers: [])
            } else {
                button
            }
        }
    }

    /// Each grade shows what FSRS would actually schedule, so grading is an
    /// informed choice rather than a guess about the algorithm.
    private func gradeButton(_ grade: FSRS.Grade, note: Note) -> some View {
        let isDefault = grade == .good
        return Button {
            apply(grade, to: note)
        } label: {
            VStack(spacing: 1) {
                Text(Self.gradeLabel(grade))
                    .font(Instrument.sans(12.5, isDefault ? .semibold : .medium))
                    .foregroundStyle(isDefault ? Instrument.accentDeep : Instrument.ink)
                Figure(
                    Self.intervalPreview(note: note, grade: grade),
                    size: 10.5, color: isDefault ? Instrument.accentText : Instrument.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                isDefault ? Instrument.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDefault ? Instrument.accent : Instrument.edge, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(grade.rawValue)")), modifiers: [])
    }

    private var done: some View {
        VStack(spacing: 12) {
            Text(reviewed > 0 ? "\(reviewed) reviewed" : "Nothing due")
                .font(Instrument.sans(18, .semibold))
                .foregroundStyle(Instrument.ink)
            Text(store.deckDueNotes.isEmpty
                ? (reviewed > 0
                    ? "Enough for today."
                    : "The deck rests until the next card comes round.")
                : "More cards became due while you reviewed.")
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.muted)
            if !store.deckDueNotes.isEmpty {
                SolidButton(title: "Review \(store.deckDueNotes.count) more") { start() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    // MARK: - Session actions

    private func start() {
        queue = store.deckDueNotes.map(\.id)
        reviewed = 0
        revealed = false
    }

    private func apply(_ grade: FSRS.Grade, to note: Note) {
        store.review(note, grade: grade)
        reviewed += 1
        revealed = false
        if grade == .again {
            moveToBack(note.id)   // relearn later this session, not immediately
        } else {
            queue.removeAll { $0 == note.id }
        }
    }

    private func skip(_ note: Note) {
        moveToBack(note.id)
        revealed = false
    }

    private func deleteCurrent() {
        guard let note = current else { return }
        store.discard(note)
        queue.removeAll { $0 == note.id }
    }

    private func moveToBack(_ noteID: String) {
        queue.removeAll { $0 == noteID }
        queue.append(noteID)
    }

    static func gradeLabel(_ grade: FSRS.Grade) -> String {
        switch grade {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    /// What FSRS would schedule for each grade.
    static func intervalPreview(note: Note, grade: FSRS.Grade, now: Date = Date()) -> String {
        let next = FSRS.review(note.srs ?? FSRS.State(due: now), grade: grade, now: now)
        let days = Int(next.intervalDays)
        if days < 1 { return "today" }
        return days >= 30 ? "\(days / 30) mo" : "\(days) d"
    }
}

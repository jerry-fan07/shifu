import ShifuCore
import SwiftUI

/// Card review session (design.md §5.2). Draws from the deck picked on the
/// Cards home screen. The session snapshots its queue up front: "Again"
/// cards rotate to the back instead of blocking the front, and background
/// refreshes can't shuffle the card underneath the user.
struct ReviewSessionView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var queue: [String] = []
    @State private var reviewedCount = 0
    @State private var revealed = false
    @State private var editingCard: Note?
    @State private var confirmingDelete = false

    /// First queued card that is still due — edits, deletions, and external
    /// changes drop out naturally instead of showing a stale card.
    private var currentNote: Note? {
        let due = store.deckDueNotes
        for noteID in queue {
            if let note = due.first(where: { $0.id == noteID }) { return note }
        }
        return nil
    }

    private var remainingCount: Int {
        let dueIDs = Set(store.deckDueNotes.map(\.id))
        return queue.filter(dueIDs.contains).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let note = currentNote, let qa = note.questionAnswer {
                // Centred in whatever room is left, but still scrollable: a card
                // can carry a code block taller than the window (§5.2).
                GeometryReader { proxy in
                    ScrollView {
                        VStack {
                            Spacer(minLength: 0)
                            cardContent(note: note, question: qa.question, answer: qa.answer)
                                .dojoCard(padding: 0)
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(minHeight: proxy.size.height)
                    }
                }
                Divider()
                controls(note: note)
            } else {
                doneView
            }
        }
        .background(Dojo.paper)
        .frame(minWidth: 460, minHeight: 400)
        .onAppear {
            store.refresh()
            startSession()
        }
        // A new card on screen must never start revealed.
        .onChange(of: currentNote?.id) { _, _ in revealed = false }
        .sheet(item: $editingCard) { note in
            CardEditSheet(note: note)
        }
        .confirmationDialog(
            "Delete this card permanently?", isPresented: $confirmingDelete
        ) {
            Button("Delete card", role: .destructive) { deleteCurrent() }
        }
    }

    /// Deck, counts, and the session's own progress bar — how far along the
    /// climb you are, which a bare "n left" never quite says.
    private var header: some View {
        VStack(spacing: 7) {
            HStack {
                Eyebrow(store.reviewDeck.label)
                Spacer()
                Text("\(reviewedCount) done · \(remainingCount) left")
                    .font(Dojo.label(10))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                let total = max(1, reviewedCount + remainingCount)
                Capsule()
                    .fill(Dojo.well)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Dojo.accent)
                            .frame(
                                width: proxy.size.width
                                    * CGFloat(reviewedCount) / CGFloat(total))
                    }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func cardContent(note: Note, question: String, answer: String) -> some View {
        VStack(spacing: 14) {
            Text(note.topic)
                .font(.caption)
                .foregroundStyle(.secondary)
            CardTextView(text: question, baseSize: 15, alignment: .center)
            if revealed {
                Divider().frame(width: 160)
                CardTextView(text: answer, alignment: .center)
                if let source = note.sourceURL, let url = URL(string: source) {
                    Link(destination: url) {
                        Label(url.host() ?? source, systemImage: "link")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func controls(note: Note) -> some View {
        VStack(spacing: 8) {
            if revealed {
                HStack(spacing: 10) {
                    ForEach(FSRS.Grade.allCases, id: \.rawValue) { grade in
                        gradeButton(grade, note: note)
                    }
                }
            } else {
                Button("Reveal answer") { revealed = true }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                Button("Edit", systemImage: "pencil") { editingCard = note }
                    .keyboardShortcut("e", modifiers: [])
                    .help("Edit this card (E)")
                Button("Skip", systemImage: "arrow.uturn.forward") { skip(note) }
                    .keyboardShortcut("s", modifiers: [])
                    .help("Move to the back of the session (S)")
                Button("Delete", systemImage: "trash") { confirmingDelete = true }
                    .help("Delete this card")
                Spacer()
                Text(revealed ? "1–4 grades" : "Space reveals")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func gradeButton(_ grade: FSRS.Grade, note: Note) -> some View {
        Button {
            applyGrade(grade, to: note)
        } label: {
            VStack(spacing: 1) {
                Text(Self.gradeLabel(grade))
                Text(Self.intervalPreview(note: note, grade: grade))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 52)
        }
        .keyboardShortcut(KeyEquivalent(Character("\(grade.rawValue)")), modifiers: [])
    }

    private var doneView: some View {
        SenseiEmptyState(
            reviewedCount > 0 ? "Done — \(reviewedCount) reviewed" : "Nothing due",
            message: store.deckDueNotes.isEmpty
                ? (reviewedCount > 0
                    ? "Enough for today. Water the mind, then rest."
                    : "The deck rests. Return when cards are due.")
                : "More cards became due while you reviewed.",
            mood: reviewedCount > 0 ? .proud : .serene
        ) {
            if !store.deckDueNotes.isEmpty {
                Button("Review \(store.deckDueNotes.count) more") { startSession() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Session actions

    private func startSession() {
        queue = store.deckDueNotes.map(\.id)
        reviewedCount = 0
        revealed = false
    }

    private func applyGrade(_ grade: FSRS.Grade, to note: Note) {
        store.review(note, grade: grade)
        reviewedCount += 1
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
        guard let note = currentNote else { return }
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

    /// What FSRS would schedule for each grade — shown under the buttons so
    /// grading is an informed choice.
    static func intervalPreview(note: Note, grade: FSRS.Grade, now: Date = Date()) -> String {
        let next = FSRS.review(note.srs ?? FSRS.State(due: now), grade: grade, now: now)
        let days = Int(next.intervalDays)
        if days < 1 { return "today" }
        return days >= 30 ? "\(days / 30) mo" : "\(days) d"
    }
}

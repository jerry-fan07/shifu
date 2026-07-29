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
                ScrollView {
                    cardContent(note: note, question: qa.question, answer: qa.answer)
                        .dojoCard(padding: 0)
                        .padding(16)
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

    private var header: some View {
        HStack {
            Text("Deck: \(store.reviewDeck.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(reviewedCount) done · \(remainingCount) left")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

/// Inbox triage, its own screen (design.md §5.1): keep/edit/discard each
/// candidate; K and D act on the top one. Bodies render with the same math
/// and code formatting the review session uses.
struct InboxView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editingCard: Note?

    var body: some View {
        Group {
            if store.inboxNotes.isEmpty {
                SenseiEmptyState(
                    "The inbox is swept",
                    message: "New knowledge candidates appear here after each "
                        + "analysis pass.")
            } else {
                List(store.inboxNotes) { note in
                    InboxRowView(
                        note: note,
                        onKeep: { store.keep(note) },
                        onDiscard: { store.discard(note) },
                        onEdit: { editingCard = note })
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Dojo.paper)
        .navigationTitle("Inbox")
        .navigationSubtitle("K keeps · D discards the first candidate")
        .onAppear { store.refresh() }
        .sheet(item: $editingCard) { note in
            CardEditSheet(note: note)
        }
        // Single-keystroke triage of the top candidate (§5.1).
        .background {
            Group {
                Button("") { if let first = store.inboxNotes.first { store.keep(first) } }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { if let first = store.inboxNotes.first { store.discard(first) } }
                    .keyboardShortcut("d", modifiers: [])
            }
            .opacity(0)
        }
    }
}

/// One inbox candidate with its triage actions — used by the Inbox screen
/// and by the Cards home empty state.
struct InboxRowView: View {
    let note: Note
    var onKeep: () -> Void
    var onDiscard: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.topic).bold()
                Spacer()
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .buttonStyle(.borderless)
                Button("Keep", action: onKeep)
                Button("Discard", action: onDiscard)
            }
            if let parts = note.cardParts {
                if !parts.reference.isEmpty {
                    CardTextView(text: parts.reference)
                }
                qaLine(marker: "Q", text: parts.question)
                qaLine(marker: "A", text: parts.answer)
            } else {
                CardTextView(text: note.body)
            }
        }
        .padding(.vertical, 6)
    }

    private func qaLine(marker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .trailing)
            CardTextView(text: text)
        }
    }
}

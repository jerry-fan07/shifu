import ShifuCore
import SwiftUI

/// *Vault* tab (implementation.md Phase 4 item 2): inbox triage with
/// single-keystroke keep/discard, plus a glance at the kept collection.
struct VaultTabView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.inboxNotes.isEmpty {
                ContentUnavailableView(
                    "Inbox empty", systemImage: "tray",
                    description: Text("New knowledge candidates appear here after analysis.")
                )
            } else {
                Text("Inbox — K keeps, D discards the first card")
                    .font(.headline)
                List(store.inboxNotes, id: \.id) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.topic).bold()
                            Spacer()
                            Button("Keep") { store.keep(note) }
                            Button("Discard") { store.discard(note) }
                        }
                        Text(note.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(store.dueNotes.count) due for review")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        // Single-keystroke triage of the top card (§5.1).
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

/// Minimal card session (design.md §5.2): question, reveal, grade 1–4.
struct ReviewSessionView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var revealed = false
    @State private var reviewedCount = 0

    var body: some View {
        VStack(spacing: 24) {
            if let note = store.dueNotes.first, let qa = note.questionAnswer {
                Text(note.topic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(qa.question)
                    .font(.title3)
                    .multilineTextAlignment(.center)

                if revealed {
                    Divider().frame(width: 160)
                    Text(qa.answer)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        gradeButton("Again", .again, "1")
                        gradeButton("Hard", .hard, "2")
                        gradeButton("Good", .good, "3")
                        gradeButton("Easy", .easy, "4")
                    }
                } else {
                    Button("Reveal") { revealed = true }
                        .keyboardShortcut(.space, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
                Text("\(store.dueNotes.count) left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView(
                    reviewedCount > 0 ? "Done — \(reviewedCount) reviewed" : "Nothing due",
                    systemImage: "checkmark.circle",
                    description: Text("Come back when notes are due.")
                )
            }
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { store.refresh() }
    }

    private func gradeButton(_ label: String, _ grade: FSRS.Grade, _ key: Character) -> some View {
        Button(label) {
            if let note = store.dueNotes.first {
                store.review(note, grade: grade)
                reviewedCount += 1
                revealed = false
            }
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }
}

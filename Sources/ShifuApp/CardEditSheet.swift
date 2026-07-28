import ShifuCore
import SwiftUI

/// Edit one card's topic, Q/A, and reference text — reachable mid-review,
/// from the inbox, and from the Cards home list. The live preview renders
/// exactly what the review session will show (math + code included).
struct CardEditSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let note: Note

    @State private var topic: String
    @State private var question: String
    @State private var answer: String
    @State private var reference: String
    @State private var confirmingDelete = false

    init(note: Note) {
        self.note = note
        let parts = note.cardParts
        _topic = State(initialValue: note.topic)
        _question = State(initialValue: parts?.question ?? "")
        _answer = State(initialValue: parts?.answer ?? "")
        _reference = State(initialValue: parts?.reference ?? note.body)
    }

    /// A card needs both halves of the Q/A; both empty is also fine (the
    /// note demotes to a reference note, §5.1).
    private var canSave: Bool {
        let hasQuestion = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAnswer = !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasQuestion == hasAnswer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit card")
                .font(.title3)
                .bold()
            TextField("Topic", text: $topic)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    editor("Question — $…$ math, `code`, ``` blocks", text: $question, height: 60)
                    editor("Answer", text: $answer, height: 90)
                    editor("Reference (optional)", text: $reference, height: 50)
                    preview
                }
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
        .confirmationDialog(
            "Delete this card permanently?", isPresented: $confirmingDelete
        ) {
            Button("Delete card", role: .destructive) {
                store.discard(note)
                dismiss()
            }
        }
    }

    private func editor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minHeight: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.quaternary)
                )
        }
    }

    @ViewBuilder private var preview: some View {
        if !question.isEmpty || !answer.isEmpty {
            GroupBox("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    if !question.isEmpty {
                        CardTextView(text: question, baseSize: 14)
                    }
                    if !answer.isEmpty {
                        Divider()
                        CardTextView(text: answer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Delete…", role: .destructive) { confirmingDelete = true }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            // ⌘S, not Return — Return types newlines in the editors.
            Button("Save") {
                store.updateCard(
                    note, topic: topic, reference: reference,
                    question: question, answer: answer)
                dismiss()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
    }
}

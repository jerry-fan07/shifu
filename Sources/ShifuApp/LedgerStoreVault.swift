import Foundation
import ShifuCore

/// Vault triage and review actions (design.md §5.1–5.2), plus the Cards
/// screen's heatmap span. Split out of LedgerStore.swift for length only;
/// `refreshVaultNotes` stays there because it writes the store's own
/// `private(set)` state.
@MainActor
extension LedgerStore {
    /// Everything one vault walk yields, so the walk can live out here while
    /// the store keeps its `private(set)` publishing to itself.
    struct VaultSnapshot {
        var cards: [Note] = []
        var due: [Note] = []
        var reviewsByDay: [Date: Int] = [:]
    }

    /// One vault walk feeding the review queue and the Cards screens.
    /// Queues are sorted most-urgent first (earliest due date; cards that
    /// never entered scheduling sort ahead of everything).
    func vaultSnapshot() -> VaultSnapshot {
        var snapshot = VaultSnapshot()
        let notes = (try? vault.allNotes()) ?? []
        snapshot.cards = notes
            .filter { $0.state == .kept && $0.questionAnswer != nil }
            .sorted { ($0.srs?.due ?? .distantPast) < ($1.srs?.due ?? .distantPast) }
        let now = Date()
        snapshot.due = snapshot.cards.filter { $0.srs.map { $0.due <= now } ?? true }
        // A week of slack so the heatmap's week-aligned first column has
        // counts for its leading days too.
        let heatmapStart = Calendar.current.date(
            byAdding: .day, value: -(HeatmapSpan.days + 7),
            to: Calendar.current.startOfDay(for: now))!
        let log = (try? vault.reviewLog(since: heatmapStart)) ?? []
        snapshot.reviewsByDay = log.reduce(into: [:]) { counts, date in
            counts[Calendar.current.startOfDay(for: date), default: 0] += 1
        }
        return snapshot
    }

    /// The task's living overview document, if the compiler has written one
    /// (vault-features.md §2.1). Read from the file rather than the index —
    /// it is one known path, and the index is disposable.
    func taskOverview(taskKey: String) -> TaskOverview? {
        vault.taskOverview(taskKey: taskKey)
    }

    /// How far back the review-activity heatmap looks (26 weeks ≈ 6 months).
    enum HeatmapSpan {
        static let weeks = 26
        static let days = weeks * 7
    }

    var reviewsToday: Int {
        reviewsByDay[Calendar.current.startOfDay(for: Date())] ?? 0
    }

    func discard(_ note: Note) {
        try? vault.discard(note)
        refreshSoon()
    }

    func review(_ note: Note, grade: FSRS.Grade) {
        _ = try? vault.review(note, grade: grade)
        refreshSoon()
    }

    /// Persists a card edit (topic + reference + Q/A) from the card editor.
    /// The file keeps its identity — `VaultStore.save` finds it by id.
    func updateCard(
        _ note: Note, topic: String, reference: String, question: String, answer: String
    ) {
        var updated = note
        let trimmedTopic = topic.trimmingCharacters(in: .whitespaces)
        if !trimmedTopic.isEmpty { updated.topic = trimmedTopic }
        let hasQA = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Clearing the Q/A demotes the card to a reference note (§5.1).
        updated.body = hasQA
            ? Note.composeBody(reference: reference, question: question, answer: answer)
            : reference.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? vault.save(updated)
        refreshSoon()
    }
}

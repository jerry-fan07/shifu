import Foundation
import GRDB

// MARK: - Evidence (vault-features.md §2.1)
//
// What a day note is written *from*, split from WorkNoteCompiler.swift the way
// the narrative is: the deterministic compile stays there.
//
// It used to be raw OCR — up to 2,000 characters per activity, 71.6k for the
// average substantial task-day on the dogfood ledger — and it was the largest
// line on the bill (46% of spend, 2026-09-11..24). Every closed block over a
// minute already carries a card (`activities.card`): the fast model's own
// reading of those same screens, paid for once by `CardBuilder` and rendered
// by every other stage. The day note renders it too — about a twelfth of the
// bytes for the same facts, in cleaner words — and the hash gate hashes what
// the prompt sees, so a card that outlives the 14-day text scrub keeps the
// day reading as unchanged.

extension WorkNoteCompiler {
    /// Card-less time — sub-minute glances, mostly — is told as a tally of
    /// the windows it went to, heaviest first; at most this many lines, each
    /// title cut to `glanceTitleChars` (browser titles run to 200 characters
    /// of page name, site and profile).
    static let glanceLimit = 12
    static let glanceTitleChars = 80
    /// Raw text is the last resort, for a day with neither a card nor a
    /// window title to show; this much of it, for at most
    /// `fallbackTextLimit` activities.
    static let fallbackTextChars = 300
    static let fallbackTextLimit = 3

    /// One activity's evidence: the cheapest faithful thing it carries.
    struct ActivityEvidence: Sendable {
        var card: BlockCard?
        var titles: [String] = []
        var text: String?

        var isEmpty: Bool { card == nil && titles.isEmpty && (text ?? "").isEmpty }

        /// What the regeneration gate hashes — the bytes this activity puts
        /// into the prompt, never the screen text behind them.
        var hash: Int64 {
            if let json = card?.json { return VaultIndexer.contentHash(json) }
            if !titles.isEmpty { return VaultIndexer.contentHash(titles.joined(separator: "\n")) }
            return text.map(VaultIndexer.contentHash) ?? 0
        }
    }

    /// One activity of a task-day, as the renderer reads it. `durationMs` is
    /// already clipped to the day.
    struct EvidenceItem {
        var startedAt: Int64
        var durationMs: Int64
        var appBundle: String
        var evidence: ActivityEvidence
    }

    /// Reads one activity's evidence: its card if it has one; otherwise its
    /// distinct window titles (which outlive the text scrub); otherwise a
    /// little of its redacted text.
    static func activityEvidence(
        _ db: Database, activityID: Int64, card: String?
    ) throws -> ActivityEvidence {
        if let card = BlockCard.parse(card) { return ActivityEvidence(card: card) }
        let titles = try String.fetchAll(db, sql: """
            SELECT window_title FROM observations
            WHERE session_id = ? AND window_title IS NOT NULL AND window_title != ''
            GROUP BY window_title ORDER BY MIN(started_at) LIMIT 3
            """, arguments: [activityID])
        if !titles.isEmpty { return ActivityEvidence(titles: titles) }
        let text = try String.fetchOne(db, sql: """
            SELECT text FROM observations
            WHERE session_id = ? AND text IS NOT NULL ORDER BY id LIMIT 1
            """, arguments: [activityID])
        return ActivityEvidence(text: text.map { String($0.prefix(fallbackTextChars)) })
    }

    /// The task-day's activity log as the prompt carries it: one line per
    /// carded block in time order ("09:12 88m Xcode: stepping through AX
    /// teardown | topic=debugging capture daemon | repo:shifu"), a card that
    /// repeats its predecessor folded into it; then the card-less time as a
    /// tally of the windows it went to. Raw text appears only for a day with
    /// neither — on a real day it is OCR'd browser chrome that the cards and
    /// titles around it already say better. Empty when the day has no
    /// evidence at all, which is what `gather` reads as "nothing to say".
    static func renderEvidence(_ items: [EvidenceItem], times: DateFormatter) -> String {
        struct CardLine {
            var start: Int64
            var durationMs: Int64
            var facts: String
        }
        var cardLines: [CardLine] = []
        var glances: [String: Int64] = [:]
        var texts: [String] = []
        for item in items.sorted(by: { $0.startedAt < $1.startedAt }) {
            let app = SemanticTaskGrouper.shortBundle(item.appBundle)
            if let card = item.evidence.card {
                let facts = "\(app): \(card.promptFacts)"
                if cardLines.last?.facts == facts {
                    cardLines[cardLines.count - 1].durationMs += item.durationMs
                } else {
                    cardLines.append(CardLine(
                        start: item.startedAt, durationMs: item.durationMs, facts: facts))
                }
            } else if let title = item.evidence.titles.first {
                glances["\(app) · \(title.prefix(glanceTitleChars))", default: 0]
                    += item.durationMs
            } else if let text = item.evidence.text, !text.isEmpty,
                      texts.count < fallbackTextLimit {
                texts.append("\(app): \(text)")
            }
        }
        if !cardLines.isEmpty || !glances.isEmpty { texts = [] }

        var lines = cardLines.map { line in
            let start = times.string(from: Date(timeIntervalSince1970: Double(line.start) / 1_000))
            return "\(start) \(minutesLabel(line.durationMs)) \(line.facts)"
        }
        let tally = glances
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(glanceLimit)
        if !tally.isEmpty {
            lines.append("Other windows, by time:")
            lines += tally.map { "- \($0.key) (\(minutesLabel($0.value)))" }
        }
        if !texts.isEmpty {
            lines.append("Screen text:")
            lines += texts.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// "88m", or "<1m" for a glance — never a "0m" that reads as nothing.
    static func minutesLabel(_ durationMs: Int64) -> String {
        durationMs < 60_000 ? "<1m" : "\(durationMs / 60_000)m"
    }
}

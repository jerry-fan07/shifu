import ShifuCore
import SwiftUI

// Spotted dates on screen (design.md §4.7) — the band under Coming up, and a
// row per proposal with the two verbs that close it.
//
// This is an inbox, not a list of deadlines: nothing here is reminded about
// until it is accepted, and the band says so. Rows are ranked rather than
// merely dated because that is the whole point of the scorer — the same screen
// shows a graded submission and a dining-hall hour, and the user should not
// have to tell them apart twice.

/// What the scout spotted, waiting for a yes. Critical and high rows first,
/// normal after, low folded behind a count.
struct SpottedBand: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var showingLow = false
    @State private var accepting: DeadlineProposal?

    /// Rows drawn before the band folds the rest behind a count.
    private static let shown = 8

    var body: some View {
        let shown = store.spottedShown
        let folded = store.spottedFolded
        if !shown.isEmpty || !folded.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Eyebrow(eyebrow(shown))
                    Text("seen on screen · not deadlines until you accept them")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.ghost)
                    Spacer(minLength: 0)
                    InlineLink("Dismiss all", action: store.dismissAllSpotted)
                }
                .padding(.bottom, shown.isEmpty ? 0 : 6)
                ForEach(shown.prefix(showingLow ? shown.count : Self.shown)) { proposal in
                    SpottedRow(proposal: proposal) { accepting = proposal }
                }
                foot(shown: shown, folded: folded)
            }
            .padding(.bottom, 14)
            .sheet(item: $accepting) { proposal in
                DeadlineSheet(taskID: nil, taskName: nil, proposal: proposal)
                    .environmentObject(store)
            }
        }
    }

    private func eyebrow(_ shown: [DeadlineProposal]) -> String {
        let pressing = shown.filter { $0.tier >= .high }.count
        guard pressing > 0 else { return "Spotted" }
        return "Spotted · \(pressing) worth a look"
    }

    /// The fold: how many more sit below the line, and the way to see them.
    @ViewBuilder private func foot(shown: [DeadlineProposal], folded: [DeadlineProposal]) -> some View {
        let hiddenRows = max(0, shown.count - Self.shown)
        if !showingLow, hiddenRows > 0 || !folded.isEmpty {
            HStack(spacing: 4) {
                Text(footText(hiddenRows: hiddenRows, lowCount: folded.count))
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                InlineLink("show", size: 11.5) { showingLow = true }
            }
            .padding(.top, 6)
        } else if showingLow {
            ForEach(folded) { proposal in
                SpottedRow(proposal: proposal) { accepting = proposal }
            }
            InlineLink("fewer", size: 11.5) { showingLow = false }
                .padding(.top, 6)
        }
    }

    private func footText(hiddenRows: Int, lowCount: Int) -> String {
        var parts: [String] = []
        if hiddenRows > 0 { parts.append("\(hiddenRows) more") }
        if lowCount > 0 { parts.append("\(lowCount) low-confidence") }
        return parts.joined(separator: " · ") + " —"
    }
}

/// One spotted date: how much it seems to matter, what it is, where it was
/// read, when — and on hover, the two verbs.
struct SpottedRow: View {
    @EnvironmentObject private var store: LedgerStore
    let proposal: DeadlineProposal
    let accept: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            tierMark
            Text(proposal.title)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .lineLimit(1)
            Tag(proposal.category.label)
            if let context = proposal.context {
                Text(context)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Figure(whenText, size: 11.5, color: whenColor)
            if hovering {
                InlineLink("Add", action: accept)
                InlineLink("Dismiss") { store.dismissSpotted(proposal) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(help)
    }

    /// Two glyphs for the two tiers that earn a banner, nothing for the rest:
    /// the mark is read beside the hue of the date, never instead of words.
    @ViewBuilder private var tierMark: some View {
        switch proposal.tier {
        case .critical: Figure("‼", size: 11.5, color: Instrument.overdue)
        case .high: Figure("!", size: 11.5, color: Instrument.alert)
        default: Figure("·", size: 11.5, color: Instrument.ghost)
        }
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private var whenText: String { SpottedNotices.when(proposal, now: now) }

    private var whenColor: Color {
        let days = proposal.daysLeft(now: now)
        return days <= 1 ? Instrument.alert : Instrument.muted
    }

    /// The evidence, verbatim: the one place the line itself is shown, so a
    /// doubtful title can be checked against what was actually on screen.
    private var help: String {
        var lines = ["\(proposal.tier.label) · \(proposal.category.label) · seen \(proposal.sightings)×"]
        lines.append("“\(proposal.evidence)”")
        if let context = proposal.context { lines.append("in \(context)") }
        return lines.joined(separator: "\n")
    }
}

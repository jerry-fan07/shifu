import AppKit
import ShifuCore
import SwiftUI

/// The *Radar* place (design.md §6.2): work a machine could be doing instead.
/// Only described, gated rows ever reach here (`Radar.active`) — a mined
/// pattern on its own is evidence, not advice.
///
/// Each row is an argument, in order: the claim, the evidence it rests on, what
/// to actually do, and why this kind of thing is worth automating at all. The
/// saving sits beside the claim because it is the only reason to read on.
struct RadarView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var copied: Int64?

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "Worth automating",
                subtitle: "Shifu only raises a pattern when the time it would give back "
                    + "plainly exceeds the cost of building it.")
            PageBody {
                if store.suggestions.isEmpty {
                    BlankSlate(
                        "Nothing has cleared the bar. Shifu reviews your recurring chores "
                            + "weekly and points only when automating one would pay for "
                            + "itself.")
                } else {
                    ForEach(store.suggestions, id: \.patternKey) { suggestion in
                        row(suggestion)
                        Rule(weight: .section)
                    }
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private func row(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(suggestion.title ?? suggestion.evidence)
                    .font(Instrument.sans(14.5, .semibold))
                    .foregroundStyle(Instrument.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Figure(suggestion.sizingLabel, size: 11, color: Instrument.muted)
                    .fixedSize()
            }
            // The dossier the suggestion was judged from: hours, days, when it
            // happens, where the time went.
            Figure(suggestion.evidence, size: 11, color: Instrument.faint)
                .padding(.top, 5)
            if let body = suggestion.suggestion {
                Text(body)
                    .font(Instrument.sans(13))
                    .lineSpacing(3)
                    .foregroundStyle(Instrument.body)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.top, 8)
            }
            if let teach = suggestion.teach {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Eyebrow("Why")
                    Text(teach)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                }
                .padding(.top, 7)
            }
            HStack(spacing: 14) {
                SolidButton(title: copied == suggestion.id ? "Copied ✓" : "Copy brief") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        suggestion.automationPrompt, forType: .string)
                    copied = suggestion.id
                }
                OutlineButton(title: "Snooze 30d") { store.snooze(suggestion) }
                OutlineButton(title: "Dismiss") { store.dismiss(suggestion) }
            }
            .padding(.top, 11)
        }
        .padding(.top, 15)
        .padding(.bottom, 14)
    }
}

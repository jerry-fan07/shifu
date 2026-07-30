import AppKit
import ShifuCore
import SwiftUI

/// The *Radar* page (design.md §6.2): ranked automation suggestions with
/// Copy / Snooze / Dismiss actions. Only described, gated rows ever reach here
/// (`Radar.active`) — a mined row on its own is evidence, not advice.
struct RadarView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var copiedID: Int64?

    var body: some View {
        PageScaffold(destination: .radar) {
            if !store.suggestions.isEmpty {
                Eyebrow("\(store.suggestions.count) open")
            }
        } content: {
            if store.suggestions.isEmpty {
                SenseiEmptyState(
                    "Nothing worth automating yet",
                    message: "I review your recurring chores weekly, and point "
                        + "only when automating one would plainly pay for itself.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.suggestions, id: \.patternKey) { suggestion in
                            row(suggestion).dojoCard(padding: 14)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private func row(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title ?? suggestion.evidence)
                .font(Dojo.display(15))
            // The dossier line the suggestion was judged from: hours, days,
            // when it happens, where the time went.
            Text(suggestion.evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let body = suggestion.suggestion {
                Text(body)
                    .font(.callout)
            }
            if let teach = suggestion.teach {
                Label(teach, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(copiedID == suggestion.id ? "Copied ✓" : "Copy brief") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        suggestion.automationPrompt, forType: .string)
                    copiedID = suggestion.id
                }
                Button("Snooze 30d") { store.snooze(suggestion) }
                Button("Dismiss") { store.dismiss(suggestion) }
                Spacer()
                Text(suggestion.sizingLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

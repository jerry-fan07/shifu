import AppKit
import ShifuCore
import SwiftUI

/// *Radar* tab (design.md §6.2): ranked automation suggestions with
/// Dismiss / Snooze / copy-automation-prompt actions.
struct RadarTabView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var copiedID: Int64?

    var body: some View {
        Group {
            if store.suggestions.isEmpty {
                ContentUnavailableView(
                    "No suggestions yet", systemImage: "dot.radiowaves.left.and.right",
                    description: Text("The pattern miner runs weekly. Repetitive workflows show up here.")
                )
            } else {
                List(store.suggestions, id: \.patternKey) { suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.title ?? suggestion.evidence)
                            .font(.headline)
                        Text(suggestion.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let body = suggestion.suggestion {
                            Text(body)
                                .font(.callout)
                        }
                        HStack(spacing: 12) {
                            Button(copiedID == suggestion.id ? "Copied ✓" : "Copy automation prompt") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    suggestion.automationPrompt, forType: .string)
                                copiedID = suggestion.id
                            }
                            Button("Snooze 30d") { store.snooze(suggestion) }
                            Button("Dismiss") { store.dismiss(suggestion) }
                            Spacer()
                            Text("≈\(Int(suggestion.estMinutesSavedWeekly)) min/week")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
    }
}

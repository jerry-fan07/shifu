import ShifuCore
import SwiftUI

/// Navigation value for the suggestion queue — a distinct type so one
/// NavigationStack can route it alongside task ids and ThemeRoute.
struct SuggestionsRoute: Hashable {}

/// The full open suggestion queue, off the Vault tab (vault-features.md §5.2).
/// The Task log shows only `LedgerStore.suggestionLimit` merge suggestions and
/// no theme ones: a weekly pass over a few hundred tasks can open more pairs
/// than the task list has rows, and inline they push the actual work log off
/// screen. Everything past that lives here, with a bulk dismiss per queue so a
/// backlog the user does not care about can be cleared in one action, not N.
struct MergeReviewView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        List {
            if !store.allMergeSuggestions.isEmpty {
                Section {
                    ForEach(store.allMergeSuggestions, id: \.rowID) { suggestion in
                        row(icon: "arrow.triangle.merge",
                            text: "**\(suggestion.nameA)** and **\(suggestion.nameB)** look alike",
                            confidence: suggestion.cosine,
                            accept: ("Merge", { store.acceptMerge(suggestion) }),
                            dismiss: { store.dismissMerge(suggestion) })
                    }
                } header: {
                    header("Possible duplicate tasks",
                           count: store.allMergeSuggestions.count,
                           dismissAll: store.dismissAllMerges)
                } footer: {
                    Text("Shifu already merges near-identical tasks on its own. These "
                        + "are the less certain ones — plus anything you renamed or "
                        + "filed under a theme by hand, which is never merged automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.allThemeSuggestions.isEmpty {
                Section {
                    ForEach(store.allThemeSuggestions, id: \.rowID) { suggestion in
                        row(icon: "square.stack.3d.up",
                            text: "Add **\(suggestion.taskName)** to *\(suggestion.themeName)*?",
                            confidence: suggestion.cosine,
                            accept: ("Add", { store.acceptThemeSuggestion(suggestion) }),
                            dismiss: { store.dismissThemeSuggestion(suggestion) })
                    }
                } header: {
                    header("Suggested theme assignments",
                           count: store.allThemeSuggestions.count,
                           dismissAll: store.dismissAllThemeSuggestions)
                } footer: {
                    Text("Shifu files most blocks under a theme on its own. These are "
                        + "tasks it left out that look, by wording, like a theme you "
                        + "already have.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.allMergeSuggestions.isEmpty && store.allThemeSuggestions.isEmpty {
                SenseiEmptyState(
                    "Nothing to review",
                    message: "Suggestions appear when the weekly analysis finds "
                        + "tasks that look like the same work.")
            }
        }
        .navigationTitle("Merge review")
        .onAppear { store.refresh() }
    }

    private func header(
        _ title: String, count: Int, dismissAll: @escaping () -> Void
    ) -> some View {
        HStack {
            Text("\(title) · \(count)")
            Spacer()
            Button("Dismiss all", action: dismissAll)
                .buttonStyle(.link)
                .help("Clears this queue for good — dismissed pairs are never re-suggested")
        }
    }

    /// Suggestions differ only in wording and the accept verb, so both queues
    /// render through one row.
    private func row(
        icon: String, text: LocalizedStringKey, confidence: Double,
        accept: (label: String, action: () -> Void), dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
            Spacer()
            // The score is the whole reason a pair is here rather than merged
            // already; showing it makes "why is this one being asked about?"
            // answerable.
            Text(String(format: "%.2f", confidence))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Button(accept.label, action: accept.action)
            Button("Dismiss", action: dismiss)
        }
        .padding(.vertical, 2)
    }
}

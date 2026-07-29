import ShifuCore
import SwiftUI

/// The Scrolls page (vault-features.md §4): search across everything the vault
/// remembers — knowledge notes, work logs — from one field. The Markdown tree
/// stays the source of truth; rows open the same read-only note viewer the
/// task pages use, and the folder itself is one click away for Obsidian.
struct ScrollsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var selectedHit: VaultSearch.Hit?

    private var isSearching: Bool {
        !store.vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if !isSearching {
                SenseiEmptyState(
                    "The vault keeps what you read",
                    message: "Ask it anything — a topic, a phrase you half remember, "
                        + "a task's name. The scrolls answer by meaning, not just by word."
                ) {
                    revealButton
                }
            } else if store.vaultHits.isEmpty {
                SenseiEmptyState(
                    "No scroll answers that",
                    message: "Ask differently, or with fewer words.")
            } else {
                resultsList
            }
        }
        .background(Dojo.paper)
        .navigationTitle("Scrolls")
        .searchable(
            text: $store.vaultQuery, placement: .toolbar,
            prompt: "Search the vault")
        .onChange(of: store.vaultQuery) { _, _ in store.searchVault() }
        .onAppear { store.refresh() }
        .sheet(item: $selectedHit) { hit in
            NoteReaderView(hit: hit)
        }
    }

    private var resultsList: some View {
        List(store.vaultHits) { hit in
            Button {
                selectedHit = hit
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(hit.title).bold()
                        Spacer()
                        if let captured = hit.captured {
                            Text(captured, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(hit.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([ShifuPaths.vault])
        } label: {
            Label("Reveal vault in Finder", systemImage: "folder")
        }
        .buttonStyle(.bordered)
    }
}

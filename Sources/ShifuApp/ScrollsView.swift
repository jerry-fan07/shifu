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
        PageScaffold(destination: .scrolls) {
            revealButton
        } content: {
            VStack(spacing: 0) {
                searchField
                if !isSearching {
                    SenseiEmptyState(
                        "The vault keeps what you read",
                        message: "Ask it anything — a topic, a phrase you half remember, "
                            + "a task's name. The scrolls answer by meaning, not just "
                            + "by word.")
                } else if store.vaultHits.isEmpty {
                    SenseiEmptyState(
                        "No scroll answers that",
                        message: "Ask differently, or with fewer words.")
                } else {
                    resultsList
                }
            }
        }
        .onChange(of: store.vaultQuery) { _, _ in store.searchVault() }
        .onAppear { store.refresh() }
        .sheet(item: $selectedHit) { hit in
            NoteReaderView(hit: hit)
        }
    }

    /// The page *is* the search box, so it lives in the page — the window
    /// toolbar's search field would hide the one control that matters.
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ask the scrolls…", text: $store.vaultQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            if isSearching {
                Button {
                    store.vaultQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .dojoCard(padding: 0)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.vaultHits) { hit in
                    Button {
                        selectedHit = hit
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hit.title).fontWeight(.medium)
                                Spacer()
                                if let captured = hit.captured {
                                    Text(captured, style: .date)
                                        .font(Dojo.label(10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(hit.snippet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .dojoCard(padding: 0)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([ShifuPaths.vault])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("The vault is plain Markdown — open it in any editor")
    }
}

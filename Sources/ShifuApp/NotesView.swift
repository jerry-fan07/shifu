import ShifuCore
import SwiftUI

/// The Vault's *Notes* place (vault-features.md §4): everything the vault
/// remembers — knowledge notes and compiled work logs — searched from one
/// field, by meaning as well as by word. The Markdown tree stays the source of
/// truth; rows open a reader, and the folder itself is one click away.
struct NotesView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var reading: VaultSearch.Hit?

    private var isSearching: Bool {
        !store.vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "Notes",
                subtitle: "\(store.noteCount) note\(store.noteCount == 1 ? "" : "s") — "
                    + "what you read, and what you did, as plain Markdown."
            ) {
                OutlineButton(title: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ShifuPaths.vault])
                }
            }
            Band { field }
            PageBody {
                if !isSearching {
                    BlankSlate(
                        "Ask the vault anything — a topic, a phrase you half remember, a "
                            + "task's name. It answers by meaning, not only by word.")
                } else if store.vaultHits.isEmpty {
                    BlankSlate("Nothing answers that. Try fewer words.")
                } else {
                    results
                }
            }
        }
        .onChange(of: store.vaultQuery) { _, _ in store.searchVault() }
        .onAppear { store.refresh() }
        .sheet(item: $reading) { hit in NoteReaderView(hit: hit) }
    }

    /// The page *is* the field — so it sits in the page, at the top, at the
    /// full width of the table under it.
    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.faint)
            TextField("Search the vault…", text: $store.vaultQuery)
                .textFieldStyle(.plain)
                .font(Instrument.sans(13.5))
                .foregroundStyle(Instrument.ink)
            if isSearching {
                InlineLink("Clear") { store.vaultQuery = "" }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(Instrument.edge, lineWidth: 1)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHead {
                Text("Note").frame(maxWidth: .infinity, alignment: .leading)
                Text("Kind").frame(width: 84, alignment: .leading)
                Text("Captured").frame(width: 92, alignment: .trailing)
            }
            ForEach(store.vaultHits) { hit in
                Button { reading = hit } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 14) {
                            Text(hit.title)
                                .font(Instrument.sans(13, .medium))
                                .foregroundStyle(Instrument.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(hit.kind == .work ? "work log" : "knowledge")
                                .font(Instrument.sans(11.5))
                                .foregroundStyle(Instrument.muted)
                                .frame(width: 84, alignment: .leading)
                            Figure(
                                hit.captured.map {
                                    $0.formatted(.dateTime.day().month(.abbreviated))
                                } ?? "—",
                                size: 11, color: Instrument.faint)
                                .frame(width: 92, alignment: .trailing)
                        }
                        Text(hit.snippet)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 700, alignment: .leading)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rule()
            }
        }
    }
}

/// One vault note, read-only (vault-features.md §4). Editing happens in the
/// user's editor of choice — hence Reveal in Finder. Shared with the task
/// page, which opens notes from the same reader.
struct NoteReaderView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let hit: VaultSearch.Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.title)
                    .font(Instrument.sans(16, .semibold))
                    .foregroundStyle(Instrument.ink)
                Spacer()
                if let captured = hit.captured {
                    Figure(
                        captured.formatted(.dateTime.day().month(.abbreviated).year()),
                        size: 11, color: Instrument.faint)
                }
            }
            .padding(.bottom, 12)
            Rule(weight: .section)
            if let document = store.noteDocument(for: hit) {
                ScrollView {
                    CardTextView(text: document.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                BlankSlate("The note file is gone — it may have been moved or deleted.")
            }
            Rule(weight: .section)
            HStack {
                OutlineButton(title: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [store.noteFileURL(for: hit)])
                }
                Spacer()
                SolidButton(title: "Done") { dismiss() }
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .background(Instrument.ground)
    }
}

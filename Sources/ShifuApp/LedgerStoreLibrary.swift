import Foundation
import ShifuCore

/// The Notes place's side of the store (vault-features.md §4, §6): keeping the
/// index in step with the Markdown tree, and reading one note's full context.
/// Split out of LedgerStore.swift for length; `loadLibrary` stays there
/// because it writes the store's own `private(set)` lists.
@MainActor
extension LedgerStore {
    /// Brings the search index in line with the Markdown tree, once per
    /// launch, off the main actor.
    ///
    /// The analyzer normally owns reconcile (vault-features.md §4), but the
    /// app is where the vault is *read*: a note edited in Obsidian — or, right
    /// after an upgrade adds index columns, every note in the tree — would
    /// otherwise stay stale until the next hourly pass, which is up to an hour
    /// of a library that doesn't match its own files.
    ///
    /// Deliberately **without an embedder**, which the analyzer keeps
    /// ownership of: embedding is 96% of the cost (measured on the dogfood
    /// vault — 0.15 s for the whole pass, 3.5 s with vectors), and the pass is
    /// one write on a serialized `DatabaseQueue`, so every second of it is a
    /// second the UI's next read blocks for. `backfillVectors` exists for
    /// exactly this: a note re-indexed here is left *without* a vector rather
    /// than with the one its previous text earned (`VaultIndexer.embedVector`),
    /// so the next analyzer reconcile embeds it and until then search is
    /// bm25-only for that note.
    func syncLibrary() {
        guard !librarySynced, let database = try? db() else { return }
        librarySynced = true
        Task.detached(priority: .utility) {
            _ = try? VaultIndexer.reconcile(root: ShifuPaths.vault, database: database)
            await MainActor.run { [weak self] in
                self?.refresh()
                self?.loadLibrary()
            }
        }
    }

    /// Everything Shifu knows about one note, for the note page
    /// (`VaultLibrary.Dossier`). Recomputed on open — never cached, so it
    /// can't drift from the tree.
    func dossier(noteID: String) -> VaultLibrary.Dossier? {
        guard let database = try? db() else { return nil }
        return (try? VaultLibrary.dossier(
            noteID: noteID, database: database, vault: vault)) ?? nil
    }

    /// The notes a set of wiki-link targets resolves to, by title. A target
    /// with nothing indexed under it is absent rather than an error — a note
    /// can name a page that was never written, and the link is still a fact
    /// about what the day was about.
    func linked(_ targets: [String]) -> [String: String] {
        guard !targets.isEmpty, let database = try? db(),
              let entries = try? VaultLibrary.entries(linkTargets: targets, database: database)
        else { return [:] }
        return Dictionary(entries.map { ($0.title, $0.noteID) }) { first, _ in first }
    }

    /// The id of the task's most recent work note (vault-features.md §2.1), so
    /// the task page can open it on the note page like any other link.
    func latestWorkNoteID(taskID: Int64) -> String? {
        guard let database = try? db() else { return nil }
        return (try? VaultLibrary.shelf(
            filter: VaultLibrary.Filter(kind: .work, taskID: taskID, limit: 1),
            database: database))?.first?.noteID
    }
}

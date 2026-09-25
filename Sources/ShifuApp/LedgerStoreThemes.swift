import Foundation
import ShifuCore

/// The store's theme actions (design.md §5.3), split out of LedgerStore.swift
/// because themes are now something the user *authors* — create, edit, delete,
/// plus accept/dismiss on the clusterer's proposals — rather than a read-only
/// view of what the model decided.
@MainActor
extension LedgerStore {
    // MARK: - Themes (the high-level mode)

    func themeDetail(_ themeID: Int64) -> ThemeStore.Detail? {
        guard let database = try? db() else { return nil }
        return (try? ThemeStore.detail(themeID: themeID, database: database)) ?? nil
    }

    /// "New theme" from the Themes grid — the only way one comes into being,
    /// short of accepting a proposal.
    func createTheme(named name: String, gist: String? = nil) {
        if let database = try? db() {
            _ = try? ThemeStore.create(named: name, gist: gist, database: database)
        }
        refreshSoon()
    }

    /// nil leaves a field alone, so the inline rename on the theme page can't
    /// blank the gist the edit sheet sets.
    func updateTheme(_ themeID: Int64, name: String?, gist: String?) {
        if let database = try? db() {
            try? ThemeStore.update(themeID: themeID, name: name, gist: gist,
                                   database: database)
        }
        refreshSoon()
    }

    /// Unfiles the theme's blocks and drops it. The time stays in the ledger.
    func deleteTheme(_ themeID: Int64) {
        if let database = try? db() {
            try? ThemeStore.delete(themeID: themeID, database: database)
        }
        refreshSoon()
    }

    // MARK: - Suggested themes (the clusterer's proposals)

    func acceptThemeProposal(_ proposal: ThemeProposals.Pending) {
        if let database = try? db() {
            _ = try? ThemeProposals.accept(proposal, database: database)
        }
        refreshSoon()
    }

    func dismissThemeProposal(_ proposal: ThemeProposals.Pending) {
        if let database = try? db() {
            try? ThemeProposals.dismiss(proposalID: proposal.id, database: database)
        }
        refreshSoon()
    }

    func dismissAllThemeProposals() {
        if let database = try? db() {
            _ = try? ThemeProposals.dismissAll(database: database)
        }
        refreshSoon()
    }
}

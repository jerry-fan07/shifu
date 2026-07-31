import Foundation
import ShifuCore

/// Which of the vault's three note kinds the Notes place is showing
/// (vault-features.md §2). Named for what they *are* to the user rather than
/// for their `kind:` string: nobody has a "task_overview", they have the page
/// that says what an effort is.
enum NoteKindScope: String, CaseIterable, Identifiable, Hashable {
    case everything = "Everything"
    case work = "Work logs"
    case knowledge = "Cards"
    case overview = "Overviews"

    var id: String { rawValue }

    var kind: FrontMatter.Kind? {
        switch self {
        case .everything: return nil
        case .work: return .work
        case .knowledge: return .knowledge
        case .overview: return .taskOverview
        }
    }
}

/// How much has to be written down before a note is worth listing.
///
/// This is the filter the place could not do without. `WorkNoteCompiler`
/// writes one note per (task, day) whatever happened, so the vault's majority
/// note is a single deterministic line — "arxiv.org" — standing in for a nine
/// second glance. Six hundred of the dogfood vault's six hundred and fifty
/// work notes are that. Listing them beside compiled documents is what made a
/// library of seven hundred documents read as though it held nothing.
///
/// They are still kept, and still findable: a trace is the receipt that says
/// the time was real, and privacy-wise it is the record §7 promises. It just
/// isn't the default answer to "what do I have written down".
enum NoteDepthScope: String, CaseIterable, Identifiable, Hashable {
    case written = "Written up"
    case documents = "Documents only"
    case everything = "Include traces"

    var id: String { rawValue }

    var minimum: VaultLibrary.Depth {
        switch self {
        case .written: return .note
        case .documents: return .document
        case .everything: return .trace
        }
    }
}

/// The Notes place's filter row: kind, depth, how far back, whose theme. Like
/// the Task log's (`TaskListFilter`) this is session state — reopening the
/// window shows the library as it stands, not as you last narrowed it.
struct NoteLibraryFilter: Equatable {
    var kind: NoteKindScope = .everything
    /// Defaults to hiding traces, with the count in the header saying how many
    /// were hidden — the exclusion is visible, never silent.
    var depth: NoteDepthScope = .written
    var range: TaskRange = .all
    var theme: TaskStore.ThemeScope = .any

    var isNarrowed: Bool { self != NoteLibraryFilter() }

    func core(
        now: Date = Date(), calendar: Calendar = .current, limit: Int
    ) -> VaultLibrary.Filter {
        let since = range.since(now: now, calendar: calendar)
        return VaultLibrary.Filter(
            kind: kind.kind,
            themeScope: theme,
            since: since == 0 ? nil : Date(timeIntervalSince1970: Double(since) / 1_000),
            minimumDepth: depth.minimum,
            limit: limit)
    }
}

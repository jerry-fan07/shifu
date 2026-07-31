import ShifuCore
import SwiftUI

/// The Vault's *Notes* place (vault-features.md §4, §6): everything the vault
/// remembers — work logs, overview documents and cards — as a library you can
/// walk, narrow, and search by meaning as well as by word.
///
/// Two things were wrong with the page this replaces, and they compounded.
/// It showed nothing at all until you typed, so a vault of nearly seven
/// hundred documents looked like an empty box; and it counted `21`, because
/// the count walked the tree with `Note.parse`, which only accepts
/// `kind: knowledge`. What search *did* return was dominated by the work-note
/// trace — one deterministic line for a task-day, of which the dogfood vault
/// holds six hundred — so the notes you could see were the ones with nothing
/// in them.
///
/// So: the shelf is the default state, the head counts every kind, traces are
/// filtered out by default rather than deleted, and a row opens the note *with
/// its collections* (`NotePage`) rather than a bare sheet. The Markdown tree
/// stays the source of truth; the folder is still one click away.
struct NotesView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    private var isSearching: Bool {
        !store.vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHead("Notes", subtitle: subtitle) {
                OutlineButton(title: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ShifuPaths.vault])
                }
            }
            Band {
                VStack(alignment: .leading, spacing: 11) {
                    field
                    facets
                }
            }
            PageBody {
                if isSearching {
                    results
                } else {
                    shelf
                }
            }
        }
        .onChange(of: store.vaultQuery) { _, _ in store.loadLibrarySoon() }
        .onChange(of: store.noteFilter) { _, _ in store.loadLibrarySoon() }
        .onAppear {
            store.refresh()
            store.loadLibrary()
            store.syncLibrary()
        }
    }

    /// The head says what is in the vault, not what the filter admits — a
    /// count that moves when you narrow can't tell you what you have.
    private var subtitle: String {
        let census = store.vaultCensus
        guard census.total > 0 else {
            return "Nothing yet. Notes are compiled by the analyzer, which passes hourly."
        }
        var parts = ["\(census.work) work log\(census.work == 1 ? "" : "s")"]
        if census.overviews > 0 { parts.append("\(census.overviews) overviews") }
        if census.knowledge > 0 { parts.append("\(census.knowledge) cards") }
        return "\(census.total) notes — \(parts.joined(separator: ", ")). "
            + "\(census.substantial) of them are written up."
    }

    /// The page *is* the field — so it sits in the page, at the top, at the
    /// full width of the table under it.
    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.faint)
            TextField("Search the vault — a topic, a phrase you half remember…",
                      text: $store.vaultQuery)
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

    /// The same four facets narrow the shelf and the search, so switching
    /// between them never changes what you are looking at, only how it is
    /// ordered.
    private var facets: some View {
        HStack(spacing: 8) {
            FilterMenu(
                options: NoteKindScope.allCases.map { ($0.rawValue, $0) },
                selection: $store.noteFilter.kind)
                .help("Work logs, the cards you kept, or a task's overview document")
            FilterMenu(
                options: NoteDepthScope.allCases.map { ($0.rawValue, $0) },
                selection: $store.noteFilter.depth)
                .help("Traces are the one-line receipts a short task-day leaves")
            FilterMenu(
                options: TaskRange.allCases.map { ($0.rawValue, $0) },
                selection: $store.noteFilter.range)
                .help("How far back the library reaches")
            FilterMenu(
                options: [("All themes", TaskStore.ThemeScope.any),
                          ("No theme", TaskStore.ThemeScope.unassigned)]
                    + store.themes.map { ($0.name, TaskStore.ThemeScope.theme(key: $0.key)) },
                selection: $store.noteFilter.theme)
                .help("Narrow to one strand of work")
            if store.noteFilter.isNarrowed {
                InlineLink("Clear") { store.noteFilter = NoteLibraryFilter() }
            }
            Spacer(minLength: 0)
            Figure(countLabel, size: 11, color: Instrument.faint)
        }
    }

    private var countLabel: String {
        if isSearching {
            let count = store.vaultHits.count
            // Ranked search is capped; saying "40 matches" when 40 is the cap
            // would report the limit as if it were the answer.
            return count >= LedgerStore.searchLimit
                ? "best \(count)"
                : "\(count) match\(count == 1 ? "" : "es")"
        }
        let shown = store.vaultShelf.count
        return shown >= LedgerStore.noteListLimit
            ? "newest \(shown)"
            : "\(shown) note\(shown == 1 ? "" : "s")"
    }

    // MARK: - The shelf

    /// The library with nothing typed: newest first, under the day it belongs
    /// to. Days are the grouping because a note's day is the thing you
    /// actually remember — "that Tuesday" beats any folder.
    @ViewBuilder private var shelf: some View {
        if store.vaultShelf.isEmpty {
            // An empty vault is not an over-tight filter, and telling a new
            // install to loosen one is the wrong instruction twice over: the
            // default filter *is* narrowing (it hides traces), so the filter
            // check alone can never say "there is nothing here".
            BlankSlate(
                store.vaultCensus.total == 0
                    ? "Nothing yet. The analyzer compiles a note for every task-day; "
                        + "it passes hourly."
                    : "Nothing in the vault matches these filters. "
                        + "\"Include traces\" widens it the most.")
        } else {
            ForEach(NoteDay.group(store.vaultShelf)) { day in
                DayHeading(day: day)
                ForEach(day.entries) { entry in
                    Rule()
                    NoteRow(entry: entry) { router.open(.note(entry.noteID)) }
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder private var results: some View {
        if store.vaultHits.isEmpty {
            BlankSlate(
                store.vaultCensus.total == 0
                    ? "There is nothing in the vault to search yet."
                    : store.noteFilter.isNarrowed
                        ? "Nothing answers that inside these filters. Try clearing them."
                        : "Nothing answers that. Try fewer words — search reads meaning "
                            + "as well as spelling.")
        } else {
            ColumnHead {
                Text("Match").frame(maxWidth: .infinity, alignment: .leading)
                Text("Where it came from").frame(width: 210, alignment: .leading)
                Text("Captured").frame(width: 78, alignment: .trailing)
            }
            ForEach(store.vaultHits) { hit in
                NoteRow(entry: hit.entry, snippet: hit.snippet, showsDate: true) {
                    router.open(.note(hit.noteID))
                }
                Rule()
            }
        }
    }
}

// MARK: - Rows

/// One day's worth of the shelf. `day` is nil for notes carrying no date at
/// all — a file dropped into the vault by hand — which get their own heading
/// rather than being filed under the year 1 AD.
struct NoteDay: Identifiable {
    var day: Date?
    var entries: [VaultLibrary.Entry]

    var id: Date { day ?? .distantPast }

    /// Entries are already newest-first out of SQL, so grouping is a single
    /// pass that preserves that order — no re-sort, and days stay contiguous.
    static func group(
        _ entries: [VaultLibrary.Entry], calendar: Calendar = .current
    ) -> [NoteDay] {
        var days: [NoteDay] = []
        for entry in entries {
            let day = entry.captured.map { calendar.startOfDay(for: $0) }
            if let last = days.last, last.day == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(NoteDay(day: day, entries: [entry]))
            }
        }
        return days
    }
}

/// The date a run of notes sits under, with what that day cost beside it.
private struct DayHeading: View {
    let day: NoteDay

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Eyebrow(label, size: 10.5, tracking: 1.1)
            Rectangle().fill(Instrument.hairline).frame(height: 1)
            if totalMs > 0 {
                Figure(TimeBreakdown.duration(totalMs), size: 10.5, color: Instrument.ghost)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var totalMs: Int64 { day.entries.compactMap(\.durationMs).reduce(0, +) }

    private var label: String {
        guard let date = day.day else { return "Undated" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One note on the shelf or in a result list: what it is, what it says, and
/// which effort it came out of. The provenance column is the point — a title
/// and a date can't tell you whether this is the memory you were reaching for.
struct NoteRow: View {
    let entry: VaultLibrary.Entry
    /// The query-aware snippet, when there is a query. Falls back to the
    /// note's own summary line, which is never empty.
    var snippet: String?
    /// The shelf groups by day and says the date in the heading, so its rows
    /// spend the last column on how long the day was instead. Results have no
    /// heading to lean on and need the date.
    var showsDate = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.title)
                        .font(Instrument.sans(13, .medium))
                        .foregroundStyle(Instrument.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    provenance
                        .frame(width: 210, alignment: .leading)
                    Figure(whenLabel, size: 11, color: Instrument.faint)
                        .frame(width: 78, alignment: .trailing)
                }
                if let gist {
                    Text(gist)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 700, alignment: .leading)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The query's own match when there is one, the note's summary line
    /// otherwise. Nil when that would only restate the title — a trace's whole
    /// body *is* its title, and "Music / Music" on two lines is worse than one
    /// line saying Music.
    ///
    /// FTS5 brackets the matched terms with guillemets (they have to be
    /// characters no note contains); they become bold here rather than being
    /// read as punctuation.
    private var gist: AttributedString? {
        let text = ((snippet?.isEmpty == false ? snippet : nil) ?? entry.summary)
            .replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty, text != entry.title else { return nil }
        let marked = text
            .replacingOccurrences(of: "«", with: "**")
            .replacingOccurrences(of: "»", with: "**")
        return (try? AttributedString(markdown: marked)) ?? AttributedString(text)
    }

    /// Kind, depth and the strand of work — in the width of one column,
    /// because they answer three different questions and the row has room for
    /// exactly one column of them.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(entry.kindLabel)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                if entry.depth == .trace {
                    Tag("trace", dashed: true)
                } else if entry.depth == .document {
                    Tag("document", tinted: true)
                }
            }
            if !belonging.isEmpty {
                Text(belonging)
                    .font(Instrument.sans(11))
                    .foregroundStyle(Instrument.ghost)
                    .lineLimit(1)
            }
        }
    }

    /// Task and theme, minus whatever the title already said. A compiled note
    /// is titled by its task, and a task named after its theme is the common
    /// case — without this the column reads "Shifu Development · Shifu
    /// Development" under a row headed "Shifu Development".
    private var belonging: String {
        var parts: [String] = []
        if let task = entry.taskName, task != entry.title { parts.append(task) }
        if let theme = entry.themeName, theme != entry.title, !parts.contains(theme) {
            parts.append(theme)
        }
        return parts.joined(separator: " · ")
    }

    private var whenLabel: String {
        if showsDate {
            return entry.captured?.formatted(.dateTime.day().month(.abbreviated)) ?? "—"
        }
        guard let ms = entry.durationMs, ms > 0 else { return "" }
        return TimeBreakdown.duration(ms)
    }
}

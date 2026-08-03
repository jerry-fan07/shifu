import ShifuCore
import SwiftUI

// The form a deck is made on (design.md §5.2). Pushed from Decks the way a
// deck's own page is: picking the source task, briefing the builder, and
// setting how the deck reviews outgrew the one-click menu this replaces.

// MARK: - The rail

/// The form's rail: the way back, and the one rule that shapes the task list.
struct NewDeckContents: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        RailColumn {
            RailBack(title: "Decks") { router.go(to: .decks) }
        } footer: {
            Text("One deck per task, so tasks that already have one — or an "
                + "open offer — aren't listed. A task whose offer was dismissed "
                + "is: this form is the way back from a dismissal.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The page

/// A deck as a request form: which task it draws from, what it is called,
/// what the builder should focus on, and how it reviews once built. Create
/// mints the deck and lands on its page, where the build spinner already is.
struct NewDeckPage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    @State private var selectedTaskKey: String?
    @State private var title = ""
    /// The last title this form wrote itself — a user's own title survives a
    /// change of task, an untouched one keeps following the picked task.
    @State private var autoTitle = ""
    @State private var instructions = ""
    @State private var cardRange: DeckStore.CardRange?
    @State private var newPerDay: Int? = DeckStore.defaultNewPerDay
    @State private var startPaused = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "New deck",
                subtitle: "Cards are written from the task's own screen time, "
                    + "then reviewed on the spaced-repetition schedule."
            ) {
                if store.hasLLMBackend {
                    SolidButton(title: "Create deck") { create() }
                        .opacity(canCreate ? 1 : 0.35)
                        .allowsHitTesting(canCreate)
                } else {
                    // Without a key nothing could build the deck, and it
                    // would sit "Building…" forever (§5.2).
                    Text("A deck needs DeepSeek (Settings)")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.ghost)
                }
            }
            PageBody {
                if candidates.isEmpty {
                    BlankSlate(
                        "No task to make a deck from — each recent one either has "
                            + "a deck already, has an open offer, or hasn't built up "
                            + "screen time yet.")
                } else {
                    // Two columns, so a dogfood-sized task list can't push
                    // the rest of the form below the fold: what the deck is
                    // made *from* on the left, what it *becomes* on the right.
                    HStack(alignment: .top, spacing: 36) {
                        taskColumn
                        formColumn
                    }
                }
            }
        }
        .onAppear { store.refresh() }
    }

    // MARK: From task

    /// Recent tasks with no deck and no open offer. A task whose offer was
    /// dismissed stays listed — that is the escape hatch working.
    private var candidates: [TaskStore.Overview] {
        let spoken = Set(store.decks.map(\.taskKey))
            .union(store.deckSuggestions.map(\.taskKey))
        return store.recentTasks.filter { !spoken.contains($0.task.key) }
    }

    private var taskColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("From task")
                .padding(.top, 16)
                .padding(.bottom, 3)
            Text("The deck reads this task's learning and work blocks — recent "
                + "first — and nothing else.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            ForEach(candidates) { overview in
                Rule()
                taskRow(overview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleSection
            instructionsSection
            cardCountSection
            reviewSection
        }
        .frame(width: 320)
    }

    private func taskRow(_ overview: TaskStore.Overview) -> some View {
        let selected = overview.task.key == selectedTaskKey
        return Button {
            select(overview)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                pip(on: selected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(overview.task.name)
                            .font(Instrument.sans(13, selected ? .semibold : .regular))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Figure(TimeBreakdown.duration(overview.totalMs),
                               color: Instrument.muted)
                    }
                    Text(overview.latestSummary ?? "No log line yet.")
                        .font(Instrument.sans(12))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The pick-one mark: an empty ring, filled in when the row is chosen.
    private func pip(on selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Instrument.accent : Instrument.edge, lineWidth: 1)
                .frame(width: 12, height: 12)
            if selected {
                Circle()
                    .fill(Instrument.accent)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func select(_ overview: TaskStore.Overview) {
        selectedTaskKey = overview.task.key
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == autoTitle {
            title = overview.task.name
            autoTitle = overview.task.name
        }
    }

    // MARK: Title

    private var titleSection: some View {
        section(
            "Title",
            caption: "Prefilled from the task; rename it now or any time from "
                + "the deck's page."
        ) {
            TextField("Deck title", text: $title)
                .textFieldStyle(.plain)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
        }
    }

    // MARK: Instructions

    private var instructionsSection: some View {
        section(
            "Instructions · optional",
            caption: "What the cards should cover and skip — \"only the "
                + "ownership rules, not the tooling\". The builder follows this "
                + "over its own judgement, on this build and every retry."
        ) {
            TextEditor(text: $instructions)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 76)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
        }
    }

    // MARK: Card count

    private var cardCountSection: some View {
        section(
            "Card count",
            caption: "Automatic sizes the deck to the material, with no hard "
                + "limit. A range is a promise: the build aims inside it and "
                + "never writes past its top."
        ) {
            FilterMenu(options: cardCountOptions, selection: $cardRange)
        }
    }

    /// The ranges stop at 30 because a build answer has a fixed token
    /// reserve (`DeckBuilder.responseTokens`), and thirty full cards already
    /// press against it — a bigger deck is what Automatic is for.
    private var cardCountOptions: [(label: String, value: DeckStore.CardRange?)] {
        [("Automatic", nil),
         ("3–5 cards", DeckStore.CardRange(lower: 3, upper: 5)),
         ("5–10 cards", DeckStore.CardRange(lower: 5, upper: 10)),
         ("10–30 cards", DeckStore.CardRange(lower: 10, upper: 30))]
    }

    // MARK: Review settings

    private var reviewSection: some View {
        section(
            "Review",
            caption: "How many never-reviewed cards the deck may introduce per "
                + "day, and whether it reviews at all. Both live on the deck's "
                + "page afterwards."
        ) {
            VStack(alignment: .leading, spacing: 7) {
                FilterMenu(prefix: "New cards", options: newPerDayOptions,
                           selection: $newPerDay)
                SegmentedBar(
                    options: [("Reviews on", false), ("Start paused", true)],
                    selection: $startPaused)
            }
        }
    }

    private var newPerDayOptions: [(label: String, value: Int?)] {
        // Typed [Int] first: mapping straight into the Int? tuples makes the
        // literal [Int?] and the label print "Optional(20) a day".
        let caps: [Int] = [5, 10, 20, 40]
        var options: [(label: String, value: Int?)] = caps.map { ("\($0) a day", $0) }
        options.append(("No daily cap", nil))
        return options
    }

    // MARK: Create

    /// The picked task must still be a candidate — a refresh can hand it a
    /// deck from elsewhere while the form sits open.
    private var canCreate: Bool {
        guard candidates.contains(where: { $0.task.key == selectedTaskKey })
        else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard let taskKey = selectedTaskKey else { return }
        let deck = store.createDeck(
            taskKey: taskKey, title: title, instructions: instructions,
            cardRange: cardRange, newPerDay: newPerDay, paused: startPaused)
        if let deck {
            router.open(.deck(deck.id))
        } else {
            router.go(to: .decks)
        }
    }

    // MARK: Furniture

    /// One block of the form column: eyebrow, the control, and the one line
    /// that says what it does.
    private func section<Content: View>(
        _ heading: String, caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(heading)
            content()
            Text(caption)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }
}

import ShifuCore
import SwiftUI

/// The main window (design.md §7): a permanent source list on the left, one
/// page on the right, and a title bar that names what you are looking at.
/// Changing place swaps the page — there is no animation between them, because
/// an instrument that flourishes when you change the range is an instrument
/// you stop trusting.
///
/// Opening a task or a theme doesn't push a screen over the top: the source
/// list becomes that thing's own contents, so the window still says where you
/// are. Shows onboarding instead until the first-run flow completes.
struct MainWindow: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @EnvironmentObject private var store: LedgerStore
    @StateObject private var router: Router
    /// The Settings place's model. Owned here rather than by the app so a
    /// harness that hosts the window alone still renders that place.
    @StateObject private var settings: SettingsStore

    /// Both models are parameters for the same reason: the app's menu bar item
    /// and a harness need to open the window already pointed somewhere —
    /// at a place, and (since Settings has a rail of its own) at a section.
    init(router: Router = Router(), settings: SettingsStore = SettingsStore()) {
        _router = StateObject(wrappedValue: router)
        _settings = StateObject(wrappedValue: settings)
    }

    var body: some View {
        Group {
            if onboarded { shell } else { OnboardingView() }
        }
        .tint(Instrument.accent)
    }

    private var shell: some View {
        VStack(spacing: 0) {
            TitleBar(title: title, paused: store.isPaused)
            Rule(weight: .edge)
            HStack(spacing: 0) {
                SourceList()
                Rectangle()
                    .fill(Instrument.edge)
                    .frame(width: 1)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Instrument.ground)
            }
        }
        .background(Instrument.ground)
        .environmentObject(router)
        .environmentObject(settings)
        .frame(minWidth: 960, minHeight: 620)
    }

    /// The page for wherever the router currently points. A pushed task or
    /// theme replaces the place's page rather than covering it.
    @ViewBuilder private var page: some View {
        switch router.route {
        case .none:
            router.place.page
        case .task(let taskID):
            TaskPage(taskID: taskID)
        case .theme(let themeID):
            ThemePage(themeID: themeID)
        case .deck(let deckID):
            DeckPage(deckID: deckID)
        case .newDeck:
            NewDeckPage()
        case .looseCards:
            LooseCardsPage()
        case .merges:
            MergeReviewView()
        case .note(let noteID):
            NotePage(noteID: noteID)
        }
    }

    /// What the window is showing, centred in the title bar the way macOS
    /// names a document.
    private var title: String {
        switch router.route {
        // Settings is a rail of sections inside one place, so the bar names
        // the section too — it is the only place where "where am I" needs two
        // words, and the only one whose page has its own navigation.
        case .none where router.place == .settings:
            return "Settings · \(settings.section.rawValue)"
        case .none: return router.place.title
        case .task(let taskID): return store.taskDetail(taskID)?.task.name ?? "Task"
        case .theme(let themeID): return store.themeDetail(themeID)?.overview.name ?? "Theme"
        case .deck(let deckID):
            return store.decks.first { $0.id == deckID }?.title ?? "Deck"
        case .newDeck: return "New deck"
        case .looseCards: return "Loose cards"
        case .merges: return "Suggestions"
        case .note: return "Note"
        }
    }
}

// MARK: - Routing

/// A page opened *from* a row rather than from the source list.
enum Route: Hashable {
    case task(Int64)
    case theme(Int64)
    case deck(Int64)
    /// The form a deck is made on — pushed from Decks like a deck's own page,
    /// because picking a task, briefing the builder, and setting how it
    /// reviews outgrew a menu.
    case newDeck
    /// The cards outside any live deck — a shelf row like the decks, so it
    /// pages the same way, but with nothing to rename or configure.
    case looseCards
    case merges
    /// One note, read with everything around it (`VaultLibrary.Dossier`).
    /// Keyed by note id rather than by path so the link survives the file
    /// being renamed or moved under it — which a rebuild does routinely.
    case note(String)
}

/// Where the window is pointed, and what the source list is therefore showing.
/// Held in one object so a row buried in a table can open a task without
/// knowing the shell exists, and so the source list can render that task's own
/// contents while it is open.
@MainActor
final class Router: ObservableObject {
    @Published private(set) var place: Place = .breakdown
    @Published private(set) var route: Route?
    /// The section the source list last asked the open page to scroll to.
    /// Cleared by the page once it has moved.
    @Published var section: String?

    func go(to place: Place) {
        self.place = place
        route = nil
        section = nil
    }

    func open(_ route: Route) {
        self.route = route
        section = nil
    }

    /// Back to the place the pushed page was opened from.
    func close() {
        route = nil
        section = nil
    }

    func scroll(to section: String) {
        self.section = section
    }
}

/// Scrolls the page to a section when the source list asks for it, and reports
/// which sections exist by tagging them with `.sectionAnchor(_:)`.
struct SectionScroll<Content: View>: View {
    @EnvironmentObject private var router: Router
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: router.section) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    router.section = nil
                }
        }
    }
}

extension View {
    /// Names a section so the source list can scroll to it.
    func sectionAnchor(_ name: String) -> some View { id(name) }
}

// MARK: - Title bar

/// The window's own bar. `.hiddenTitleBar` leaves the traffic lights floating
/// over the content, so the bar is ours to draw — which is the only way the
/// state indicator can live at the top right where it belongs.
private struct TitleBar: View {
    let title: String
    let paused: Bool

    var body: some View {
        ZStack {
            Text(title)
                .font(Instrument.sans(12.5, .medium))
                .foregroundStyle(Instrument.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Spacer()
                StatusDot(color: paused ? Instrument.alert : Instrument.live)
                Text(paused ? "Resting" : "Watching")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
            }
        }
        // The traffic lights own the leading corner; nothing of ours goes
        // under them.
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(height: Instrument.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(Instrument.rail)
    }
}

// MARK: - Places

/// The bands the source list is grouped into: where the time went, what it
/// left behind, what to bring back, and what a machine could take over.
enum Region: String, CaseIterable, Identifiable {
    case ledger = "Ledger"
    case vault = "Vault"
    case practice = "Practice"
    case signals = "Signals"

    var id: String { rawValue }

    var places: [Place] {
        Place.allCases.filter { $0.region == self }
    }
}

/// Everywhere the source list can take you.
enum Place: String, CaseIterable, Identifiable {
    case breakdown, timeline
    case themes, tasks, notes
    case due, decks
    case radar
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakdown: return "Breakdown"
        case .timeline: return "Timeline"
        case .themes: return "Themes"
        case .tasks: return "Tasks"
        case .notes: return "Notes"
        case .due: return "Due"
        case .decks: return "Decks"
        case .radar: return "Radar"
        case .settings: return "Settings"
        }
    }

    /// Nil for the places outside the bands — Settings is pinned at the rail's
    /// foot rather than listed under a region.
    var region: Region? {
        switch self {
        case .breakdown, .timeline: return .ledger
        case .themes, .tasks, .notes: return .vault
        case .due, .decks: return .practice
        case .radar: return .signals
        case .settings: return nil
        }
    }

    /// The figure on this row. Durations for the ledger, counts everywhere
    /// else — a place is worth visiting in proportion to what is in it.
    @MainActor func badge(_ store: LedgerStore) -> String? {
        switch self {
        // An untracked day leaves the row blank rather than saying "0s":
        // a instrument with nothing on it should look like one.
        case .breakdown: return store.todayMs > 0 ? store.todayTotalLabel : nil
        case .timeline: return store.todayBlockCount > 0 ? "\(store.todayBlockCount)" : nil
        case .themes: return count(store.themes.count)
        case .tasks: return count(store.matchingTaskCount)
        case .notes: return count(store.noteCount)
        case .due: return count(store.dueNotes.count)
        // Kept decks plus open offers: the number of deck-shaped things the
        // page will show, not the cards inside them — Due already counts
        // cards.
        case .decks: return count(store.decks.count + store.deckSuggestions.count)
        case .radar: return count(store.suggestions.count)
        case .settings: return nil
        }
    }

    private func count(_ value: Int) -> String? { value > 0 ? "\(value)" : nil }

    @MainActor @ViewBuilder var page: some View {
        switch self {
        case .breakdown: LedgerView(mode: .breakdown)
        case .timeline: LedgerView(mode: .timeline)
        case .themes: ThemesView()
        case .tasks: TasksView()
        case .notes: NotesView()
        case .due: DueView()
        case .decks: DecksView()
        case .radar: RadarView()
        case .settings: SettingsView()
        }
    }
}

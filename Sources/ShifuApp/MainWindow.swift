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

    /// The router is a parameter so a harness can open the window already
    /// pointed at a place; the app itself always takes the default.
    init(router: Router = Router()) {
        _router = StateObject(wrappedValue: router)
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
        case .merges:
            MergeReviewView()
        }
    }

    /// What the window is showing, centred in the title bar the way macOS
    /// names a document.
    private var title: String {
        switch router.route {
        case .none: return router.place.title
        case .task(let taskID): return store.taskDetail(taskID)?.task.name ?? "Task"
        case .theme(let themeID): return store.themeDetail(themeID)?.overview.name ?? "Theme"
        case .merges: return "Suggestions"
        }
    }
}

// MARK: - Routing

/// A page opened *from* a row rather than from the source list.
enum Route: Hashable {
    case task(Int64)
    case theme(Int64)
    case merges
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

// MARK: - The source list

/// The permanent left column. What it lists depends on where you are: the
/// places while you are in one, and the open thing's own contents while you
/// are inside a task or a theme — so the window never stops saying where you
/// are, and the way back is where the way in was.
private struct SourceList: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        Group {
            switch router.route {
            case .none: Places()
            case .task(let taskID): TaskContents(taskID: taskID)
            case .theme(let themeID): ThemeContents(themeID: themeID)
            case .merges: MergeContents()
            }
        }
        .frame(width: Instrument.railWidth)
        .background(Instrument.rail)
    }
}

/// The default contents: the ten places, with the count that says whether
/// going there is worth it.
private struct Places: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    var body: some View {
        RailColumn {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shifu")
                        .font(Instrument.sans(14, .semibold))
                        .tracking(-0.14)
                        .foregroundStyle(Instrument.ink)
                    Figure(
                        store.todayMs > 0
                            ? store.todayTotalLabel + " today"
                            : "nothing yet today",
                        size: 10.5, color: Instrument.faint)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)

                ForEach(Region.allCases) { region in
                    VStack(alignment: .leading, spacing: 0) {
                        RailHeading(region.rawValue)
                        ForEach(region.places) { place in
                            RailRow(
                                title: place.title,
                                badge: place.badge(store),
                                urgent: place == .due,
                                selected: router.place == place
                            ) {
                                router.go(to: place)
                            }
                        }
                    }
                }
            }
        } footer: {
            // Capture state and how far the ledger reaches — the two things
            // that explain a screen emptier than the day felt.
            Text(store.captureLine)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.railInk)
            if let through = store.ledgerThrough {
                Figure(
                    "ledger to " + through.formatted(.dateTime.hour().minute()),
                    size: 10.5, color: Instrument.ghost)
            }
        }
    }
}

/// The suggestion queue's contents: nothing but the way back.
private struct MergeContents: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        RailColumn {
            RailBack(title: "Tasks") { router.go(to: .tasks) }
        } footer: {
            Text("Dismissed pairs are never re-suggested.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The shape every source list takes: contents at the top, a footer pinned to
/// the bottom over a rule.
struct RailColumn<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 3) {
                Rule(weight: .section)
                    .padding(.bottom, 7)
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One row of the source list: a name, and the number that says how much is
/// behind it. The count is the whole point of a permanent list — it means you
/// can decide whether to go there without going there.
struct RailRow: View {
    let title: String
    var badge: String?
    var urgent = false
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Instrument.sans(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Instrument.ink : Instrument.railInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty {
                    Figure(badge, size: 11, weight: urgent ? .medium : .regular, color: badgeColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                selected ? Instrument.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var badgeColor: Color {
        if urgent { return Instrument.alert }
        return selected ? Instrument.accentText : Instrument.faint
    }
}

/// The way back out of a task or a theme.
struct RailBack: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("← \(title)")
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.accentText)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A heading inside the source list.
struct RailHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Eyebrow(text, tracking: 1.2)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
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
    case breakdown, timeline, week
    case themes, tasks, notes
    case due, inbox, deck
    case radar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakdown: return "Breakdown"
        case .timeline: return "Timeline"
        case .week: return "Week"
        case .themes: return "Themes"
        case .tasks: return "Tasks"
        case .notes: return "Notes"
        case .due: return "Due"
        case .inbox: return "Inbox"
        case .deck: return "Deck"
        case .radar: return "Radar"
        }
    }

    var region: Region {
        switch self {
        case .breakdown, .timeline, .week: return .ledger
        case .themes, .tasks, .notes: return .vault
        case .due, .inbox, .deck: return .practice
        case .radar: return .signals
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
        case .week: return store.weekTotalLabel
        case .themes: return count(store.themes.count)
        case .tasks: return count(store.matchingTaskCount)
        case .notes: return count(store.noteCount)
        case .due: return count(store.dueNotes.count)
        case .inbox: return count(store.deckSuggestions.count)
        case .deck: return count(store.allCards.count)
        case .radar: return count(store.suggestions.count)
        }
    }

    private func count(_ value: Int) -> String? { value > 0 ? "\(value)" : nil }

    @MainActor @ViewBuilder var page: some View {
        switch self {
        case .breakdown: LedgerView(mode: .breakdown)
        case .timeline: LedgerView(mode: .timeline)
        case .week: LedgerView(mode: .week)
        case .themes: ThemesView()
        case .tasks: TasksView()
        case .notes: NotesView()
        case .due: DueView()
        case .inbox: InboxView()
        case .deck: DeckView()
        case .radar: RadarView()
        }
    }
}

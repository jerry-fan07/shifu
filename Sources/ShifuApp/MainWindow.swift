import AppKit
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
        // Behind the page, watching for the window: the third way out. The
        // guard has to hang on the shell rather than the Settings page — a
        // close click is a departure from *anywhere*, drafts in hand.
        .background(WindowCloseGuard { [weak settings] in
            settings?.confirmDeparture() ?? true
        })
        .onAppear {
            // Leaving Settings with staged edits resolves them first — the
            // same three-way question closing and quitting ask. Weak on both
            // sides: the guard outlives neither model it consults.
            router.departureGuard = { [weak router, weak settings] in
                guard let router, let settings, router.place == .settings
                else { return true }
                return settings.confirmDeparture()
            }
            AppDelegate.settings = settings
        }
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
    /// Asked before a place change; returning false keeps the window where it
    /// is. Installed by the window over the one place with unfinished business
    /// to guard — Settings, while edits are staged (`MainWindow`). Not
    /// consulted for a same-place `go`, which loses nothing.
    var departureGuard: (() -> Bool)?

    func go(to place: Place) {
        if place != self.place, departureGuard?() == false { return }
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

// MARK: - Closing the window with staged edits

/// The red light and ⌘W share exactly one hook — `windowShouldClose` on the
/// window's delegate — and SwiftUI owns that delegate. So the shell wears a
/// zero-sized view whose only job is to learn which `NSWindow` ended up
/// hosting it, and to slip a gate in front of whatever delegate it finds
/// there. The gate answers the close question itself and hands every other
/// delegate duty through untouched.
struct WindowCloseGuard: NSViewRepresentable {
    /// Answered on the close click; false keeps the window open.
    let confirmClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = CloseGuardView()
        let coordinator = context.coordinator
        view.installGate = { [confirmClose] window in
            guard !(window.delegate is WindowCloseGate) else { return }
            let gate = WindowCloseGate(
                chaining: window.delegate, confirmClose: confirmClose)
            window.delegate = gate
            // The window only holds its delegate weakly; the gate lives here.
            coordinator.gate = gate
        }
        return view
    }

    /// Re-asserts on every render: if a scene update ever hands the window a
    /// fresh delegate, the next render puts the gate back in front of it —
    /// the install is a no-op while the gate is already there.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CloseGuardView, let window = view.window
        else { return }
        view.installGate?(window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var gate: WindowCloseGate?
    }
}

/// A zero-sized view behind the page, there only to know its window. It never
/// takes a click.
private final class CloseGuardView: NSView {
    var installGate: ((NSWindow) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { installGate?(window) }
    }
}

/// The delegate the guard installs: one question of its own, everything else
/// forwarded to the delegate SwiftUI had on the window before. The chained
/// delegate is asked *after* the gate allows the close — a veto must stop the
/// question reaching anyone else, or a "Cancel" could still close the window.
final class WindowCloseGate: NSObject, NSWindowDelegate {
    private weak var chained: NSWindowDelegate?
    private let confirmClose: @MainActor () -> Bool

    init(chaining chained: NSWindowDelegate?, confirmClose: @escaping @MainActor () -> Bool) {
        self.chained = chained
        self.confirmClose = confirmClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard MainActor.assumeIsolated({ confirmClose() }) else { return false }
        return chained?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (chained?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if chained?.responds(to: selector) == true { return chained }
        return super.forwardingTarget(for: selector)
    }
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
        // A title bar is a handle, and the system only leaves its own 28 pt
        // strip draggable — ours is 40 pt, so the bottom band of the bar you
        // can see would refuse the drag. The whole bar takes it instead.
        // Nothing in here is clickable, so an overlay costs no target, and the
        // traffic lights live in the window's own title bar view above the
        // content — they keep their clicks.
        .overlay(WindowDragArea())
    }
}

// MARK: - Dragging the window by its bar

/// Makes whatever it covers a handle for the window: press and move drags it,
/// double click does what System Settings says a double click on a title bar
/// does. Put it over a bar, never over a control.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Not private: what a press lands on is the whole behaviour, and the test
/// that checks it asks the window's hit test for this type by name.
final class WindowDragView: NSView {
    /// `performDrag` runs its own event loop until the mouse comes up, so the
    /// press has to reach us rather than being answered by AppKit's own
    /// move-by-background path — which this window doesn't have anyway.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount < 2 else {
            doubleClickAction(on: window)
            return
        }
        window.performDrag(with: event)
    }

    /// Desktop & Dock → "Double-click a window's title bar to". Absent means
    /// the default, which is zoom.
    private func doubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
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

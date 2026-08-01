import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// Renders the real window, against real data, to PNGs you can look at.
///
/// Not an assertion suite — a camera. `screencapture` on this machine returns
/// black without a Screen Recording grant, and `ImageRenderer` refuses to lay
/// out a `ScrollView`, so the only way to see what the app actually draws is
/// to host it in an offscreen `NSWindow` and `cacheDisplay` the layer tree.
///
/// Opt-in, because it is slow and writes files:
///
///     SHIFU_SHOTS=/tmp/shifu-shots SHIFU_HOME=/tmp/shifu-verify \
///         swift test --filter WindowShots
///
/// Point `SHIFU_HOME` at a *copy* of ~/Shifu — the store opens the database
/// read-write, and a real dogfood ledger is the only input that shows whether
/// a table holds up at thirty rows.
@Suite struct WindowShots {
    private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SHIFU_SHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @MainActor @Test func everyPlace() throws {
        guard let directory = Self.outputDirectory else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let store = LedgerStore()
        store.refresh()

        // A crashed run may have left the ledger's persisted Day/Week window
        // flipped, which would silently turn every day shot into a week shot.
        UserDefaults.standard.removeObject(forKey: "shifu.ledger.week")

        for place in Place.allCases {
            shoot(
                place, as: place.rawValue,
                dark: place == .timeline || place == .decks,
                store: store, into: directory)
        }

        shootEverySettingsSection(store: store, into: directory)

        // The Day/Week window is view state, not a place, so the ledger pages
        // get a second pass with it flipped.
        UserDefaults.standard.set(true, forKey: "shifu.ledger.week")
        defer { UserDefaults.standard.removeObject(forKey: "shifu.ledger.week") }
        for place in [Place.breakdown, .timeline] {
            shoot(
                place, as: "\(place.rawValue)-week", dark: place == .timeline,
                store: store, into: directory)
        }
        // The week Breakdown twice: it is the only place that draws rhythm
        // marks, and they are the one thing in the band whose hue is not a
        // series — so it is the one thing whose light and dark steps have to
        // be checked against real rails rather than reasoned about.
        shoot(.breakdown, as: "breakdown-week-dark", dark: true, store: store, into: directory)

        shootPagesBehindARow(store: store, into: directory)
        shootNotes(store: store, into: directory)
    }

    /// The pages that only exist behind a row, so the source list has something
    /// to become.
    @MainActor private func shootPagesBehindARow(
        store: LedgerStore, into directory: URL
    ) {
        if let theme = store.themes.first {
            shoot(
                .themes, route: .theme(theme.id), as: "theme-page", dark: false,
                store: store, into: directory)
        }
        if let task = Self.unrollableTask(store) {
            shoot(
                .tasks, route: .task(task), as: "task-page", dark: true,
                store: store, into: directory)
            // Twice: the page is mostly a day's *prose*, and the hairline spine
            // and the eyebrows it is structured with are the two marks that
            // read differently against a near-white ground.
            shoot(
                .tasks, route: .task(task), as: "task-page-light", dark: false,
                store: store, into: directory)
        }
        if let deck = store.decks.first {
            shoot(
                .decks, route: .deck(deck.id), as: "deck-page", dark: false,
                store: store, into: directory)
        }
        shoot(
            .decks, route: .newDeck, as: "new-deck-page", dark: false,
            store: store, into: directory)
        let liveDecks = Set(store.decks.map(\.key))
        if store.allCards.contains(where: { card in
            card.deck.map { !liveDecks.contains($0) } ?? true
        }) {
            shoot(
                .decks, route: .looseCards, as: "loose-cards", dark: true,
                store: store, into: directory)
        }
    }

    /// The biggest task whose newest day has a *narrative*, falling back to the
    /// biggest task at all.
    ///
    /// The page opens on its newest day, and the newest day is usually today —
    /// whose narrative is written by the analyzer an hour behind the blocks, and
    /// is dropped again by any rebuild that changes the day's content hash
    /// (which this harness performs on the vault copy it is pointed at). So the
    /// obvious subject photographs as a head with nothing under it, which is
    /// correct behaviour and a useless picture.
    @MainActor private static func unrollableTask(_ store: LedgerStore) -> Int64? {
        let bySize = store.filteredTasks.sorted { $0.totalMs > $1.totalMs }
        let unrollable = bySize.first { overview in
            guard let id = overview.task.id, let detail = store.taskDetail(id),
                  let newest = detail.days.first
            else { return false }
            let note = store.workNote(dayStart: newest.dayStart, taskKey: detail.task.key)
            return !(note?.sessionsProse ?? "").isEmpty
        }
        return (unrollable ?? bySize.first)?.task.id
    }

    /// The Notes place has three states worth looking at and one page behind a
    /// row, and `Place.allCases` only reaches the first of them.
    @MainActor private func shootNotes(store: LedgerStore, into directory: URL) {
        store.loadLibrary()
        // The deepest note the vault holds: the shape the page exists for, and
        // the one whose dossier has every section populated.
        let deepest = store.vaultShelf.max { $0.words < $1.words }
        if let deepest {
            shoot(
                .notes, route: .note(deepest.noteID), as: "note-page", dark: false,
                store: store, into: directory)
            shoot(
                .notes, route: .note(deepest.noteID), as: "note-page-dark", dark: true,
                store: store, into: directory)
        }
        // A work note: 654 of the vault's 686 documents are one, and it is the
        // only kind that carries a session timeline and a Captured list.
        if let work = store.vaultShelf.filter({ $0.kind == .work }).max(by: { $0.words < $1.words }) {
            shoot(
                .notes, route: .note(work.noteID), as: "work-note-page", dark: false,
                store: store, into: directory)
        }
        // A task overview, twice: its `## Timeline` renders two ways — dated
        // leads on the rail, or titled dateless bullets as the claims table —
        // and each shape needs to be seen on the page it produces. Falls back
        // to the wordiest when a shape has no example in the vault.
        let overviews = store.vaultShelf.filter { $0.kind == .taskOverview }
            .sorted { $0.words > $1.words }
        func timelineShape(_ noteID: String, dated: Bool) -> Bool {
            guard let body = store.dossier(noteID: noteID)?.body else { return false }
            let hasDated = NoteProse.lines(body).contains {
                if case .dated = $0.kind { return true } else { return false }
            }
            return dated == hasDated
        }
        if let railed = overviews.first(where: { timelineShape($0.noteID, dated: true) })
            ?? overviews.first {
            shoot(
                .notes, route: .note(railed.noteID), as: "overview-note-page",
                dark: false, store: store, into: directory)
        }
        if let titled = overviews.first(where: { timelineShape($0.noteID, dated: false) }) {
            shoot(
                .notes, route: .note(titled.noteID), as: "overview-note-page-titled",
                dark: false, store: store, into: directory)
        }
        // A trace, so the page's "this is a receipt, not a note" line is
        // visible rather than theoretical.
        store.noteFilter.depth = .everything
        store.loadLibrary()
        if let trace = store.vaultShelf.first(where: { $0.depth == .trace }) {
            shoot(
                .notes, route: .note(trace.noteID), as: "note-page-trace", dark: false,
                store: store, into: directory)
        }
        shoot(.notes, as: "notes-with-traces", dark: false, store: store, into: directory)
        store.noteFilter = NoteLibraryFilter()

        store.vaultQuery = "capture daemon"
        shoot(.notes, as: "notes-search", dark: false, store: store, into: directory)
        store.vaultQuery = ""
        store.loadLibrary()
    }

    /// Settings is one place with a rail of its own, so it gets one shot per
    /// section — a single settings.png would only ever show Capture.
    @MainActor private func shootEverySettingsSection(
        store: LedgerStore, into directory: URL
    ) {
        for section in SettingsSection.allCases {
            let settings = SettingsStore()
            settings.section = section
            let router = Router()
            router.go(to: .settings)
            let slug = section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            shoot(
                MainWindow(router: router, settings: settings).environmentObject(store),
                to: directory.appendingPathComponent("settings-\(slug).png"),
                dark: section == .privacy)
        }
    }

    /// One shot: the window pointed at `place`, optionally with a pushed
    /// `route` over it, written as `name`.png.
    @MainActor private func shoot(
        _ place: Place, route: Route? = nil, as name: String, dark: Bool,
        store: LedgerStore, into directory: URL
    ) {
        let router = Router()
        router.go(to: place)
        if let route { router.open(route) }
        shoot(
            MainWindow(router: router).environmentObject(store),
            to: directory.appendingPathComponent("\(name).png"), dark: dark)
    }

    /// Hosts a view in an offscreen window, lets it settle, and writes what
    /// the layer tree drew.
    /// `SHIFU_SHOT_WIDTH` drives the window to its minimum (960) or wider, so
    /// a column that only fits on a big display is visible as a fault.
    /// `SHIFU_SHOT_HEIGHT` makes the film taller than any real window — the
    /// only way to see below a scroll fold, since the harness can't scroll.
    private static var width: CGFloat {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOT_WIDTH"],
              let width = Double(raw)
        else { return 1_180 }
        return CGFloat(width)
    }

    private static var height: CGFloat {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOT_HEIGHT"],
              let height = Double(raw)
        else { return 760 }
        return CGFloat(height)
    }

    @MainActor private func shoot(
        _ view: some View, to url: URL, dark: Bool,
        size: CGSize = CGSize(width: Self.width, height: Self.height)
    ) {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)

        // The store's reads happen in onAppear; a ScrollView's content is laid
        // out a runloop turn after that. One second is empirically enough for
        // both on a warm database and cheap on a cold one.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

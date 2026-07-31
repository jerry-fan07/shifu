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
        // flipped, or its picker parked on Focus — either would silently turn
        // every Breakdown shot into a different page.
        UserDefaults.standard.removeObject(forKey: "shifu.ledger.week")
        UserDefaults.standard.removeObject(forKey: "shifu.ledger.lens")

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
        shootFocus(store: store, into: directory)

        // The pages that only exist behind a row, so the source list has
        // something to become.
        if let theme = store.themes.first {
            shoot(
                .themes, route: .theme(theme.id), as: "theme-page", dark: false,
                store: store, into: directory)
        }
        if let task = store.filteredTasks.first?.task.id {
            shoot(
                .tasks, route: .task(task), as: "task-page", dark: true,
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
        shootNotes(store: store, into: directory)
    }

    /// The picker's Focus position is view state the same way Day/Week is — a
    /// persisted raw — so the session bands and the score head get their own
    /// pass over both windows. Gold on real rails, both appearances: the warm
    /// slot is the one hue in the band that is not a series.
    @MainActor private func shootFocus(store: LedgerStore, into directory: URL) {
        UserDefaults.standard.set("Focus", forKey: "shifu.ledger.lens")
        defer { UserDefaults.standard.removeObject(forKey: "shifu.ledger.lens") }
        UserDefaults.standard.set(true, forKey: "shifu.ledger.week")
        shoot(.breakdown, as: "breakdown-focus-week", dark: false, store: store, into: directory)
        shoot(
            .breakdown, as: "breakdown-focus-week-dark", dark: true,
            store: store, into: directory)
        UserDefaults.standard.removeObject(forKey: "shifu.ledger.week")
        shoot(.breakdown, as: "breakdown-focus", dark: false, store: store, into: directory)
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
    private static var width: CGFloat {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOT_WIDTH"],
              let width = Double(raw)
        else { return 1_180 }
        return CGFloat(width)
    }

    @MainActor private func shoot(
        _ view: some View, to url: URL, dark: Bool,
        size: CGSize = CGSize(width: Self.width, height: 760)
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

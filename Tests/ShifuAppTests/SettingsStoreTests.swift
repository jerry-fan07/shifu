import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The Settings page stages dial edits behind a Save button. The contract
/// pinned here is the one the bar's copy makes: nothing reaches the settings
/// table before Save, everything staged reaches it on Save, and a draft that
/// matches what's stored is not a draft at all.
@Suite @MainActor struct SettingsStoreTests {
    private let heartbeat = SettingsCatalog.heartbeatSeconds

    private func freshStore() throws -> (SettingsStore, ShifuDatabase) {
        let database = try ShifuDatabase.inMemory()
        let store = SettingsStore(database: database)
        store.load()
        return (store, database)
    }

    @Test func editsStayOffDiskUntilSaved() throws {
        let (store, database) = try freshStore()
        let raised = heartbeat.defaultValue + heartbeat.step

        store.set(heartbeat, to: raised)

        #expect(store.hasUnsavedChanges)
        // The dial shows the draft; the table still holds the old value —
        // the daemon must not see a half-finished edit.
        #expect(store.value(for: heartbeat) == raised)
        #expect(Settings.value(heartbeat, database: database) == heartbeat.defaultValue)

        store.save()

        #expect(!store.hasUnsavedChanges)
        #expect(Settings.value(heartbeat, database: database) == raised)
        #expect(store.value(for: heartbeat) == raised)
    }

    @Test func dialingBackToStoredDisarmsTheBar() throws {
        let (store, _) = try freshStore()

        store.set(heartbeat, to: heartbeat.defaultValue + heartbeat.step)
        store.set(heartbeat, to: heartbeat.defaultValue)

        #expect(!store.hasUnsavedChanges)
    }

    @Test func discardDropsEveryDraft() throws {
        let (store, database) = try freshStore()
        let key = SettingsCatalog.deepseekAPIKey

        store.set(heartbeat, to: heartbeat.defaultValue + heartbeat.step)
        store.set(key, to: "sk-half-typed")
        #expect(store.hasUnsavedChanges)

        store.discardChanges()

        #expect(!store.hasUnsavedChanges)
        #expect(store.value(for: heartbeat) == heartbeat.defaultValue)
        #expect(store.value(for: key).isEmpty)
        #expect(Settings.value(key, database: database).isEmpty)
    }

    // MARK: - Leaving with staged edits (the departure question)

    @Test func departingWithSavePersistsAndAllowsLeaving() throws {
        let (store, database) = try freshStore()
        let raised = heartbeat.defaultValue + heartbeat.step
        store.set(heartbeat, to: raised)

        #expect(store.resolveDeparture(.save))
        #expect(!store.hasUnsavedChanges)
        #expect(Settings.value(heartbeat, database: database) == raised)
    }

    @Test func departingWithDiscardDropsDraftsAndAllowsLeaving() throws {
        let (store, database) = try freshStore()
        store.set(heartbeat, to: heartbeat.defaultValue + heartbeat.step)

        #expect(store.resolveDeparture(.discard))
        #expect(!store.hasUnsavedChanges)
        #expect(Settings.value(heartbeat, database: database) == heartbeat.defaultValue)
    }

    @Test func stayingKeepsTheDraftsAndDeniesLeaving() throws {
        let (store, database) = try freshStore()
        let raised = heartbeat.defaultValue + heartbeat.step
        store.set(heartbeat, to: raised)

        #expect(!store.resolveDeparture(.stay))
        #expect(store.hasUnsavedChanges)
        #expect(store.value(for: heartbeat) == raised)
        #expect(Settings.value(heartbeat, database: database) == heartbeat.defaultValue)
    }

    /// The guard is the router's one veto point: a false answer keeps the
    /// window where it is, and a same-place `go` never asks — it loses
    /// nothing, so it has nothing to ask about.
    @Test func routerDepartureGuardVetoesThePlaceChange() {
        let router = Router()
        router.go(to: .settings)

        var asked = 0
        var allow = false
        router.departureGuard = { asked += 1; return allow }

        router.go(to: .breakdown)
        #expect(router.place == .settings)
        #expect(asked == 1)

        router.go(to: .settings)   // same place: not consulted
        #expect(asked == 1)

        allow = true
        router.go(to: .breakdown)
        #expect(router.place == .breakdown)
        #expect(asked == 2)
    }

    @Test func saveWritesEveryKindOfDraft() throws {
        let (store, database) = try freshStore()
        let backend = SettingsCatalog.analysisBackend
        let key = SettingsCatalog.deepseekAPIKey
        let choice = backend.options.map(\.value).first { $0 != backend.defaultValue }!

        store.set(heartbeat, to: heartbeat.range.upperBound)
        store.set(backend, to: choice)
        store.set(key, to: "  sk-test  ")
        store.save()

        #expect(!store.hasUnsavedChanges)
        #expect(Settings.value(heartbeat, database: database) == heartbeat.range.upperBound)
        #expect(Settings.value(backend, database: database) == choice)
        // Trimmed on the way down, exactly as `Settings.set` always has.
        #expect(Settings.value(key, database: database) == "sk-test")
    }
}

/// The window's close button is the third way out with staged edits, and the
/// only one whose hook — `windowShouldClose` — belongs to a delegate SwiftUI
/// installs. The gate slips in front of it; what is pinned here is that a
/// veto really stops the close, and that the delegate behind it keeps every
/// duty it had.
@Suite @MainActor struct WindowCloseGateTests {
    /// Stands in for whatever delegate SwiftUI put on the window: answers the
    /// close question, counts being asked, and carries a second duty
    /// (`windowDidResize`) so forwarding has something to prove.
    private final class ChainedDelegate: NSObject, NSWindowDelegate {
        var answer = true
        var asked = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asked += 1
            return answer
        }

        func windowDidResize(_ notification: Notification) {}
    }

    private func bareWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }

    @Test func vetoStopsTheCloseBeforeTheChainedDelegateHears() {
        let chained = ChainedDelegate()
        let gate = WindowCloseGate(chaining: chained, confirmClose: { false })

        #expect(!gate.windowShouldClose(bareWindow()))
        #expect(chained.asked == 0)
    }

    @Test func allowedCloseStillHonorsTheChainedAnswer() {
        let chained = ChainedDelegate()
        let gate = WindowCloseGate(chaining: chained, confirmClose: { true })
        let window = bareWindow()

        chained.answer = false
        #expect(!gate.windowShouldClose(window))
        chained.answer = true
        #expect(gate.windowShouldClose(window))
        #expect(chained.asked == 2)
    }

    @Test func aloneTheGateAnswersForItself() {
        let gate = WindowCloseGate(chaining: nil, confirmClose: { true })
        #expect(gate.windowShouldClose(bareWindow()))
    }

    @Test func everyOtherDutyForwardsToTheChainedDelegate() {
        let chained = ChainedDelegate()
        let gate = WindowCloseGate(chaining: chained, confirmClose: { true })
        let resize = #selector(NSWindowDelegate.windowDidResize(_:))
        let move = #selector(NSWindowDelegate.windowDidMove(_:))

        #expect(gate.responds(to: resize))
        #expect(gate.forwardingTarget(for: resize) as? ChainedDelegate === chained)
        // A duty neither of them carries stays uncarried — claiming it would
        // make AppKit call into nothing.
        #expect(!gate.responds(to: move))
    }

    /// The representable end: hosting the guard puts the gate in front of the
    /// window's existing delegate, and the close question passes through both.
    @Test func hostingTheGuardInstallsTheGate() throws {
        let window = bareWindow()
        let previous = ChainedDelegate()
        window.delegate = previous

        let host = NSHostingView(rootView: WindowCloseGuard(confirmClose: { true }))
        host.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: 200))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let gate = try #require(window.delegate as? WindowCloseGate)
        #expect(gate.windowShouldClose(window))
        #expect(previous.asked == 1)
    }
}

import AppKit
import ShifuCore
import SwiftUI

// Fullscreen for the Rewind players (design.md §3.6): the footage takes the
// whole screen, with the transport and the rail floating over its foot the way
// a video player's controls sit over its video. The page keeps its ordinary
// layout; this is the door out of it.

/// Presents `content` in a borderless window covering the screen the app is
/// on, while `active` is true. Lives in the page's own hierarchy — like the
/// drop-down's child panel — so every render refreshes the hosted view and the
/// fullscreen player stays live: scrubbing, the tick, and the buffer all flow
/// through the same state the page draws from.
///
/// **Not** the snip overlay's configuration, deliberately: snip must not
/// activate Shifu and has to sit above everything on every Space, while a
/// player is an ordinary key window on one screen — ⌘-tab leaves it behind
/// like any other window, and only the menu bar and Dock step aside.
struct RewindFullscreen<Content: View>: NSViewRepresentable {
    @Binding var active: Bool
    /// The keys the player wants out here — space, the arrows. Returning true
    /// swallows the event; escape never reaches this, because leaving is the
    /// window's own business. One monitor, not two: a second one racing this
    /// for the same keyDown is how a transport ends up double-stepping.
    var onKey: (UInt16) -> Bool = { _ in false }
    /// The pointer moved over the player — what brings the chrome back.
    ///
    /// An event monitor rather than `onContinuousHover`, deliberately. Hover is
    /// a *tracking area*: it re-reports itself when the view is rebuilt, and
    /// this view rebuilds thirty times a second while the footage is playing —
    /// so the chrome would be told the pointer had moved forever and never
    /// hide, exactly when hiding matters most. Mouse-moved events are the
    /// pointer actually moving. (Measured: the fullscreen film with the chrome
    /// forced hidden still photographed the bar, because the real mouse was
    /// resting over the offscreen window.)
    var onMotion: () -> Void = {}
    let content: () -> Content

    func makeNSView(context: Context) -> NSView { FullscreenAnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.exit = { active = false }
        coordinator.key = onKey
        coordinator.motion = onMotion
        if active {
            coordinator.present(over: nsView.window, rootView: content())
        } else {
            coordinator.dismiss()
        }
    }

    /// Leaving the page while fullscreen is up — the source list can navigate
    /// away under it — takes the window down with it rather than stranding a
    /// frozen frame over the whole screen.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private var window: FullscreenPlayerWindow?
        private var hosting: NSHostingView<Content>?
        private var escapeMonitor: Any?
        private var motionMonitor: Any?
        private var priorOptions: NSApplication.PresentationOptions?
        var exit: () -> Void = {}
        var key: (UInt16) -> Bool = { _ in false }
        var motion: () -> Void = {}

        func present(over host: NSWindow?, rootView: Content) {
            if let hosting {
                hosting.rootView = rootView
                return
            }
            let screen = host?.screen ?? NSScreen.main
            let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
            let window = FullscreenPlayerWindow.make(frame: frame)
            let hosting = NSHostingView(rootView: rootView)
            hosting.frame = CGRect(origin: .zero, size: frame.size)
            window.contentView = hosting
            self.window = window
            self.hosting = hosting

            // The pair is required — AppKit rejects `autoHideMenuBar` alone.
            // The prior options come back exactly as they were on the way out.
            priorOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]

            window.makeKeyAndOrderFront(nil)
            escapeMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.keyCode == FullscreenPlayerWindow.escapeKey {
                    self.exit()
                    return nil
                }
                return self.key(event.keyCode) ? nil : event
            }
            // Dragged as well as moved: scrubbing the rail is the pointer
            // being used, and a bar that hid mid-drag would be absurd.
            motionMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.motion()
                return event
            }
        }

        func dismiss() {
            guard let window else { return }
            for monitor in [escapeMonitor, motionMonitor].compactMap({ $0 }) {
                NSEvent.removeMonitor(monitor)
            }
            escapeMonitor = nil
            motionMonitor = nil
            window.orderOut(nil)
            self.window = nil
            hosting = nil
            if let priorOptions { NSApp.presentationOptions = priorOptions }
            priorOptions = nil
        }
    }
}

/// A zero-sized view whose only job is to know the window the page is in —
/// the same trick `WindowCloseGuard` plays. It never takes a click.
private final class FullscreenAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A borderless window that can still be key — borderless windows refuse key
/// status by default, and without it escape has nowhere to land.
final class FullscreenPlayerWindow: NSWindow {
    static let escapeKey: UInt16 = 53
    /// The transport's keys, so the players name them rather than spelling
    /// virtual key codes into a switch.
    static let spaceKey: UInt16 = 49
    static let leftKey: UInt16 = 123
    static let rightKey: UInt16 = 124

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Configuration in one place so a test can hold it to the light.
    static func make(frame: CGRect) -> FullscreenPlayerWindow {
        let window = FullscreenPlayerWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Borderless windows release themselves on close by default — under
        // ARC that is an over-release the first time the user leaves.
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.isMovable = false
        // The chrome hides itself when the pointer goes still, so the pointer
        // going still has to be something this window can notice.
        window.acceptsMouseMovedEvents = true
        window.setFrame(frame, display: false)
        return window
    }
}

/// Whether the fullscreen player's chrome — the transport bar, the exit chip,
/// the caption — is on screen (design.md §3.6).
///
/// A player's controls sit *over* the footage, which means that while they are
/// up they are also hiding the bottom of it. Every real one answers this the
/// same way: the chrome goes when the pointer goes still and comes back the
/// moment it moves, so the default state of a screen you are watching is the
/// whole screen.
///
/// The motion timestamp is deliberately **not** published. A mouse move
/// crossing full-screen footage would otherwise invalidate the body on every
/// event; only the visibility flip is worth a redraw.
@MainActor final class FullscreenChrome: ObservableObject {
    @Published private(set) var visible = true
    /// The pointer is over the bar itself. Controls must not vanish from under
    /// the hand reaching for them, however still that hand is.
    var pinned = false {
        didSet { if pinned { stir() } }
    }

    private let idleSeconds: TimeInterval
    private var lastMotion = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?

    /// Long enough to read the readout after nudging the mouse, short enough
    /// that watching is the resting state.
    init(idleSeconds: TimeInterval = 2.5) {
        self.idleSeconds = idleSeconds
    }

    /// Entering fullscreen: chrome up, and the idle watch running.
    func begin() {
        stir()
        guard timer == nil else { return }
        // Twice a second is plenty to notice stillness, and costs nothing
        // next to the footage it is watching over. `.common`, like the
        // transport's, so dragging the rail doesn't stop the watch.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Leaving. Idempotent, because both the window going away and the page
    /// going away call it, and either may be first.
    func end() {
        timer?.invalidate()
        timer = nil
        pinned = false
        visible = true
    }

    /// The pointer moved, or a key was pressed — whatever it was, someone is
    /// there.
    func stir() {
        lastMotion = ProcessInfo.processInfo.systemUptime
        visible = true
    }

    /// A click on the footage. The one way to *dismiss* the chrome deliberately
    /// rather than by waiting, and the way back if a trackpad never quite goes
    /// still.
    func toggle() {
        if visible { hide() } else { stir() }
    }

    private func check() {
        // Pinned counts as motion: the clock restarts when the pointer leaves
        // the bar, rather than hiding it the instant it does.
        guard !pinned else { return stir() }
        guard visible,
            ProcessInfo.processInfo.systemUptime - lastMotion >= idleSeconds
        else { return }
        hide()
    }

    private func hide() {
        visible = false
        // The cursor is chrome too. `untilMouseMoves` rather than `hide()`:
        // AppKit balances it itself, so there is no way to strand an
        // invisible pointer over the rest of the app.
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

/// The fullscreen composition: the footage edge to edge, an exit chip in the
/// top corner, and whatever transport the page brings in a bar over the foot —
/// on a translucent run of the page ground, so every Instrument token keeps
/// its contrast in both modes, whatever the frame behind it shows.
///
/// The chrome floats *over* the footage rather than taking layout from it, so
/// hiding it (`FullscreenChrome`) uncovers the bottom of the frame without
/// resizing or re-laying anything — the image never moves under the controls
/// coming and going.
struct RewindFullscreenPlayer<Bar: View>: View {
    let frame: RewindFrame?
    var caption: String?
    @ObservedObject var chrome: FullscreenChrome
    let onExit: () -> Void
    @ViewBuilder var bar: Bar

    var body: some View {
        ZStack(alignment: .bottom) {
            // The caption is chrome too — it comes and goes with the rest,
            // so "hidden" means the whole screen is footage.
            RewindViewport(frame: frame, caption: chrome.visible ? caption : nil, bare: true)
                .contentShape(Rectangle())
                .onTapGesture { chrome.toggle() }
            if chrome.visible {
                VStack(alignment: .leading, spacing: 8) {
                    bar
                }
                .padding(.horizontal, Instrument.gutter)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(Instrument.ground.opacity(0.94))
                .overlay(alignment: .top) { Rule(weight: .section) }
                .onHover { chrome.pinned = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if chrome.visible {
                OutlineButton(title: "Exit fullscreen  ·  esc", action: onExit)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .background(Instrument.ground)
        .animation(.easeOut(duration: 0.18), value: chrome.visible)
    }
}

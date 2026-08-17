import ShifuCore
import SwiftUI

// Shifu.app — a full desktop app with a menu bar companion (design.md §7).
// The main window is one instrument: a permanent source list and one page.
// The menu bar item stays the always-visible surface for state, pause, and
// Focus Mode.
@main
struct ShifuApp: App {
    @StateObject private var store = LedgerStore()
    /// Owned by the app rather than the window so the menu bar item and the
    /// ⌘, command can point the dashboard at a place before opening it.
    @StateObject private var router = Router()
    /// Exists for one interception: quitting with staged settings edits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Keep the bundled daemon registered (and migrate a ~/Shifu/bin dev
        // install) on every launch — but not before onboarding has shown what
        // capture means. First-run registration happens when onboarding
        // finishes instead.
        if UserDefaults.standard.bool(forKey: "shifu.onboarded") {
            DaemonService.syncRegistration()
        }
    }

    var body: some Scene {
        Window("Shifu", id: "dashboard") {
            MainWindow(router: router)
                .environmentObject(store)
                .task {
                    // Menu opens refresh implicitly; the window polls gently.
                    while !Task.isCancelled {
                        store.refresh()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
        }
        .defaultSize(width: 1_280, height: 820)
        // The window draws its own title bar: the traffic lights float over it,
        // the centre names what you are looking at, and the state indicator
        // sits at the right where it can always be seen.
        .windowStyle(.hiddenTitleBar)
        // Settings is a place in the window, not a scene of its own — but ⌘,
        // still has to do what macOS users expect.
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
                    .environmentObject(router)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(router)
        } label: {
            MenuBarLabel(store: store)
        }
        // A window rather than a menu: the panel leads with two lines of
        // figures, and an NSMenu can only render them as disabled menu items.
        .menuBarExtraStyle(.window)

        // Resizable: cards can carry code blocks and display math (§5.2).
        Window("Review", id: "review") {
            ReviewSessionView()
                .environmentObject(store)
        }
        .defaultSize(width: 520, height: 500)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The one delegate duty SwiftUI can't express: ⌘Q and the menu bar's Quit
/// both land in `terminate`, and quitting with staged settings edits would
/// silently drop them. Same three-way question as leaving the Settings place
/// (`MainWindow`'s departure guard), same resolution rules.
///
/// It also homes the deadline notifier (design.md §4.5), for its lifetime: the
/// dashboard window's own 60 s poll dies with the window, and a reminder that
/// only arrives while the dashboard is open is not a reminder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The live Settings model, set by the window that owns it. Weak, so a
    /// closed window's store can die — and with it, the gate: no drafts can
    /// outlive the window they were typed into.
    static weak var settings: SettingsStore?

    private let deadlines = DeadlineNotifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not before onboarding, like daemon registration: the first thing a
        // new install should do is explain itself, not ask for permission to
        // interrupt. With no deadlines recorded the notifier asks for nothing
        // anyway, so this gate only matters for a reinstall over old data.
        guard UserDefaults.standard.bool(forKey: "shifu.onboarded") else { return }
        deadlines.start()
    }

    func applicationShouldTerminate(
        _ application: NSApplication
    ) -> NSApplication.TerminateReply {
        (Self.settings?.confirmDeparture() ?? true) ? .terminateNow : .terminateCancel
    }
}

/// The app menu's "Settings…": points the dashboard at the Settings place —
/// there is no separate settings window to open.
private struct SettingsCommand: View {
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            router.go(to: .settings)
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// The menu bar panel (§7): the day in two lines, then the four things you
/// might want from a menu bar — the switch, the pause, the queue, the window.
private struct MenuBarPanel: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Figure(
                    store.isPaused ? "Paused" : "\(store.todayTotalLabel) today",
                    size: 13, weight: .medium)
                Text(store.isPaused ? store.captureLine : store.todayHeadline)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .padding(.bottom, 7)

            separator
            FocusModeMenuLine()

            separator
            if store.isPaused {
                MenuLine(title: "Resume capture") { store.resume() }
            } else {
                MenuLine(title: "Pause 1 hour") {
                    store.pause(until: Date().addingTimeInterval(3_600))
                }
                MenuLine(title: "Pause until tomorrow") {
                    store.pause(until: Calendar.current.startOfDay(
                        for: Date().addingTimeInterval(86_400)))
                }
            }

            separator
            RewindMenuLines()

            separator
            DeadlineMenuLine()
            MenuLine(
                title: "Review",
                trailing: store.dueNotes.isEmpty ? nil : "\(store.dueNotes.count) due",
                urgent: !store.dueNotes.isEmpty
            ) {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuLine(title: "Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuLine(title: "Settings…") {
                router.go(to: .settings)
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }

            separator
            MenuLine(title: "Quit Shifu") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        // Escape closes the panel, like every other one Shifu draws.
        .background(MenuBarEscapeCloser(dismiss: dismiss))
        .onAppear {
            store.refresh()       // menu open = refresh
            store.runAnalysis()   // …and fold in the latest captures
        }
    }

    private var separator: some View {
        Rule(weight: .edge).padding(.vertical, 4)
    }
}

/// The Focus Mode line wears the switch itself — the same control as the rail's
/// foot and the Settings page, so the state looks the same everywhere it can
/// be flipped. The whole row stays the target, like every other line here.
///
/// It wears the clock too, and this is the surface that most needs it: the menu
/// bar is reachable without the window, so "how long have I been at this" is
/// one click from anywhere.
private struct FocusModeMenuLine: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var hovering = false

    var body: some View {
        Button {
            store.toggleFocusMode()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Focus Mode")
                        .font(Instrument.sans(13))
                        .foregroundStyle(Instrument.ink)
                    Spacer(minLength: 0)
                    ToggleSwitch(isOn: store.focusModeOn) { store.toggleFocusMode() }
                }
                FocusTimerLine(size: 11)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(hovering ? Instrument.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Focus Mode")
    }
}

/// Rewind's two verbs in the menu bar (design.md §3.6) — the surface they were
/// asked for, because both are things you want *while looking at something
/// else*, which is exactly when the main window isn't open.
///
/// Neither takes a screenshot here. The app writes a `RewindRequest` control
/// file and the daemon does the work, for the reason there is no IPC in Shifu:
/// the daemon holds the Screen Recording grant, the exclusion list and the
/// buffer, and a second process capable of grabbing the screen is a second
/// thing to have to trust.
///
/// Both lines disappear while recording is off and go quiet while capture is
/// paused. A menu item that silently does nothing is worse than one that isn't
/// there — and a paused Shifu screenshotting on request would be the exact
/// thing pause promises it won't do.
private struct RewindMenuLines: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.rewindSettings.recording {
            if store.isPaused {
                MenuLine(title: "Rewind", trailing: "paused") { open() }
            } else {
                MenuLine(
                    title: "Save the last \(store.rewindSettings.bufferMinutes) min",
                    trailing: buffered
                ) {
                    store.saveRewind()
                }
                MenuLine(title: "Snip a region…") { store.snipRegion() }
            }
        } else {
            MenuLine(title: "Rewind", trailing: "off") { open() }
        }
    }

    /// How much is actually rewindable — the one figure that decides whether
    /// saving is worth doing, and it is only ever known here.
    private var buffered: String? {
        let seconds = store.rewindBuffer.spanMs / 1_000
        guard seconds > 0 else { return "filling" }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }

    private func open() {
        router.go(to: .rewind)
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The nearest deadline, in the menu bar (design.md §4.5).
///
/// One line, and only when something is actually near: the menu bar is the
/// surface you can see without opening anything, so a deadline a month out
/// sitting here permanently would train the eye to skip the row that matters.
/// With nothing pressing it shows the way in instead, because a place you can
/// only reach when it has contents is a place nobody finds.
private struct DeadlineMenuLine: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let pressing = store.pressingDeadlines
        MenuLine(
            title: pressing.first.map { $0.deadline.title } ?? "Deadlines",
            trailing: trailing(pressing),
            urgent: isOverdue(pressing.first)
        ) {
            router.go(to: .tasks)
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The nearest one's distance, plus a count when it isn't the only one —
    /// "tomorrow +2" is the whole state of the queue in nine characters.
    private func trailing(_ pressing: [DeadlineHorizon.Standing]) -> String? {
        guard let nearest = pressing.first else {
            return store.comingUp.isEmpty ? "none" : "\(store.comingUp.count) later"
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let days = DeadlineHorizon.daysUntil(dueAt: nearest.deadline.dueAt, now: now)
        let phrase = days < 0 ? "overdue" : DeadlineCopy.whenPhrase(daysLeft: days)
        return pressing.count > 1 ? "\(phrase) +\(pressing.count - 1)" : phrase
    }

    private func isOverdue(_ standing: DeadlineHorizon.Standing?) -> Bool {
        guard let standing else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return DeadlineHorizon.daysUntil(dueAt: standing.deadline.dueAt, now: now) <= 0
    }
}

/// One row of the menu bar panel: a verb on the left, its current state on the
/// right, and a hover fill so it reads as a menu item rather than a label.
private struct MenuLine: View {
    let title: String
    var trailing: String?
    var urgent = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                if let trailing {
                    Figure(
                        trailing, size: 11.5,
                        color: urgent ? Instrument.alert : Instrument.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(hovering ? Instrument.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

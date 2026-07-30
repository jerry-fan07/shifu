import ShifuCore
import SwiftUI

// Shifu.app — a full desktop app with a menu bar companion (design.md §7).
// The main window is one instrument: a permanent source list and one page.
// The menu bar item stays the always-visible surface for state, pause, and
// Work Mode.
@main
struct ShifuApp: App {
    @StateObject private var store = LedgerStore()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        Window("Shifu", id: "dashboard") {
            MainWindow()
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

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            if let mark = MenuBarMark.image(paused: store.isPaused) {
                Image(nsImage: mark)
                    .accessibilityLabel(store.isPaused ? "Shifu, resting" : "Shifu, watching")
            } else {
                Image(systemName: store.isPaused ? "pause" : "chart.bar.xaxis")
            }
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

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

/// The menu bar panel (§7): the day in two lines, then the four things you
/// might want from a menu bar — the switch, the pause, the queue, the window.
private struct MenuBarPanel: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openWindow) private var openWindow

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
            MenuLine(title: "Work Mode", trailing: store.workModeOn ? "on" : "off") {
                store.toggleWorkMode()
            }

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
            SettingsLink {
                Text("Settings…")
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            separator
            MenuLine(title: "Quit Shifu") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .onAppear {
            store.refresh()       // menu open = refresh
            store.runAnalysis()   // …and fold in the latest captures
        }
    }

    private var separator: some View {
        Rule(weight: .edge).padding(.vertical, 4)
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

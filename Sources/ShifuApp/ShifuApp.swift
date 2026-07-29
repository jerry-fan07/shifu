import ShifuCore
import SwiftUI

// Shifu.app — a full desktop app with a menu bar companion (design.md §7).
// The main window carries the sidebar and pages; the menu bar item stays the
// always-visible surface for state, pause, and Work Mode.
@main
struct ShifuApp: App {
    @StateObject private var store = LedgerStore()
    @StateObject private var settings = SettingsStore()
    @Environment(\.openWindow) private var openWindow

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
        .defaultSize(width: 1080, height: 700)

        MenuBarExtra {
            Text(store.todaySummaryLine)
                .onAppear {
                    store.refresh()       // menu open = refresh
                    store.runAnalysis()   // …and fold in the latest captures
                }

            Divider()

            Button(store.workModeOn ? "Work Mode: on ✓" : "Work Mode") {
                store.toggleWorkMode()
            }

            Divider()

            if store.isPaused {
                Button("Resume capture") { store.resume() }
                if let until = store.pausedUntil {
                    Text("Paused until \(until, format: .dateTime.hour().minute())")
                }
            } else {
                Button("Pause 1 hour") {
                    store.pause(until: Date().addingTimeInterval(3_600))
                }
                Button("Pause until tomorrow") {
                    let tomorrow = Calendar.current.startOfDay(
                        for: Date().addingTimeInterval(86_400))
                    store.pause(until: tomorrow)
                }
            }

            Divider()

            if !store.dueNotes.isEmpty {
                Button("Review · \(store.dueNotes.count) due") {
                    openWindow(id: "review")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Button("Open Shifu") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            if let mark = MenuBarMark.image(paused: store.isPaused) {
                Image(nsImage: mark)
                    .accessibilityLabel(store.isPaused ? "Shifu, resting" : "Shifu, watching")
            } else {
                Image(systemName: store.isPaused ? "zzz" : "mountain.2.fill")
            }
        }
        .menuBarExtraStyle(.menu)

        // Resizable: cards can carry code blocks and display math (§5.2).
        Window("Review", id: "review") {
            ReviewSessionView()
                .environmentObject(store)
                .tint(Dojo.accent)
        }
        .defaultSize(width: 520, height: 480)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .tint(Dojo.accent)
        }
    }
}

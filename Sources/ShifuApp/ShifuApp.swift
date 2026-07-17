import ShifuCore
import SwiftUI

// Shifu.app — menu bar UI (design.md §7). One menu bar item, one window.
@main
struct ShifuApp: App {
    @StateObject private var store = LedgerStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Shifu", systemImage: store.isPaused ? "eye.slash" : "eye") {
            Text(store.todaySummaryLine)
                .onAppear { store.refresh() }   // menu open = refresh

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

            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Window("Shifu", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
                .task {
                    // Menu opens refresh implicitly; the window polls gently.
                    while !Task.isCancelled {
                        store.refresh()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
        }
        .defaultSize(width: 720, height: 640)

        Window("Review", id: "review") {
            ReviewSessionView()
                .environmentObject(store)
        }
        .defaultSize(width: 440, height: 360)
        .windowResizability(.contentSize)
    }
}

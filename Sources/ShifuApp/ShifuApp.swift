import ShifuCore
import SwiftUI

// Shifu.app — menu bar UI (design.md §7). Phase 0: empty menu bar extra.
@main
struct ShifuApp: App {
    var body: some Scene {
        MenuBarExtra("Shifu", systemImage: "eye") {
            Text("Shifu \(Shifu.version)")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

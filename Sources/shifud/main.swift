import AppKit
import Foundation
import ShifuCore

// shifud — capture daemon (design.md §3). Headless LaunchAgent; no network.

// Line-buffer stdout so LaunchAgent log files are written promptly.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments

if let flagIndex = arguments.firstIndex(of: "--synthetic-feed"),
   flagIndex + 1 < arguments.count, let count = Int(arguments[flagIndex + 1]) {
    try SyntheticFeed.run(count: count)
    exit(0)
}

if arguments.contains("--version") {
    print("shifud \(Shifu.version)")
    exit(0)
}

try ShifuPaths.ensureHomeExists()
let database = try ShifuDatabase(at: ShifuPaths.database)
let recorder = ObservationRecorder(database: database)
let exclusions = try Exclusions(database: database)
let engine = CaptureEngine(recorder: recorder, exclusions: exclusions)
let daemon = Daemon(engine: engine)

log("shifud \(Shifu.version) starting — home: \(ShifuPaths.home.path)")
daemon.start()

// Keep a reference alive for the process lifetime and run forever.
withExtendedLifetime(daemon) {
    RunLoop.main.run()
}

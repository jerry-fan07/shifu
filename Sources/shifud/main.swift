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

// Accessory app: no dock icon, but the glow overlay can create windows.
NSApplication.shared.setActivationPolicy(.accessory)

let workMode = WorkModeController(
    database: database, classifier: (try? RulesClassifier(database: database)) ?? RulesClassifier()
)
engine.onCapture = { bundle, url, excluded in
    workMode.observe(appBundle: bundle, url: url, excluded: excluded)
}

log("shifud \(Shifu.version) starting — home: \(ShifuPaths.home.path)")
daemon.start()
workMode.startWatching()

// Keep references alive for the process lifetime and run forever.
withExtendedLifetime((daemon, workMode)) {
    RunLoop.main.run()
}

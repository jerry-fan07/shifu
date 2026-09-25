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

// The bundled LaunchAgent passes --log-file because an SMAppService plist is
// baked at build time and cannot name the user's home in StandardOutPath the
// way install-daemon.sh's template does. Opt-in by flag so a terminal run
// still prints, and the perf harness still reads stdout.
if arguments.contains("--log-file") {
    try FileManager.default.createDirectory(
        at: ShifuPaths.logs, withIntermediateDirectories: true)
    freopen(ShifuPaths.logs.appendingPathComponent("shifud.log").path, "a", stdout)
    freopen(ShifuPaths.logs.appendingPathComponent("shifud.err.log").path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
}
// The daemon watches the control file's identity directly rather than going
// through `FocusModeFile`, so it adopts the pre-rename name here — before
// `startWatching` below takes the token it will compare everything against.
FocusModeFile.adoptLegacyName()
let (database, rotated) = try ShifuDatabase.openRotatingOnCorruption(at: ShifuPaths.database)
if let rotated {
    log("WARNING: database was corrupt — rotated aside to \(rotated.lastPathComponent), starting fresh")
}
let recorder = ObservationRecorder(database: database)
let exclusions = try Exclusions(database: database)
let engine = CaptureEngine(recorder: recorder, exclusions: exclusions)

// Rewind (design.md §3.6) — the one part of Shifu that writes pixels, and off
// until the user switches it on. Constructed unconditionally because the
// recorder is what *reads* the switch; nothing happens until it says "on".
let rewindStore = RewindStore(database: database)
let rewindRecorder = RewindRecorder(
    store: rewindStore, database: database, exclusions: exclusions)
let daemon = Daemon(engine: engine, database: database, rewind: rewindRecorder)
let rewindShot = RewindShot()
let rewindRequests = RewindRequestWatcher(
    store: rewindStore, database: database, recorder: rewindRecorder,
    shot: { region in
        // A snip is worth full quality — the user asked for this frame, not a
        // scrubbable one. Capped where the OCR rung caps, for the same reason.
        try await rewindShot.capture(
            width: OCRCapture.maxCaptureWidth, excludedBundles: exclusions.bundleIDs,
            region: region)
    })

// Accessory app: no dock icon, but the glow overlay can create windows.
NSApplication.shared.setActivationPolicy(.accessory)

let focusMode = FocusModeController(
    database: database, classifier: (try? RulesClassifier(database: database)) ?? RulesClassifier()
)
engine.onCapture = { bundle, url, excluded in
    focusMode.observe(appBundle: bundle, url: url, excluded: excluded)
}

log("shifud \(Shifu.version) starting — home: \(ShifuPaths.home.path)")
daemon.start()
focusMode.startWatching()
rewindRequests.startWatching()
log(rewindRecorder.isRecording
    ? "rewind recording is on — frames in \(ShifuPaths.rewind.path)"
    : "rewind recording is off — no pixels are written")

// Keep references alive for the process lifetime and run forever.
withExtendedLifetime((daemon, focusMode, rewindRequests)) {
    RunLoop.main.run()
}

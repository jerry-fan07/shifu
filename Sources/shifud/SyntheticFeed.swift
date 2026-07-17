import Foundation
import ShifuCore

/// Perf-harness mode: pump synthetic triggers through the real write path
/// (redaction → simhash → SQLite) and report throughput + peak RSS.
/// Run as `shifud --synthetic-feed <count>` with SHIFU_HOME pointing at a
/// scratch directory.
enum SyntheticFeed {
    static func run(count: Int) throws {
        try ShifuPaths.ensureHomeExists()
        let database = try ShifuDatabase(at: ShifuPaths.database)
        let recorder = ObservationRecorder(database: database)

        let apps = [
            ("com.apple.dt.Xcode", "shifu — CaptureEngine.swift"),
            ("com.apple.Safari", "ScreenCaptureKit | Apple Developer"),
            ("com.googlecode.iterm2", "zsh — ~/code/shifu"),
            ("com.tinyspeck.slackmacgap", "#eng-infra — Slack"),
            ("com.spotify.client", "Spotify"),
        ]

        let start = Date()
        var inserted = 0
        var refreshed = 0
        for i in 0..<count {
            let (bundle, title) = apps[i % apps.count]
            // Every third trigger repeats the previous screen (dedupe path);
            // others get fresh content of realistic size (~2 KB).
            let page = (i % 3 == 0) ? i - 1 : i
            let text = Self.syntheticText(seed: page / apps.count, bundle: bundle)
            let outcome = try recorder.record(.init(
                timestamp: Int64(1_700_000_000_000) + Int64(i) * 30_000,
                appBundle: bundle, windowTitle: title,
                captureKind: .ax, text: text
            ))
            if case .inserted = outcome { inserted += 1 } else { refreshed += 1 }
        }
        let elapsed = Date().timeIntervalSince(start)

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let peakRSSMB = Double(usage.ru_maxrss) / 1_048_576  // ru_maxrss is bytes on macOS

        print("synthetic-feed: \(count) triggers in \(String(format: "%.2f", elapsed))s "
            + "(\(String(format: "%.0f", Double(count) / max(elapsed, 0.001)))/s), "
            + "\(inserted) inserted, \(refreshed) deduped, "
            + "peak RSS \(String(format: "%.1f", peakRSSMB)) MB")
    }

    private static func syntheticText(seed: Int, bundle: String) -> String {
        let words = ["capture", "ladder", "swift", "actor", "window", "focus", "event",
                     "screen", "text", "observer", "debounce", "hash", "session", "idle"]
        var pieces: [String] = ["document \(seed) in \(bundle)"]
        var state = UInt64(seed &* 2_654_435_761 &+ 1)
        for _ in 0..<300 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pieces.append(words[Int(state >> 33) % words.count])
        }
        return pieces.joined(separator: " ")
    }
}

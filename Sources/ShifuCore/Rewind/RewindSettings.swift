import Foundation

/// Everything Rewind is currently configured to do, read in one place
/// (design.md §3.6).
///
/// Read as a set rather than dial by dial because the recorder, the trimmer and
/// the player all have to agree about the same window: "how far back" bounds
/// what the daemon keeps, what the rail draws, and what a save can reach, and
/// three separate `Settings.value` calls is three chances for one of them to
/// read a stale or differently-clamped number.
public struct RewindSettings: Sendable, Equatable {
    /// The master switch. **False by default** — see `SettingsCatalog`.
    public var recording: Bool
    /// How far back the rolling buffer reaches.
    public var bufferMinutes: Int
    /// The cadence the buffer's *tail* settles to, and the bucket decimation
    /// thins to. Window and app changes take a frame immediately.
    public var frameSeconds: Int
    /// How far back the high-fidelity head reaches. Zero disables it, and the
    /// whole buffer runs at `frameSeconds` — the in-budget shape.
    public var hotMinutes: Int
    /// The head's frame rate. **This is the dial that breaks the §3.4 CPU
    /// budget** (design.md §3.6): the capture path is one display grab and one
    /// JPEG encode per frame, ~5.6 ms of daemon CPU, so 8 fps is ~4.5% of a
    /// core against a 0.5% target. Taken deliberately, and reversible by
    /// setting `hotMinutes` to 0.
    public var hotFPS: Int
    /// Capture width in pixels; height follows the display's aspect.
    public var frameWidth: Int
    /// The buffer's hard bound on disk.
    public var ceilingMB: Int
    /// How long a *saved* rewind lives before the analyzer reaps it.
    public var retentionDays: Int

    public init(
        recording: Bool = false, bufferMinutes: Int = 30, frameSeconds: Int = 5,
        hotMinutes: Int = 5, hotFPS: Int = 8,
        frameWidth: Int = 960, ceilingMB: Int = 512, retentionDays: Int = 14
    ) {
        self.recording = recording
        self.bufferMinutes = bufferMinutes
        self.frameSeconds = frameSeconds
        self.hotMinutes = hotMinutes
        self.hotFPS = hotFPS
        self.frameWidth = frameWidth
        self.ceilingMB = ceilingMB
        self.retentionDays = retentionDays
    }

    public var bufferMs: Int64 { Int64(bufferMinutes) * 60_000 }
    public var ceilingBytes: Int64 { Int64(ceilingMB) * 1_048_576 }
    /// How far back full-rate frames are kept. Clamped to the buffer itself: a
    /// head longer than the whole window is just a buffer with no tail, and the
    /// recorder should say so rather than compute a negative decimation cutoff.
    public var hotMs: Int64 { min(Int64(hotMinutes) * 60_000, bufferMs) }
    public var hasHotWindow: Bool { hotMinutes > 0 && hotFPS > 1 }

    /// The timer period the recorder actually runs at — the head's rate when
    /// there is a head, otherwise the tail cadence. One place, because the
    /// scheduler and the "did the dials change" check must not disagree about
    /// what the current period is.
    public var captureInterval: TimeInterval {
        hasHotWindow ? 1 / Double(hotFPS) : TimeInterval(frameSeconds)
    }

    /// The bucket decimation thins the tail to, in milliseconds.
    public var tailBucketMs: Int64 { Int64(frameSeconds) * 1_000 }

    public static func load(database: ShifuDatabase) -> RewindSettings {
        RewindSettings(
            recording: Settings.value(SettingsCatalog.rewindRecording, database: database) == "on",
            bufferMinutes: Settings.value(SettingsCatalog.rewindBufferMinutes, database: database),
            frameSeconds: Settings.value(SettingsCatalog.rewindFrameSeconds, database: database),
            hotMinutes: Settings.value(SettingsCatalog.rewindHotMinutes, database: database),
            hotFPS: Settings.value(SettingsCatalog.rewindHotFPS, database: database),
            frameWidth: Settings.value(SettingsCatalog.rewindWidth, database: database),
            ceilingMB: Settings.value(SettingsCatalog.rewindCeilingMB, database: database),
            retentionDays: Settings.value(SettingsCatalog.rewindRetentionDays, database: database))
    }

    /// How the page head describes the buffer, in the same words the daemon
    /// would use for it. One sentence, and every number in it is real.
    public var fidelityLine: String {
        let tail = frameSeconds == 1 ? "1 fps" : "one frame every \(frameSeconds)s"
        guard hasHotWindow else {
            return "\(bufferMinutes) min at \(tail), \(frameWidth) px wide"
        }
        // Both tiers, head first — the head is what you are looking at when you
        // open the page, and "30 min" alone would promise the head's fidelity
        // for the part of the buffer that has none of it. "out to" rather than
        // a second duration because the window is 30 minutes *total*: "5 min at
        // 8 fps, then 30 min at …" reads as 35.
        return "\(hotMinutes) min at \(hotFPS) fps, then \(tail) out to "
            + "\(bufferMinutes) min, \(frameWidth) px wide"
    }
}

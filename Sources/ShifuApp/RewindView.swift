import ShifuCore
import SwiftUI

/// The Rewind place (design.md §3.6), laid out as design 1a: the player owns
/// the top of the page, and the saved rewinds read like the Notes shelf under
/// it. "Fullscreen" in the transport hands the same player to a screen-covering
/// window (`RewindFullscreen`) — the page underneath keeps ticking, and escape
/// or the exit chip comes back to it.
///
/// It leads with the privacy banner rather than burying it in Settings, because
/// this is the one screen in Shifu where the honest headline is "this part
/// writes pixels to disk" — and the switch that stops it is in the banner, not
/// three clicks away.
struct RewindView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    /// Advances the rail's live end so "now" stays now while the page is open.
    @State private var tick = Date()
    @State private var fullscreen = false
    /// The transport: playing or not, how fast, and where in footage time the
    /// playhead sits. **The playhead is a moment, not a frame index** — the
    /// buffer grows and is trimmed under this page every five seconds, and an
    /// index would jump on every refresh (design.md §3.6).
    @StateObject private var clock = RewindClock()
    /// Whether the fullscreen player's bar is up. Held by the page rather than
    /// by the hosted view, so entering and leaving fullscreen are the two
    /// events that start and stop it.
    @StateObject private var chrome = FullscreenChrome()

    private static let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            head
            if store.rewindSettings.recording {
                RewindBanner()
                Band { player }
            }
            shelf
        }
        .background(
            RewindFullscreen(active: $fullscreen, onKey: key, onMotion: chrome.stir) {
                fullscreenPlayer
            })
        .onAppear { store.refreshRewind() }
        .onDisappear {
            clock.pause()
            chrome.end()
        }
        .onChange(of: fullscreen) { _, on in
            if on { chrome.begin() } else { chrome.end() }
        }
        .onReceive(Self.refresh) { moment in
            tick = moment
            store.refreshRewind()
        }
        .onReceive(clock.pulse) { elapsed in advance(by: elapsed) }
        // Switching recording off takes the player off the page under a
        // running transport; a timer left ticking into an empty buffer is a
        // clock nobody can see.
        .onChange(of: store.rewindSettings.recording) { _, on in
            if !on { clock.pause() }
        }
    }

    // MARK: - Head

    private var head: some View {
        PageHead("Rewind", subtitle: subtitle) {
            HStack(spacing: 6) {
                OutlineButton(title: "Rewind settings") {
                    router.go(to: .settings)
                    router.scroll(to: SettingsSection.rewind.rawValue)
                }
                if store.rewindSettings.recording {
                    SolidButton(title: "Save a rewind") { store.saveRewind() }
                }
            }
        }
    }

    /// One sentence, every number in it read from the running configuration —
    /// never a fixed description of a buffer somebody once designed.
    private var subtitle: String {
        guard store.rewindSettings.recording else {
            return "Off. Nothing on your screen is being kept — the capture ladder's "
                + "screenshots live in memory for one OCR call and are discarded. "
                + "Switch it on below to keep a rolling window you can scrub back through."
        }
        let buffered = store.rewindBuffer.frameCount
        guard buffered > 0 else {
            return "Recording. The buffer is still filling — the first frames arrive "
                + "within \(store.rewindSettings.frameSeconds) seconds."
        }
        return "The last \(store.rewindSettings.bufferMinutes) minutes are on disk — "
            + "\(store.rewindSettings.fidelityLine). Everything older has already been "
            + "overwritten."
    }

    // MARK: - Player

    private var player: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    RewindViewport(frame: currentFrame, caption: viewportCaption)
                        .frame(height: 322)
                    // Under the footage, where a player's controls live —
                    // never off to one side.
                    controls
                    frameLine
                }
                RewindTransport()
            }

            rail
                .padding(.top, 4)

            legend
        }
    }

    /// The transport, on the page and over the whole screen alike.
    private func controls(isFullscreen: Bool) -> some View {
        RewindControlBar(
            clock: clock,
            position: positionLabel, total: totalLabel,
            enabled: !store.rewindFrames.isEmpty,
            atEnd: clock.moment == nil,
            showsLive: true,
            isFullscreen: isFullscreen,
            onStep: step, onSkip: skip,
            onLive: { clock.seek(to: nil) },
            onFullscreen: { fullscreen = !isFullscreen })
    }

    private var controls: some View { controls(isFullscreen: false) }

    /// The same footage over the whole screen: the viewport edge to edge, and
    /// the frame line, the rail and a one-row transport floating over its foot.
    /// Built from the page's own state, so scrubbing out there and in here are
    /// the same scrub.
    private var fullscreenPlayer: some View {
        RewindFullscreenPlayer(
            frame: currentFrame, caption: viewportCaption, chrome: chrome,
            onExit: { fullscreen = false },
            bar: {
                fullscreenBar
            })
    }

    @ViewBuilder private var fullscreenBar: some View {
        frameLine
        rail
        controls(isFullscreen: true)
        legend
    }

    private var rail: some View {
        RewindRail(
            bands: bands, marks: marks, taskBands: taskBands, ticks: ticks,
            fidelity: store.rewindSettings.fidelityLine,
            playhead: playheadFraction, onScrub: scrub)
    }

    private var legend: some View {
        RewindLegend(
            entries: RewindTimeline.legend(bands: bands, span: span),
            markCount: marks.count,
            names: appNames)
    }

    /// What is under the playhead, in words: when, and what was on screen.
    private var frameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Figure(clock(currentFrame?.capturedAt), size: 12.5, weight: .medium)
            Text(sourceLine)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let frame = currentFrame {
                Figure(ago(frame.capturedAt), size: 11, color: Instrument.faint)
            }
        }
    }

    // MARK: - Shelf

    @ViewBuilder private var shelf: some View {
        if store.rewindSettings.recording || !store.savedRewinds.isEmpty {
            RewindShelf(rewinds: store.savedRewinds) { router.open(.rewind($0)) }
        } else {
            PageBody { RewindOffSlate() }
        }
    }

    // MARK: - Derived

    private var span: RewindTimeline.Span {
        RewindTimeline.span(
            now: Int64(tick.timeIntervalSince1970 * 1_000), settings: store.rewindSettings)
    }

    private var bands: [RewindTimeline.Band] {
        RewindTimeline.bands(frames: store.rewindFrames, span: span)
    }

    private var marks: [RewindTimeline.Mark] {
        RewindTimeline.marks(saved: store.savedRewinds, span: span)
    }

    /// The ledger's blocks over this span, as a strip. Usually empty at the
    /// live end — the analyzer runs hourly, so the minutes you are scrubbing
    /// have not been sessionized yet, and drawing nothing is the honest answer.
    private var taskBands: [RewindTimeline.Band] {
        let blocks = store.blocks(from: span.start, to: span.end)
        // `frameIndex` doubles as the band's identity, so each block needs its
        // own — bands that all claim 0 collapse under `ForEach`.
        return blocks.enumerated().compactMap { position, block in
            guard let name = block.taskName else { return nil }
            let start = span.fraction(of: block.startedAt)
            let end = span.fraction(of: block.endedAt)
            guard end > start else { return nil }
            return RewindTimeline.Band(
                start: start, end: end, label: name, excluded: false, frameIndex: position)
        }
    }

    private var ticks: [(at: Double, label: String)] { RewindTimeline.ticks(span: span) }

    /// Bundle → the name a person would use for it, so the legend says
    /// "Xcode" rather than "com.apple.dt.Xcode" wherever macOS still knows.
    private var appNames: [String: String] {
        var names: [String: String] = [:]
        for bundle in Set(store.rewindFrames.compactMap(\.appBundle)) {
            names[bundle] = AppNames.display(bundle)
        }
        return names
    }

    /// What the viewport shows, resolved from the clock's moment on every pass
    /// rather than remembered as an index. A nil moment follows the head of the
    /// buffer — the live end.
    private var index: Int {
        let frames = store.rewindFrames
        guard !frames.isEmpty else { return 0 }
        guard let moment = clock.moment,
            let nearest = RewindTimeline.nearestFrame(to: Int64(moment), in: frames)
        else { return frames.count - 1 }
        return nearest
    }

    /// The footage the transport can reach: oldest frame to newest.
    private var footage: (start: Int64, end: Int64) {
        let frames = store.rewindFrames
        guard let first = frames.first, let last = frames.last else { return (0, 0) }
        return (first.capturedAt, last.capturedAt)
    }

    /// How far into the buffer the playhead is — position in the footage, the
    /// way a player's readout works, matched to the rail beneath it. The wall
    /// clock this actually *was* is on the frame line right under the bar, so
    /// putting it here too would be the same fact printed twice.
    private var positionLabel: String {
        guard let frame = currentFrame else { return "0:00" }
        return RewindPlayback.duration(ms: max(0, frame.capturedAt - footage.start))
    }

    /// How much footage there is, which is not the configured window: a buffer
    /// that has been filling for a minute holds a minute.
    private var totalLabel: String {
        let span = footage
        guard span.end > span.start else { return "0:00" }
        return RewindPlayback.duration(ms: span.end - span.start)
    }

    private var currentFrame: RewindFrame? {
        store.rewindFrames.isEmpty ? nil : store.rewindFrames[index]
    }

    private var playheadFraction: Double {
        guard let frame = currentFrame else { return 1 }
        return span.fraction(of: frame.capturedAt)
    }

    private var viewportCaption: String? {
        guard let frame = currentFrame, !frame.excluded else { return nil }
        return "\(frame.width) × \(frame.height)"
    }

    private var sourceLine: String {
        guard let frame = currentFrame else { return "Nothing buffered yet" }
        if frame.excluded { return "Excluded — nothing was captured here" }
        let app = frame.appBundle.map(AppNames.display) ?? "Unknown"
        guard let title = frame.windowTitle, !title.isEmpty else { return app }
        return "\(app) — \(title)"
    }

    // MARK: - Playing and scrubbing

    /// One tick of the transport. The clock walks through footage time, so 1×
    /// is one second of screen per second of wall clock on both sides of the
    /// hot/tail boundary — see `RewindPlayback`.
    private func advance(by elapsed: TimeInterval) {
        guard clock.isPlaying else { return }
        guard !store.rewindFrames.isEmpty else { return clock.pause() }
        let span = footage
        apply(RewindPlayback.advance(
            from: clock.moment, rate: clock.rate, elapsed: elapsed,
            start: span.start, end: span.end))
    }

    private func skip(_ seconds: Double) {
        guard !store.rewindFrames.isEmpty else { return }
        let span = footage
        apply(RewindPlayback.skip(
            from: clock.moment, seconds: seconds, start: span.start, end: span.end))
    }

    /// Running into the live end stops the transport and parks the playhead
    /// there — the buffer has caught up with the present, and there is nothing
    /// past it to play.
    private func apply(_ step: RewindPlayback.Step) {
        guard !step.reachedEnd else {
            clock.seek(to: nil)
            clock.pause()
            return
        }
        clock.seek(to: step.moment)
    }

    private func step(_ delta: Int) {
        let frames = store.rewindFrames
        guard !frames.isEmpty else { return }
        let target = min(frames.count - 1, max(0, index + delta))
        // Stepping onto the last frame *is* live: parking the playhead there
        // would freeze the viewport a frame behind as new ones arrive.
        clock.seek(to: target >= frames.count - 1 ? nil : Double(frames[target].capturedAt))
    }

    private func scrub(_ fraction: Double) {
        let frames = store.rewindFrames
        guard !frames.isEmpty else { return }
        let moment = span.start + Int64(fraction * Double(span.lengthMs))
        // Landing on the last frame is landing on "live" — see `step`.
        guard moment < frames[frames.count - 1].capturedAt else { return clock.seek(to: nil) }
        clock.seek(to: Double(max(moment, frames[0].capturedAt)))
    }

    /// The keys the fullscreen window answers to, so the player behaves like
    /// one out there: space plays, the arrows step. Escape is the window's own.
    private func key(_ code: UInt16) -> Bool {
        // A key is someone being there as much as a mouse move is: stepping
        // frames blind, with the readout hidden, is not the intent.
        defer { chrome.stir() }
        switch code {
        case FullscreenPlayerWindow.spaceKey: clock.toggle()
        case FullscreenPlayerWindow.leftKey: step(-1)
        case FullscreenPlayerWindow.rightKey: step(1)
        default: return false
        }
        return true
    }

    private func clock(_ ms: Int64?) -> String {
        guard let ms else { return "—" }
        return Date(timeIntervalSince1970: Double(ms) / 1_000)
            .formatted(.dateTime.hour().minute().second())
    }

    private func ago(_ ms: Int64) -> String {
        let seconds = max(0, Int(tick.timeIntervalSince1970) - Int(ms / 1_000))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m \(seconds % 60)s ago"
    }
}

/// The banner (design.md §3.6): what Rewind does that nothing else in Shifu
/// does, and the switch that stops it, on the same line as the claim.
struct RewindBanner: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                SeriesSwatch(color: Instrument.quiet, hatched: true)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rewind is the one part of Shifu that writes pixels to disk.")
                        .font(Instrument.sans(12.5, .medium))
                        .foregroundStyle(Instrument.beacon)
                    // Every clause here is a guarantee stated as an invariant
                    // somewhere else. Deliberately *not* "redacted" — the
                    // redactor reads text, and claiming it reads pixels would
                    // be the one false sentence on the page.
                    Text("Frames live in ~/Shifu/rewind/, are excluded before capture the "
                        + "way text is, and are deleted on the schedule in Settings. The "
                        + "daemon still cannot speak — nothing here can leave the Mac.")
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .frame(maxWidth: 720, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Recording")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.muted)
                    ToggleSwitch(isOn: store.rewindSettings.recording) {
                        store.setRewindRecording(!store.rewindSettings.recording)
                        RewindFrameCache.clear()
                    }
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, Instrument.gutter)
            .padding(.vertical, 12)
            Rule(weight: .section)
        }
    }
}

/// What the page says while Rewind has never been switched on. The switch is
/// the whole screen, because there is nothing else to look at yet.
struct RewindOffSlate: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BlankSlate("Rewind keeps the last few minutes of your screen as "
                + "low-resolution frames, so you can go back and see what you were "
                + "actually looking at. It is the only feature in Shifu that stores "
                + "pixels, which is why it starts off.")
            VStack(alignment: .leading, spacing: 6) {
                promise("Frames are written to ~/Shifu/rewind and nowhere else.")
                promise("Excluded apps and private windows are skipped before the "
                    + "screenshot, not filtered out of one.")
                promise("Pausing capture tears the recorder down like every other observer.")
                promise("Nothing here is ever sent anywhere — the daemon has no network code.")
            }
            SolidButton(title: "Turn Rewind on") { store.setRewindRecording(true) }
                .padding(.top, 4)
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(Instrument.mono(12.5))
                .foregroundStyle(Instrument.ghost)
            Text(text)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

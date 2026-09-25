import ShifuCore
import SwiftUI

/// One saved rewind, opened (design.md §3.6): its own player over its own
/// frames, why it was saved, when it goes, and the ledger blocks it covers.
/// "Fullscreen" beside the transport hands the clip to a screen-covering
/// window (`RewindFullscreen`), the way the live player's transport does.
///
/// A pushed route rather than a sheet, like a task or a theme — so the source
/// list becomes this rewind's own contents and the window never stops saying
/// where you are.
struct RewindDetailPage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let rewindID: Int64

    @State private var frames: [RewindFrame] = []
    @State private var fullscreen = false
    /// The same transport the live player uses, over a clip that doesn't move.
    /// A moment rather than an index here too, so 1× means one second of screen
    /// per second across a clip whose frames are as unevenly spaced as the
    /// buffer they were cut from (design.md §3.6).
    @StateObject private var clock = RewindClock()
    /// See `RewindView` — the fullscreen bar hides itself here too.
    @StateObject private var chrome = FullscreenChrome()

    var body: some View {
        Group {
            if let rewind = store.savedRewind(rewindID) {
                content(rewind)
            } else {
                PageBody { BlankSlate("This rewind has been deleted.") }
            }
        }
        .onAppear { frames = store.frames(ofRewind: rewindID) }
        .onDisappear {
            clock.pause()
            chrome.end()
        }
        .onChange(of: fullscreen) { _, on in
            if on { chrome.begin() } else { chrome.end() }
        }
        .onReceive(clock.pulse) { elapsed in advance(by: elapsed) }
    }

    private func content(_ rewind: SavedRewind) -> some View {
        VStack(spacing: 0) {
            head(rewind)
            Band { player(rewind) }
            blocks(rewind)
        }
        .background(
            RewindFullscreen(active: $fullscreen, onKey: key, onMotion: chrome.stir) {
                fullscreenPlayer(rewind)
            })
    }

    // MARK: - Head

    private func head(_ rewind: SavedRewind) -> some View {
        PageHead(rewind.title, subtitle: subtitle(rewind)) {
            HStack(spacing: 6) {
                OutlineButton(title: "Delete") {
                    store.deleteRewind(rewindID)
                    router.close()
                }
                OutlineButton(title: "Reveal in Finder") { store.revealInFinder(rewind) }
                if !rewind.keptForever {
                    SolidButton(title: "Keep forever") { store.keepForever(rewindID: rewindID) }
                }
            }
        }
    }

    private func subtitle(_ rewind: SavedRewind) -> String {
        var parts: [String] = []
        let start = Date(timeIntervalSince1970: Double(rewind.startedAt) / 1_000)
        let end = Date(timeIntervalSince1970: Double(rewind.endedAt) / 1_000)
        if rewind.kind == .snip {
            parts.append(start.formatted(.dateTime.hour().minute().second()))
        } else {
            parts.append(start.formatted(.dateTime.hour().minute().second())
                + " – " + end.formatted(.dateTime.hour().minute().second()))
        }
        parts.append(frameCountLine)
        parts.append(RewindTransport.megabytes(rewind.bytes))
        if let frame = frames.first(where: { $0.width > 0 }) {
            parts.append("\(frame.width) × \(frame.height)")
        }
        return parts.joined(separator: " · ")
    }

    /// The head and the transport have to count the same things or the page
    /// reads as two disagreeing sources. The transport scrubs every *moment* —
    /// excluded gaps included, because scrubbing into one and seeing why is the
    /// point — so the head counts moments too, and names the gap separately
    /// rather than quietly subtracting it.
    private var frameCountLine: String {
        let total = frames.count
        let excluded = frames.count { $0.excluded }
        let noun = total == 1 ? "frame" : "frames"
        guard excluded > 0 else { return "\(total) \(noun)" }
        return "\(total) \(noun), \(excluded) excluded"
    }

    /// What the band over the strips says this clip is.
    private var fidelity: String {
        guard let frame = frames.first(where: { $0.width > 0 }) else { return "no frames kept" }
        return "\(frames.count) frames at \(frame.width) px"
    }

    // MARK: - Player

    private func player(_ rewind: SavedRewind) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                RewindViewport(frame: current, caption: nil)
                    .frame(height: 300)
                controls(rewind, isFullscreen: false)
                if frames.count > 1 {
                    rail(rewind)
                }
            }
            sidebar(rewind)
        }
    }

    /// The same clip over the whole screen, scrubbed by the same state.
    private func fullscreenPlayer(_ rewind: SavedRewind) -> some View {
        RewindFullscreenPlayer(
            frame: current, caption: nil, chrome: chrome,
            onExit: { fullscreen = false },
            bar: {
                if frames.count > 1 {
                    rail(rewind)
                }
                controls(rewind, isFullscreen: true)
            })
    }

    private func rail(_ rewind: SavedRewind) -> some View {
        RewindRail(
            bands: RewindTimeline.bands(frames: frames, span: span(rewind)),
            marks: [], taskBands: [],
            ticks: elapsedTicks(rewind),
            fidelity: fidelity,
            playhead: playhead(rewind),
            onScrub: { scrub($0, rewind) })
    }

    /// The transport, on the page and over the whole screen alike. A clip has
    /// no live end, so no live chip — the last frame is simply the last frame.
    private func controls(_ rewind: SavedRewind, isFullscreen: Bool) -> some View {
        RewindControlBar(
            clock: clock,
            position: RewindPlayback.duration(ms: elapsedMs),
            total: RewindPlayback.duration(ms: max(0, footage.end - footage.start)),
            enabled: frames.count > 1,
            atEnd: index >= frames.count - 1,
            showsLive: false,
            isFullscreen: isFullscreen,
            onStep: step, onSkip: skip,
            onLive: {},
            onFullscreen: { fullscreen = !isFullscreen })
    }

    /// Why it was saved, and when it goes. The two things a saved rewind is
    /// asked about later, in that order.
    private func sidebar(_ rewind: SavedRewind) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("Why it was saved", tracking: 1)
            Text(rewind.note ?? "Saved by hand.")
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.body)
                .fixedSize(horizontal: false, vertical: true)

            if let path = rewind.notePath {
                Rule(weight: .row).padding(.vertical, 3)
                Eyebrow("Filed as", tracking: 1)
                Text(path)
                    .font(Instrument.mono(11))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rule(weight: .row).padding(.vertical, 3)
            Eyebrow("Retention", tracking: 1)
            retention(rewind)
        }
        .frame(width: 290, alignment: .leading)
    }

    @ViewBuilder private func retention(_ rewind: SavedRewind) -> some View {
        if let expires = rewind.expiresAt {
            let expiry = Date(timeIntervalSince1970: Double(expires) / 1_000)
            HStack(alignment: .firstTextBaseline) {
                Text("Deleted on")
                    .font(Instrument.sans(12))
                    .foregroundStyle(Instrument.secondary)
                Spacer(minLength: 6)
                Figure(expiry.formatted(.dateTime.day().month().year()), size: 12)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Instrument.well)
                    Capsule()
                        .fill(Instrument.accent)
                        .frame(width: proxy.size.width * elapsedShare(rewind))
                }
            }
            .frame(height: 6)
            Text("\"Keep forever\" takes it out of the schedule; nothing else does.")
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Kept indefinitely. It is out of the retention schedule and will not "
                + "be deleted with the others.")
                .font(Instrument.sans(12))
                .foregroundStyle(Instrument.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Blocks

    private func blocks(_ rewind: SavedRewind) -> some View {
        RewindBlocksTable(blocks: store.blocks(from: rewind.startedAt, to: rewind.endedAt))
    }

    // MARK: - Derived

    private var current: RewindFrame? {
        frames.isEmpty ? nil : frames[min(index, frames.count - 1)]
    }

    /// Resolved from the clock every pass, never remembered — the same rule the
    /// live player follows, for the same reason: one playhead, one shape.
    private var index: Int {
        guard !frames.isEmpty else { return 0 }
        guard let moment = clock.moment,
            let nearest = RewindTimeline.nearestFrame(to: Int64(moment), in: frames)
        else { return frames.count - 1 }
        return nearest
    }

    private var footage: (start: Int64, end: Int64) {
        guard let first = frames.first, let last = frames.last else { return (0, 0) }
        return (first.capturedAt, last.capturedAt)
    }

    /// How far into the clip the playhead is. A saved rewind is read as a
    /// five-minute thing, so its readout counts from its own first frame.
    private var elapsedMs: Int64 {
        guard let frame = current else { return 0 }
        return max(0, frame.capturedAt - footage.start)
    }

    private func span(_ rewind: SavedRewind) -> RewindTimeline.Span {
        RewindTimeline.Span(start: rewind.startedAt, end: max(rewind.endedAt, rewind.startedAt + 1))
    }

    private func playhead(_ rewind: SavedRewind) -> Double {
        guard let frame = current else { return 0 }
        return span(rewind).fraction(of: frame.capturedAt)
    }

    private func scrub(_ fraction: Double, _ rewind: SavedRewind) {
        guard !frames.isEmpty else { return }
        let moment = rewind.startedAt + Int64(fraction * Double(span(rewind).lengthMs))
        clock.seek(to: Double(min(max(moment, footage.start), footage.end)))
    }

    // MARK: - Playing

    private func advance(by elapsed: TimeInterval) {
        guard clock.isPlaying else { return }
        guard frames.count > 1 else { return clock.pause() }
        apply(RewindPlayback.advance(
            from: clock.moment, rate: clock.rate, elapsed: elapsed,
            start: footage.start, end: footage.end))
    }

    private func skip(_ seconds: Double) {
        guard frames.count > 1 else { return }
        apply(RewindPlayback.skip(
            from: clock.moment, seconds: seconds, start: footage.start, end: footage.end))
    }

    /// A clip that has played out stops on its last frame rather than looping —
    /// pressing play again starts it over, which is where the nil moment
    /// `RewindPlayback.advance` reads as "from the beginning" comes from.
    private func apply(_ step: RewindPlayback.Step) {
        guard !step.reachedEnd else {
            clock.seek(to: nil)
            clock.pause()
            return
        }
        clock.seek(to: step.moment)
    }

    private func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        let target = min(frames.count - 1, max(0, index + delta))
        clock.seek(to: target >= frames.count - 1 ? nil : Double(frames[target].capturedAt))
    }

    private func key(_ code: UInt16) -> Bool {
        defer { chrome.stir() }
        switch code {
        case FullscreenPlayerWindow.spaceKey: clock.toggle()
        case FullscreenPlayerWindow.leftKey: step(-1)
        case FullscreenPlayerWindow.rightKey: step(1)
        default: return false
        }
        return true
    }

    /// Elapsed time into the clip rather than wall clock — a saved rewind is
    /// read as a five-minute thing, not as a slice of the afternoon.
    private func elapsedTicks(_ rewind: SavedRewind) -> [(at: Double, label: String)] {
        let length = span(rewind).lengthMs
        return (0..<5).map { step in
            let place = Double(step) / 4
            let seconds = Int(place * Double(length) / 1_000)
            return (at: place, label: String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }

    /// How far through its retention window this rewind is.
    private func elapsedShare(_ rewind: SavedRewind) -> Double {
        guard let expires = rewind.expiresAt, expires > rewind.createdAt else { return 0 }
        let total = Double(expires - rewind.createdAt)
        let gone = Date().timeIntervalSince1970 * 1_000 - Double(rewind.createdAt)
        return min(1, max(0, gone / total))
    }
}

/// The ledger's own blocks over a rewind's span. **Not the rewind's** —
/// deleting the footage leaves them exactly where they are, which is the
/// sentence under the table.
struct RewindBlocksTable: View {
    let blocks: [LedgerBuilder.LabeledActivity]

    var body: some View {
        PageBody {
            ColumnHead(spacing: 12) {
                Text("Time").frame(width: 66, alignment: .leading)
                Text("Block").frame(maxWidth: .infinity, alignment: .leading)
                Text("For").frame(width: 88, alignment: .trailing)
                Text("Category").frame(width: 92, alignment: .trailing)
            }
            if blocks.isEmpty {
                BlankSlate("The analyzer has not reached these minutes yet. The blocks "
                    + "appear here on its next run — the footage does not wait for them.")
            } else {
                ForEach(blocks, id: \.id) { block in
                    row(block)
                    Rule(weight: .row)
                }
                QuietLine {
                    Text("These blocks are the ledger's, not the rewind's — deleting the "
                        + "footage leaves them where they are.")
                }
            }
        }
    }

    private func row(_ block: LedgerBuilder.LabeledActivity) -> some View {
        HStack(spacing: 12) {
            Figure(
                Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
                    .formatted(.dateTime.hour().minute()),
                size: 12.5, color: Instrument.faint)
                .frame(width: 66, alignment: .leading)
            Text(title(block))
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(block.durationMs), size: 12.5, color: Instrument.muted)
                .frame(width: 88, alignment: .trailing)
            Text(block.category)
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.muted)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    /// `source` is already the domain or the app-bundle tail — what the Time
    /// page names a block. The task is added when the ledger has one, because
    /// "Xcode" alone doesn't say which of four things you were doing in it.
    private func title(_ block: LedgerBuilder.LabeledActivity) -> String {
        guard let task = block.taskName, !task.isEmpty else { return block.source }
        return "\(block.source) — \(task)"
    }
}

import AppKit
import ShifuCore
import SwiftUI

// The player half of the Rewind place (design.md §3.6): the viewport, the
// transport beside it, and the frame cache that keeps scrubbing from decoding
// the same JPEG on every body pass.

/// One frame, drawn. Falls back to the hatched "nothing here" ground for an
/// excluded moment and for a frame whose file has already been trimmed out from
/// under the row — both are honest states rather than errors.
struct RewindViewport: View {
    let frame: RewindFrame?
    var caption: String?
    /// Edge to edge for the fullscreen player: no rounded chrome, and the
    /// caption in the top corner, because the bottom belongs to the control
    /// bar floating over the footage's foot.
    var bare = false

    var body: some View {
        ZStack {
            Hatch()
                .background(Instrument.quiet.opacity(0.35))
            if let image = frame.flatMap(RewindFrameCache.image(for:)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(placeholder)
                    .font(Instrument.mono(11))
                    .tracking(0.6)
                    .foregroundStyle(Instrument.faint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Instrument.ground, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Instrument.hairline, lineWidth: 1)
                    }
            }
        }
        .overlay(alignment: bare ? .topLeading : .bottomLeading) {
            if let caption {
                Text(caption)
                    .font(Instrument.mono(10, .medium))
                    .foregroundStyle(Instrument.solidInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Instrument.solidFill.opacity(0.82),
                        in: RoundedRectangle(cornerRadius: 3))
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: bare ? 0 : 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Instrument.edge, lineWidth: bare ? 0 : 1)
        }
    }

    private var placeholder: String {
        guard let frame else { return "NOTHING BUFFERED YET" }
        if frame.excluded { return "EXCLUDED — NEVER CAPTURED" }
        return "FRAME NO LONGER ON DISK"
    }
}

/// Decoded frames, kept briefly.
///
/// The scrubber walks one frame at a time and SwiftUI re-runs a body for every
/// step, so decoding on each pass would re-read the same JPEG dozens of times a
/// second. Small and bounded on purpose: this is a *scrub* cache, not a
/// filmstrip — nothing here outlives looking at it, and holding a whole
/// half-hour buffer decoded would be ~360 bitmaps of resident memory for a
/// window showing one.
@MainActor
enum RewindFrameCache {
    private static let capacity = 12
    private static var images: [String: NSImage] = [:]
    private static var order: [String] = []

    static func image(for frame: RewindFrame) -> NSImage? {
        guard let url = frame.url() else { return nil }
        let key = url.path
        if let cached = images[key] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[key] = image
        order.append(key)
        while order.count > capacity {
            images.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    /// Dropped when the buffer is purged — the paths are about to be reused by
    /// frames with different contents.
    static func clear() {
        images.removeAll()
        order.removeAll()
    }
}

/// The column beside the viewport: what the buffer costs, and the things you
/// can do with it. **Not the transport** — that moved under the footage, where
/// a player's controls belong (`RewindControlBar`).
struct RewindTransport: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("Buffer", tracking: 1)
            meter
            Rule(weight: .row).padding(.vertical, 2)
            actions
        }
        .frame(width: 212, alignment: .leading)
    }

    /// What the buffer costs, against its ceiling. The sentence under it is the
    /// one thing a meter can't say: which end gets dropped.
    private var meter: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Buffer on disk", Self.megabytes(store.rewindBuffer.bytes))
            row("Ceiling", Self.megabytes(store.rewindSettings.ceilingBytes), muted: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Instrument.well)
                    Capsule()
                        .fill(Instrument.accent)
                        .frame(width: proxy.size.width * fill)
                }
            }
            .frame(height: 6)
            Text("Oldest frames are dropped as the ceiling is reached — the tail "
                + "thins before the head does.")
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            OutlineButton(title: "Save the last \(store.rewindSettings.bufferMinutes) min") {
                store.saveRewind()
            }
            OutlineButton(title: "Keep this frame") { store.snip() }
            Text("Both run in the daemon — the app never takes a screenshot.")
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fill: Double {
        let ceiling = Double(store.rewindSettings.ceilingBytes)
        guard ceiling > 0 else { return 0 }
        return min(1, Double(store.rewindBuffer.bytes) / ceiling)
    }

    private func row(_ label: String, _ value: String, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
            Spacer(minLength: 6)
            Figure(value, size: 11.5, color: muted ? Instrument.muted : Instrument.ink)
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1_024 { return String(format: "%.1f GB", megabytes / 1_024) }
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f MB", megabytes)
    }
}

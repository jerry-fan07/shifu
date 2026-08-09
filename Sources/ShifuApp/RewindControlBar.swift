import ShifuCore
import SwiftUI

// The transport a Rewind player wears (design.md §3.6) — one control bar, used
// by all four surfaces: the live player on the page, a saved rewind's page, and
// each of those over the whole screen. Built once here so the fullscreen bar
// can't drift into being a different, worse transport than the page's.
//
// The marks are drawn rather than typed. Everywhere else the instrument sets
// its glyphs in type, but "▷" is a *typographic* triangle — optically light,
// vertically off-centre, and sized by a font metric rather than by the button
// it sits in. A transport is the one place in the app that has to read as a
// familiar object at a glance, so its play triangle is a triangle.

/// The transport marks, as geometry.
struct PlayerGlyph: Shape {
    enum Kind {
        case play
        case pause
        case stepBack
        case stepForward
        case skipBack
        case skipForward
        case enterFullscreen
        case exitFullscreen
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .play:
            triangle(&path, in: rect, from: 0.16, to: 0.9, forward: true)
        case .pause:
            path.addRoundedRect(
                in: unit(rect, 0.22, 0.1, 0.19, 0.8), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(
                in: unit(rect, 0.59, 0.1, 0.19, 0.8), cornerSize: CGSize(width: 1, height: 1))
        case .stepForward:
            triangle(&path, in: rect, from: 0.1, to: 0.66, forward: true)
            path.addRect(unit(rect, 0.74, 0.14, 0.13, 0.72))
        case .stepBack:
            triangle(&path, in: rect, from: 0.9, to: 0.34, forward: false)
            path.addRect(unit(rect, 0.13, 0.14, 0.13, 0.72))
        case .skipForward:
            triangle(&path, in: rect, from: 0.04, to: 0.5, forward: true)
            triangle(&path, in: rect, from: 0.5, to: 0.96, forward: true)
        case .skipBack:
            triangle(&path, in: rect, from: 0.96, to: 0.5, forward: false)
            triangle(&path, in: rect, from: 0.5, to: 0.04, forward: false)
        case .enterFullscreen:
            // Four Ls hugging the corners: the box opening outwards.
            for at in [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.05),
                       CGPoint(x: 0.05, y: 0.95), CGPoint(x: 0.95, y: 0.95)] {
                bracket(&path, in: rect, at: at, opening: away(from: at))
            }
        case .exitFullscreen:
            // The same four Ls turned inside out — the box closing again.
            for at in [CGPoint(x: 0.42, y: 0.42), CGPoint(x: 0.58, y: 0.42),
                       CGPoint(x: 0.42, y: 0.58), CGPoint(x: 0.58, y: 0.58)] {
                bracket(&path, in: rect, at: at, opening: toward(edgeOf: at))
            }
        }
        return path
    }

    /// A play triangle spanning `from`…`to` horizontally, pointing at `to`.
    private func triangle(
        _ path: inout Path, in rect: CGRect, from: Double, to: Double, forward: Bool
    ) {
        let top = point(rect, from, 0.12)
        let bottom = point(rect, from, 0.88)
        let tip = point(rect, to, 0.5)
        path.move(to: forward ? top : bottom)
        path.addLine(to: tip)
        path.addLine(to: forward ? bottom : top)
        path.closeSubpath()
    }

    /// One corner bracket: two arms running from `at` in the ±1 directions
    /// `opening` gives, which is what makes the enter and exit marks the same
    /// four Ls pointed opposite ways.
    private func bracket(
        _ path: inout Path, in rect: CGRect, at: CGPoint, opening: CGPoint
    ) {
        let arm = 0.34
        let thickness = 0.12
        path.addRect(span(rect, at.x, at.y, opening.x * arm, opening.y * thickness))
        path.addRect(span(rect, at.x, at.y, opening.x * thickness, opening.y * arm))
    }

    /// Arms pointing in from a corner of the box — the enter mark.
    private func away(from at: CGPoint) -> CGPoint {
        CGPoint(x: at.x < 0.5 ? 1 : -1, y: at.y < 0.5 ? 1 : -1)
    }

    /// Arms pointing back out at the edges — the exit mark.
    private func toward(edgeOf at: CGPoint) -> CGPoint {
        CGPoint(x: at.x < 0.5 ? -1 : 1, y: at.y < 0.5 ? -1 : 1)
    }

    private func point(_ rect: CGRect, _ atX: Double, _ atY: Double) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * atX, y: rect.minY + rect.height * atY)
    }

    private func unit(
        _ rect: CGRect, _ atX: Double, _ atY: Double, _ wide: Double, _ tall: Double
    ) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * atX, y: rect.minY + rect.height * atY,
            width: rect.width * wide, height: rect.height * tall)
    }

    /// Like `unit`, but the extents may be negative — the bracket arms are
    /// written as "from this corner, that far in this direction".
    private func span(
        _ rect: CGRect, _ atX: Double, _ atY: Double, _ wide: Double, _ tall: Double
    ) -> CGRect {
        CGRect(
            x: rect.minX + rect.width * min(atX, atX + wide),
            y: rect.minY + rect.height * min(atY, atY + tall),
            width: rect.width * abs(wide), height: rect.height * abs(tall))
    }
}

/// One round transport button. `prominent` is the play/pause key — filled,
/// larger, and the only loud thing on the bar.
struct PlayerButton: View {
    let glyph: PlayerGlyph.Kind
    var prominent = false
    var enabled = true
    var help: String
    let action: () -> Void

    @State private var hovering = false

    private var diameter: CGFloat { prominent ? 32 : 25 }
    private var mark: CGFloat { prominent ? 13 : 11 }

    var body: some View {
        Button(action: action) {
            PlayerGlyph(kind: glyph)
                .fill(ink)
                .frame(width: mark, height: mark)
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        prominent ? Color.clear : Instrument.edge, lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .help(help)
        .accessibilityLabel(help)
    }

    private var ink: Color {
        guard enabled else { return Instrument.ghost }
        return prominent ? Instrument.solidInk : Instrument.railInk
    }

    private var fill: Color {
        if prominent { return enabled ? Instrument.solidFill : Instrument.well }
        return hovering ? Instrument.well : .clear
    }
}

/// The speed control: one pill that cycles. Not a dropdown — the same bar has
/// to work inside the borderless fullscreen window, where a panel-drawing menu
/// would attach to the wrong window, and cycling is what a player's speed
/// control does anyway.
struct PlayerRateButton: View {
    @ObservedObject var clock: RewindClock
    var enabled = true

    @State private var hovering = false

    var body: some View {
        Button { clock.cycleRate() } label: {
            Text(RewindPlayback.rateLabel(clock.rate))
                .font(Instrument.mono(11, .medium))
                .foregroundStyle(tinted ? Instrument.accentDeep : Instrument.railInk)
                .frame(minWidth: 30)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    tinted ? Instrument.selection : (hovering ? Instrument.well : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            tinted ? Instrument.accent : Instrument.edge, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .help("Playback speed — click to cycle "
            + RewindPlayback.rates.map(RewindPlayback.rateLabel).joined(separator: ", "))
        .accessibilityLabel("Playback speed")
    }

    /// Anything but 1× is a state the player is *in*, so it takes the tint the
    /// rest of the instrument gives a non-default setting.
    private var tinted: Bool { clock.rate != 1 }
}

/// The bar itself: the transport, where you are in the footage, the speed, the
/// live chip, and the door in and out of fullscreen.
struct RewindControlBar: View {
    @ObservedObject var clock: RewindClock
    /// Where the playhead is, as the surface wants to say it — a wall clock for
    /// the live buffer, elapsed time for a saved clip.
    let position: String
    /// How much footage there is, after the slash.
    let total: String
    /// There are frames to play. Everything is dead without them.
    var enabled = true
    /// The playhead is at the head of the footage.
    var atEnd = true
    /// This player is the live buffer, so the end of the footage is *now* and
    /// deserves saying so.
    var showsLive = false
    var isFullscreen = false
    let onStep: (Int) -> Void
    let onSkip: (Double) -> Void
    let onLive: () -> Void
    let onFullscreen: () -> Void

    private var skip: Double { RewindPlayback.skipSeconds }

    var body: some View {
        HStack(spacing: 7) {
            PlayerButton(
                glyph: .stepBack, enabled: enabled, help: "Previous frame  ·  ←"
            ) { onStep(-1) }
            PlayerButton(
                glyph: .skipBack, enabled: enabled, help: "Back \(Int(skip)) seconds"
            ) { onSkip(-skip) }
            PlayerButton(
                glyph: clock.isPlaying ? .pause : .play, prominent: true, enabled: enabled,
                help: clock.isPlaying ? "Pause  ·  space" : "Play  ·  space"
            ) { clock.toggle() }
            PlayerButton(
                glyph: .skipForward, enabled: enabled && !atEnd,
                help: "Forward \(Int(skip)) seconds"
            ) { onSkip(skip) }
            PlayerButton(
                glyph: .stepForward, enabled: enabled && !atEnd, help: "Next frame  ·  →"
            ) { onStep(1) }

            readout
                .padding(.leading, 4)

            Spacer(minLength: 8)

            PlayerRateButton(clock: clock, enabled: enabled)
            if showsLive { liveChip }
            PlayerButton(
                glyph: isFullscreen ? .exitFullscreen : .enterFullscreen,
                help: isFullscreen ? "Exit fullscreen  ·  esc" : "Fullscreen",
                action: onFullscreen)
        }
    }

    private var readout: some View {
        HStack(spacing: 4) {
            Figure(position, size: 12, weight: .medium)
            Text("/")
                .font(Instrument.mono(11))
                .foregroundStyle(Instrument.ghost)
            Figure(total, size: 12, color: Instrument.muted)
        }
        .monospacedDigit()
    }

    /// The live chip, saying two things at once: the dot is lit while the
    /// playhead follows the head of the buffer, and once it doesn't, the chip
    /// takes the tint the instrument gives anything you can press — being
    /// behind live is the state where this is a *button*, so that is the state
    /// it has to look like one in.
    private var liveChip: some View {
        Button(action: onLive) {
            HStack(spacing: 5) {
                Circle()
                    .fill(atEnd ? Instrument.live : Instrument.accent)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(Instrument.mono(10, .medium))
                    .tracking(0.8)
                    .foregroundStyle(atEnd ? Instrument.muted : Instrument.accentDeep)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                atEnd ? Color.clear : Instrument.selection,
                in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(atEnd ? Instrument.edge : Instrument.accent, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(atEnd)
        .help(atEnd ? "Following the live end of the buffer" : "Jump to now")
    }
}

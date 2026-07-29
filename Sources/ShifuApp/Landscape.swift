import SwiftUI

/// The mountain the app is set on (design.md §7). Flat vector layers — a sky
/// wash, angular far peaks, a temple in the fog, rolling near dunes — with
/// atmospheric perspective doing all the depth work: each layer forward is
/// darker and less washed toward the sky.
///
/// The sky follows the clock. A time ledger whose window matches the light
/// outside is a nicer thing to open at 11pm than the same white card.
enum SkyTime: String, CaseIterable {
    case dawn, day, dusk, night

    static func current(_ date: Date = Date()) -> SkyTime {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<8: return .dawn
        case 8..<17: return .day
        case 17..<20: return .dusk
        default: return .night
        }
    }

    var palette: SkyPalette {
        switch self {
        case .dawn:
            return SkyPalette(
                sky: [0xA9C4E4, 0xD9C3C4, 0xEFC9AC, 0xF9E6CC],
                ridges: [0xAAA8C8, 0x827FA3, 0x57527D, 0x342F54, 0x231F3E],
                ink: 0x2A2745, onDark: false,
                orb: 0xFFE9C4, fog: 0xFBE7D2, fogOpacity: 0.34,
                tread: 0x7C74A6, vermilion: 0xD1613A, lantern: 0xFFD79A)
        case .day:
            return SkyPalette(
                sky: [0x7FB2DE, 0xA9CDE6, 0xCFE0E9, 0xEDE7DA],
                ridges: [0xA8C0CB, 0x7997A7, 0x4F6F7F, 0x2E4A57, 0x1E333D],
                ink: 0x1E3340, onDark: false,
                orb: 0xFFF6DE, fog: 0xFFFFFF, fogOpacity: 0.30,
                tread: 0x6E8C97, vermilion: 0xC2542F, lantern: 0xFFE9B8)
        case .dusk:
            return SkyPalette(
                sky: [0x2E3566, 0x6B4877, 0xC06C64, 0xEFA469],
                ridges: [0x6E5683, 0x4C3B65, 0x2F2447, 0x18122F, 0x100B22],
                ink: 0xF7EBE0, onDark: true,
                orb: 0xFFD79A, fog: 0xF3A472, fogOpacity: 0.24,
                tread: 0x574468, vermilion: 0xE0703F, lantern: 0xFFC46A)
        case .night:
            return SkyPalette(
                sky: [0x080C1C, 0x101731, 0x1B2444, 0x2A3459],
                ridges: [0x33406E, 0x26305A, 0x1A2144, 0x10142C, 0x090C1E],
                ink: 0xE9EEFA, onDark: true,
                orb: 0xEFF3FF, fog: 0x7E8FC0, fogOpacity: 0.18,
                tread: 0x2E3A66, vermilion: 0x8C4632, lantern: 0xFFB85C)
        }
    }
}

/// Every color one sky needs. Stored as hex so a palette reads as a swatch
/// list; `Color` conversion happens once at draw time.
struct SkyPalette {
    let sky: [UInt32]
    /// Far → near, then the bank in front of everything. Five planes is enough
    /// for depth and few enough that each one still reads as distinct.
    let ridges: [UInt32]
    let ink: UInt32
    /// True when text over this sky has to be light — drives `textColor`.
    let onDark: Bool
    let orb: UInt32
    let fog: UInt32
    let fogOpacity: Double
    /// The lit top of a stone step, a shade up from the plane it is cut into.
    /// In flat colour that one band *is* the read of a staircase.
    let tread: UInt32
    /// Temple lacquer — warm at every hour, a dull oxide at night.
    let vermilion: UInt32
    /// Lantern flame and lit windows.
    let lantern: UInt32

    var skyColors: [Color] { sky.map(Color.init(illustration:)) }
    var ridgeColors: [Color] { ridges.map(Color.init(illustration:)) }
    /// Headline color for text laid over the *upper* sky, where the scene is
    /// flattest — the only place the hero puts words.
    var textColor: Color { Color(illustration: ink) }
    var secondaryTextColor: Color { textColor.opacity(onDark ? 0.72 : 0.66) }
    var orbColor: Color { Color(illustration: orb) }
    var fogColor: Color { Color(illustration: fog) }
    var treadColor: Color { Color(illustration: tread) }
    var vermilionColor: Color { Color(illustration: vermilion) }
    var lanternColor: Color { Color(illustration: lantern) }
    /// The near stone the terraces are cut from, and the darker bank in front.
    var stoneColor: Color { Color(illustration: ridges[3]) }
    var deepColor: Color { Color(illustration: ridges[4]) }
}

extension Color {
    /// A fixed illustration color — no light/dark pair. The scene supplies its
    /// own contrast; letting the OS invert it would break the painting.
    init(illustration hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - The scene

struct MountainScene: View {
    enum Detail {
        /// Everything: temple, fog banks, pines, birds or stars.
        case full
        /// Ridges and sky only — for strips under ~140 pt tall, where the
        /// small props turn to litter.
        case compact
    }

    var time: SkyTime = .current()
    var detail: Detail = .full

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            Landscape.draw(palette: time.palette, detail: detail, into: &context, size: size)
        }
        // No .drawingGroup(): Canvas already rasterises, and the extra
        // offscreen pass just doubles the work on every resize.
        .accessibilityHidden(true)
    }

    /// Where anything standing in the scene is planted: the front dune's crest,
    /// right of center and clear of the temple.
    static let standingX: CGFloat = 0.79

    static func groundY(height: CGFloat, at xFraction: CGFloat = standingX) -> CGFloat {
        Landscape.duneY(.front, at: xFraction, height: height)
    }
}

/// The app's signature image: the mountain with Shifu standing on it. Every
/// surface that wants "the place" rather than "a chart" uses this.
struct ShifuScene: View {
    var time: SkyTime = .current()
    var mood: SenseiFigure.Mood = .serene
    var detail: MountainScene.Detail = .full
    var petSize: CGFloat = 96

    var body: some View {
        GeometryReader { proxy in
            MountainScene(time: time, detail: detail)
                .overlay(alignment: .topLeading) {
                    SenseiFigure(size: petSize, mood: mood)
                        .offset(
                            x: proxy.size.width * MountainScene.standingX - petSize / 2,
                            // His feet sit at 0.97 of the sprite box.
                            y: MountainScene.groundY(height: proxy.size.height) - petSize * 0.97)
                }
        }
    }
}

private enum Landscape {
    /// Angular far peaks, in normalized (x, height) pairs. Hand-placed rather
    /// than generated: a good skyline has a couple of dominant summits and a
    /// lot of restraint, which noise never gives you.
    static let farPeaks: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.22), CGPoint(x: 0.08, y: 0.54), CGPoint(x: 0.15, y: 0.36),
        CGPoint(x: 0.25, y: 0.88), CGPoint(x: 0.34, y: 0.44), CGPoint(x: 0.41, y: 0.62),
        CGPoint(x: 0.50, y: 0.30), CGPoint(x: 0.59, y: 0.72), CGPoint(x: 0.68, y: 0.46),
        CGPoint(x: 0.78, y: 1.00), CGPoint(x: 0.87, y: 0.42), CGPoint(x: 0.94, y: 0.60),
        CGPoint(x: 1.00, y: 0.30)
    ]

    /// The mid range. Its tallest summit — index 4, at x = 0.45 — carries the
    /// temple. It sits right of center so the hero's text column, which owns the
    /// left third of the sky, never runs into a pagoda.
    static let midPeaks: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.40), CGPoint(x: 0.10, y: 0.22), CGPoint(x: 0.20, y: 0.52),
        CGPoint(x: 0.30, y: 0.34), CGPoint(x: 0.45, y: 1.00), CGPoint(x: 0.53, y: 0.48),
        CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.67, y: 0.58), CGPoint(x: 0.74, y: 0.34),
        CGPoint(x: 0.83, y: 0.74), CGPoint(x: 0.91, y: 0.44), CGPoint(x: 1.00, y: 0.56)
    ]

    static let templeIndex = 4

    static func draw(
        palette: SkyPalette, detail: MountainScene.Detail,
        into context: inout GraphicsContext, size: CGSize
    ) {
        let colors = palette.ridgeColors
        drawSky(palette, into: &context, size: size)
        drawOrb(palette, into: &context, size: size)
        if detail == .full { drawSparks(palette, into: &context, size: size) }

        context.fill(
            peakPath(farPeaks, baseline: 0.70, amplitude: 0.44, size: size),
            with: .color(colors[0]))
        drawFog(palette, at: 0.66, weight: 1.0, into: &context, size: size)

        context.fill(
            peakPath(midPeaks, baseline: 0.84, amplitude: 0.40, size: size),
            with: .color(colors[1]))
        if detail == .full { drawTemple(palette, into: &context, size: size) }
        // The bank the temple sits above: the summit clears it, the shoulders
        // don't, which is the whole "hut in the fog" reading.
        drawFog(palette, at: 0.60, weight: 0.75, into: &context, size: size)
        drawFog(palette, at: 0.80, weight: 0.9, into: &context, size: size)

        context.fill(dunePath(.back, size: size), with: .color(colors[2]))
        if detail == .full { drawPines(palette, into: &context, size: size) }
        context.fill(dunePath(.front, size: size), with: .color(colors[3]))
    }

    // MARK: - Sky

    private static func drawSky(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: palette.skyColors),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.92)))
    }

    /// Sun or moon, set in the notch left of the tallest far peak so it is
    /// half-framed by the skyline instead of floating in open sky — and on the
    /// right, where the hero lays no text.
    private static func drawOrb(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        let radius = size.height * 0.095
        let center = CGPoint(x: size.width * 0.665, y: size.height * 0.30)
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - radius * 3.4, y: center.y - radius * 3.4,
                width: radius * 6.8, height: radius * 6.8)),
            with: .radialGradient(
                Gradient(colors: [palette.orbColor.opacity(0.30), palette.orbColor.opacity(0)]),
                center: center, startRadius: radius, endRadius: radius * 3.4))
        let disc = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        guard palette.onDark, palette.fogOpacity < 0.2 else {
            context.fill(disc, with: .color(palette.orbColor))
            return
        }
        // Night: bite a crescent out of the disc rather than drawing an arc.
        context.drawLayer { layer in
            layer.clip(
                to: Path(ellipseIn: CGRect(
                    x: center.x - radius * 0.62, y: center.y - radius * 1.1,
                    width: radius * 2, height: radius * 2)),
                options: .inverse)
            layer.fill(disc, with: .color(palette.orbColor))
        }
    }

    /// Stars at night, birds by day — the same slot in the composition, filled
    /// by whatever the hour makes plausible.
    private static func drawSparks(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        guard palette.onDark else {
            drawBirds(palette, into: &context, size: size)
            return
        }
        var seed: UInt64 = 0x5EED
        for _ in 0..<52 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let xFraction = CGFloat((seed >> 33) % 1_000) / 1_000
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let yFraction = CGFloat((seed >> 33) % 1_000) / 1_000
            let radius = 0.6 + CGFloat((seed >> 13) % 12) / 10
            // Stars thin out toward the horizon, where dusk's glow would drown
            // them anyway — the fade is what keeps them off the orange band.
            let depth = pow(1 - yFraction, 2.2)
            let point = CGPoint(x: xFraction * size.width, y: yFraction * size.height * 0.60)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: point.x, y: point.y, width: radius, height: radius)),
                with: .color(.white.opacity(
                    (0.28 + Double((seed >> 7) % 55) / 100) * Double(depth))))
        }
    }

    private static func drawBirds(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        let flock = [CGPoint(x: 0.17, y: 0.18), CGPoint(x: 0.24, y: 0.11),
                     CGPoint(x: 0.30, y: 0.21)]
        for (index, spot) in flock.enumerated() {
            let span = size.height * (index == 1 ? 0.045 : 0.035)
            let origin = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
            var path = Path()
            path.move(to: CGPoint(x: origin.x - span, y: origin.y))
            path.addQuadCurve(
                to: origin, control: CGPoint(x: origin.x - span * 0.5, y: origin.y - span * 0.6))
            path.addQuadCurve(
                to: CGPoint(x: origin.x + span, y: origin.y),
                control: CGPoint(x: origin.x + span * 0.5, y: origin.y - span * 0.6))
            context.stroke(
                path, with: .color(palette.ridgeColors[1].opacity(0.55)),
                style: StrokeStyle(lineWidth: max(1, size.height * 0.006), lineCap: .round))
        }
    }

    /// A soft horizontal bank sitting on a ridge line. Blur plus a wide ellipse
    /// beats any gradient here — the edges have to feel like weather.
    private static func drawFog(
        _ palette: SkyPalette, at fraction: CGFloat, weight: Double,
        into context: inout GraphicsContext, size: CGSize
    ) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: size.height * 0.05))
            for (offset, spread, alpha) in [(0.0, 0.13, 1.0), (0.035, 0.06, 0.7)] {
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: -size.width * 0.2,
                        y: (fraction + offset) * size.height - size.height * spread / 2,
                        width: size.width * 1.4, height: size.height * spread)),
                    with: .color(palette.fogColor.opacity(
                        palette.fogOpacity * weight * alpha)))
            }
        }
    }

    // MARK: - Ground

    /// A ridge of straight-edged peaks, filled down to the bottom of the frame.
    private static func peakPath(
        _ profile: [CGPoint], baseline: CGFloat, amplitude: CGFloat, size: CGSize
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for point in profile {
            path.addLine(to: CGPoint(
                x: point.x * size.width,
                y: (baseline - point.y * amplitude) * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// The two rolling near layers. Each is two sines summed; the phases are
    /// chosen so the front dune crests around x = 0.78 — the shelf the pet
    /// stands on — while the back one crests left of the temple.
    enum Dune {
        case back, front

        var baseline: CGFloat { self == .back ? 0.93 : 1.07 }
        var amplitude: CGFloat { self == .back ? 0.13 : 0.24 }
        var phase: CGFloat { self == .back ? 0.03 : 0.69 }
    }

    /// Ground height at a horizontal fraction. The single source of truth for
    /// the dune outline, the trees standing on it, and anything the app plants
    /// on the front crest.
    static func duneY(_ dune: Dune, at xFraction: CGFloat, height: CGFloat) -> CGFloat {
        let wave = 0.5
            + 0.34 * sin(2 * .pi * (xFraction * 0.72 + dune.phase))
            + 0.16 * sin(2 * .pi * (xFraction * 1.9 + dune.phase * 2.3))
        return (dune.baseline - wave * dune.amplitude) * height
    }

    /// Sampled densely enough that the straight segments read as a curve.
    private static func dunePath(_ dune: Dune, size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for step in 0...80 {
            let xFraction = CGFloat(step) / 80
            path.addLine(to: CGPoint(
                x: xFraction * size.width,
                y: duneY(dune, at: xFraction, height: size.height)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// A small grove on the back dune's shoulder, left of the temple peak, sized
    /// down as it recedes.
    private static func drawPines(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        for (xFraction, scale) in [(0.17, 1.0), (0.215, 0.68), (0.255, 0.85), (0.50, 0.6)] {
            let height = size.height * 0.072 * scale
            let baseY = duneY(.back, at: CGFloat(xFraction), height: size.height) + 1
            let baseX = CGFloat(xFraction) * size.width
            var path = Path()
            path.move(to: CGPoint(x: baseX, y: baseY - height))
            path.addLine(to: CGPoint(x: baseX + height * 0.30, y: baseY))
            path.addLine(to: CGPoint(x: baseX - height * 0.30, y: baseY))
            path.closeSubpath()
            context.fill(path, with: .color(palette.ridgeColors[3]))
        }
    }

    // MARK: - The temple

    /// Where Shifu lives: a three-tier pagoda on the mid range's summit, small
    /// enough to be a detail you find rather than a logo.
    private static func drawTemple(
        _ palette: SkyPalette, into context: inout GraphicsContext, size: CGSize
    ) {
        let peak = midPeaks[templeIndex]
        let unit = size.height * 0.034
        let baseX = peak.x * size.width
        let baseY = (0.84 - peak.y * 0.40) * size.height + unit * 0.9
        var path = Path()
        path.addRect(CGRect(x: baseX - unit * 1.0, y: baseY - unit * 0.28,
                            width: unit * 2.0, height: unit * 0.28))
        appendRoof(&path, centerX: baseX, baseY: baseY - unit * 0.28, width: unit * 2.5,
                   height: unit * 0.75)
        appendRect(&path, centerX: baseX, bottomY: baseY - unit * 0.95, width: unit * 1.15,
                   height: unit * 0.62)
        appendRoof(&path, centerX: baseX, baseY: baseY - unit * 1.57, width: unit * 1.95,
                   height: unit * 0.68)
        appendRect(&path, centerX: baseX, bottomY: baseY - unit * 2.15, width: unit * 0.85,
                   height: unit * 0.55)
        appendRoof(&path, centerX: baseX, baseY: baseY - unit * 2.70, width: unit * 1.40,
                   height: unit * 0.60)
        appendRect(&path, centerX: baseX, bottomY: baseY - unit * 3.22, width: unit * 0.14,
                   height: unit * 0.5)
        context.fill(path, with: .color(palette.ridgeColors[3]))
    }

    /// One pagoda eave: flat underside, ends flicking up past the ridge line.
    private static func appendRoof(
        _ path: inout Path, centerX: CGFloat, baseY: CGFloat, width: CGFloat, height: CGFloat
    ) {
        let half = width / 2
        path.move(to: CGPoint(x: centerX - half, y: baseY - height * 0.30))
        path.addQuadCurve(
            to: CGPoint(x: centerX, y: baseY - height),
            control: CGPoint(x: centerX - half * 0.42, y: baseY - height * 0.94))
        path.addQuadCurve(
            to: CGPoint(x: centerX + half, y: baseY - height * 0.30),
            control: CGPoint(x: centerX + half * 0.42, y: baseY - height * 0.94))
        path.addLine(to: CGPoint(x: centerX + half * 0.72, y: baseY))
        path.addLine(to: CGPoint(x: centerX - half * 0.72, y: baseY))
        path.closeSubpath()
    }

    private static func appendRect(
        _ path: inout Path, centerX: CGFloat, bottomY: CGFloat, width: CGFloat, height: CGFloat
    ) {
        path.addRect(CGRect(
            x: centerX - width / 2, y: bottomY - height, width: width, height: height))
    }
}

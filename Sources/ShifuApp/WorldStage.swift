import SwiftUI

/// The window's ground: the whole mountain, painted edge to edge behind
/// everything else (design.md §7).
///
/// The view is `Animatable` on the camera, so SwiftUI interpolates the flight
/// between two terraces frame by frame and the Canvas simply paints wherever
/// the camera currently is. Nothing here ticks on its own — when the camera is
/// parked the scene is a still image and costs nothing to leave open all day,
/// which is the same bargain the pixel sprite makes.
struct WorldStage: View, Animatable {
    var camera: Camera
    var anchor: UnitPoint
    var sky: SkyTime
    var mood: SenseiFigure.Mood
    /// The leg being walked. The drawing reads "moving" vs "arrived" off the
    /// interpolated camera's distance from either end, so it needs no clock and
    /// survives a change of destination mid-flight.
    var origin: CGPoint
    var arrival: CGPoint
    /// 0…1 of a hop in place, from a click on the world.
    var hop: CGFloat

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                   AnimatablePair<CGFloat, CGFloat>> {
        get {
            .init(.init(camera.target.x, camera.target.y), .init(camera.span, hop))
        }
        set {
            camera.target = CGPoint(x: newValue.first.first, y: newValue.first.second)
            camera.span = newValue.second.first
            hop = newValue.second.second
        }
    }

    /// 0 parked, 1 at the midpoint of the leg. Measured off the live camera
    /// rather than a timer, which is what lets the pull-back and Shifu's gait
    /// stay in step with whatever curve the animation happens to be using.
    private var travel: CGFloat {
        let total = hypot(arrival.x - origin.x, arrival.y - origin.y)
        guard total > 1 else { return 0 }
        let fromStart = hypot(camera.target.x - origin.x, camera.target.y - origin.y)
        let toEnd = hypot(camera.target.x - arrival.x, camera.target.y - arrival.y)
        return min(1, 2 * min(fromStart, toEnd) / total)
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let pulled = Camera(
                target: camera.target,
                span: camera.span * (1 + WorldMap.travelPullback * travel))
            WorldPainter(
                palette: sky.palette,
                projection: Projection(camera: pulled, size: size, anchor: anchor),
                travel: travel, hop: hop, mood: mood
            )
            .paint(into: &context)
        }
        .accessibilityHidden(true)
    }
}

/// One frame of the world. Layers back to front; every one of them is flat
/// colour, and depth is carried by nothing but how much each plane moves.
struct WorldPainter {
    let palette: SkyPalette
    let projection: Projection
    let travel: CGFloat
    let hop: CGFloat
    let mood: SenseiFigure.Mood

    var size: CGSize { projection.size }
    /// 0 at the camp, 1 at the summit — the cue for the sea of cloud.
    var altitude: CGFloat { WorldMap.altitude(of: projection.camera.target.y) }

    func paint(into context: inout GraphicsContext) {
        drawSky(into: &context)
        drawOrb(into: &context)
        drawSparks(into: &context)
        drawClouds(into: &context)
        for range in Ridgeline.ranges {
            drawRange(range, into: &context)
            // A bank on the two far ridges only. The near hills carry the
            // depth on their own, and a third smear across the middle of the
            // window reads as a dirty screen rather than as weather.
            guard range.colorIndex < 2 else { continue }
            drawHaze(
                atY: projection.baselineY(range) + 10,
                weight: 0.55 + 0.45 * altitude, into: &context)
        }
        drawTerraces(into: &context)
        drawLandmarks(into: &context)
        drawShifu(into: &context)
        drawRange(Ridgeline.foreground, into: &context)
    }

    // MARK: - Sky

    private func drawSky(into context: inout GraphicsContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: palette.skyColors),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.94)))
    }

    /// Sun or moon, parked high and to the right. The whole climb drifts it by
    /// about a tenth of the window — enough that it feels pinned to the world
    /// rather than to the glass, little enough that it never has to wrap.
    private func drawOrb(into context: inout GraphicsContext) {
        let radius = size.height * 0.075
        let centre = CGPoint(
            x: size.width * 0.70 - skyDrift * 1.2,
            y: size.height * 0.19 + altitude * 24)
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius * 3.6, y: centre.y - radius * 3.6,
                width: radius * 7.2, height: radius * 7.2)),
            with: .radialGradient(
                Gradient(colors: [palette.orbColor.opacity(0.26), palette.orbColor.opacity(0)]),
                center: centre, startRadius: radius, endRadius: radius * 3.6))
        let disc = Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        guard palette.onDark, palette.fogOpacity < 0.2 else {
            context.fill(disc, with: .color(palette.orbColor))
            return
        }
        // Night: bite a crescent out of the disc rather than drawing an arc.
        context.drawLayer { layer in
            layer.clip(
                to: Path(ellipseIn: CGRect(
                    x: centre.x - radius * 0.62, y: centre.y - radius * 1.1,
                    width: radius * 2, height: radius * 2)),
                options: .inverse)
            layer.fill(disc, with: .color(palette.orbColor))
        }
    }

    /// How far the slowest plane in the scene has slid since the camp. Small
    /// enough over the whole climb that the sky never needs wrapping.
    private var skyDrift: CGFloat {
        (projection.camera.target.x - WorldMap.firstStationX) * 0.03 * projection.scale
    }

    /// Stars at night, birds by day — the same slot in the composition, filled
    /// by whatever the hour makes plausible. Both drift with the camera at the
    /// slowest parallax in the scene.
    private func drawSparks(into context: inout GraphicsContext) {
        guard palette.onDark else {
            drawBirds(into: &context)
            return
        }
        var seed: UInt64 = 0x5EED
        for _ in 0..<64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let across = CGFloat((seed >> 33) % 1_000) / 1_000
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let down = CGFloat((seed >> 33) % 1_000) / 1_000
            let radius = 0.6 + CGFloat((seed >> 13) % 12) / 10
            // Stars thin out toward the horizon, where the glow would drown
            // them anyway — the fade is what keeps them off the bright band.
            let depth = pow(1 - down, 2.2)
            let spot = CGPoint(
                x: across * size.width * 1.4 - size.width * 0.2 - skyDrift,
                y: down * size.height * 0.62)
            context.fill(
                Path(ellipseIn: CGRect(x: spot.x, y: spot.y, width: radius, height: radius)),
                with: .color(.white.opacity(
                    (0.28 + Double((seed >> 7) % 55) / 100) * Double(depth))))
        }
    }

    private func drawBirds(into context: inout GraphicsContext) {
        let flock = [CGPoint(x: 0.42, y: 0.17), CGPoint(x: 0.49, y: 0.10),
                     CGPoint(x: 0.55, y: 0.20)]
        for (index, spot) in flock.enumerated() {
            let span = size.height * (index == 1 ? 0.030 : 0.023)
            let origin = CGPoint(
                x: spot.x * size.width - skyDrift, y: spot.y * size.height)
            var path = Path()
            path.move(to: CGPoint(x: origin.x - span, y: origin.y))
            path.addQuadCurve(
                to: origin, control: CGPoint(x: origin.x - span * 0.5, y: origin.y - span * 0.6))
            path.addQuadCurve(
                to: CGPoint(x: origin.x + span, y: origin.y),
                control: CGPoint(x: origin.x + span * 0.5, y: origin.y - span * 0.6))
            context.stroke(
                path, with: .color(palette.ridgeColors[1].opacity(0.55)),
                style: StrokeStyle(lineWidth: max(1, size.height * 0.005), lineCap: .round))
        }
    }

    /// Flat-bottomed lozenges high in the sky, one per cell of world so they
    /// never run out however far you climb. They drift at the slowest parallax
    /// in the scene, which is what stops the sky reading as a painted backdrop.
    private func drawClouds(into context: inout GraphicsContext) {
        let parallax: CGFloat = 0.10
        let period: CGFloat = 820
        let first = Int((projection.worldX(atScreen: -260, parallax: parallax) / period)
            .rounded(.down))
        let last = Int((projection.worldX(atScreen: size.width + 260, parallax: parallax) / period)
            .rounded(.up))
        var clouds = Path()
        for cell in first...last {
            let jitter = (sin(CGFloat(cell) * 21.7) + 1) / 2
            guard jitter > 0.28 else { continue }
            let worldX = (CGFloat(cell) + jitter * 0.6) * period
            let centre = CGPoint(
                x: projection.anchorPoint.x
                    + (worldX - projection.camera.target.x * parallax) * projection.scale,
                y: size.height * (0.09 + 0.17 * jitter))
            let width = size.height * (0.10 + 0.07 * jitter)
            let height = width * 0.36
            for (offset, scale) in [(-0.42, 0.62), (0.0, 1.0), (0.44, 0.7)] {
                clouds.addEllipse(in: CGRect(
                    x: centre.x + width * CGFloat(offset) - width * CGFloat(scale) / 2,
                    y: centre.y - height * CGFloat(scale),
                    width: width * CGFloat(scale), height: height * CGFloat(scale) * 2))
            }
            clouds.addRect(CGRect(
                x: centre.x - width * 0.78, y: centre.y - height * 0.1,
                width: width * 1.56, height: height * 0.1))
        }
        context.fill(clouds, with: .color(palette.fogColor.opacity(palette.fogOpacity * 0.7)))
    }

    // MARK: - Ranges

    /// One procedural skyline, sampled across the window. Six points per
    /// sample keeps a triangular summit sharp enough to read as rock without
    /// paying for a path the size of the window.
    private func drawRange(_ range: Ridgeline.Range, into context: inout GraphicsContext) {
        let baseline = projection.baselineY(range)
        let lift = range.amplitude * projection.scale
        var path = Path()
        path.move(to: CGPoint(x: -4, y: size.height + 4))
        var screenX: CGFloat = -4
        while screenX <= size.width + 4 {
            let worldX = projection.worldX(atScreen: screenX, parallax: range.parallax)
            path.addLine(to: CGPoint(
                x: screenX, y: baseline - Ridgeline.profile(range, at: worldX) * lift))
            screenX += 6
        }
        path.addLine(to: CGPoint(x: size.width + 4, y: size.height + 4))
        path.closeSubpath()
        context.fill(path, with: .color(palette.ridgeColors[range.colorIndex]))
    }

    /// A soft bank sitting on a ridge line. A gradient rather than a blurred
    /// ellipse: the camera repaints this every frame of a flight, and a blur
    /// filter the width of the window is the one thing here that would cost
    /// real money.
    private func drawHaze(atY centreY: CGFloat, weight: Double,
                          into context: inout GraphicsContext) {
        let band = size.height * 0.20
        guard centreY > -band else { return }
        // High up, the ranges sink toward the terrace you are standing on, and
        // a bank laid over the stone reads as a washed-out screen rather than
        // as cloud. Fade each one out as it nears the ground.
        let clearance = (size.height * 0.78 - centreY) / (size.height * 0.16)
        let weight = weight * Double(min(1, max(0, clearance)))
        guard weight > 0.01 else { return }
        context.fill(
            Path(CGRect(x: 0, y: centreY - band / 2, width: size.width, height: band)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: palette.fogColor.opacity(0), location: 0),
                    .init(
                        color: palette.fogColor.opacity(palette.fogOpacity * weight),
                        location: 0.46),
                    .init(color: palette.fogColor.opacity(0), location: 1)
                ]),
                startPoint: CGPoint(x: 0, y: centreY - band / 2),
                endPoint: CGPoint(x: 0, y: centreY + band / 2)))
    }

    // MARK: - The stair

    /// The terraces and the flights between them: one silhouette filled to the
    /// bottom of the frame, then a lit band on every flat top. Both come off
    /// the same list of runs, so the steps Shifu walks are the steps you see.
    private func drawTerraces(into context: inout GraphicsContext) {
        let runs = WorldMap.runs(
            from: projection.worldX(atScreen: -60, parallax: 1),
            to: projection.worldX(atScreen: size.width + 60, parallax: 1))
        guard let first = runs.first, let last = runs.last else { return }
        let floorY = size.height + 80
        var body = Path()
        let start = projection.point(CGPoint(x: first.minX, y: first.topY))
        body.move(to: CGPoint(x: start.x, y: floorY))
        body.addLine(to: start)
        for run in runs {
            body.addLine(to: projection.point(CGPoint(x: run.minX, y: run.topY)))
            body.addLine(to: projection.point(CGPoint(x: run.maxX, y: run.topY)))
        }
        let end = projection.point(CGPoint(x: last.maxX, y: last.topY))
        body.addLine(to: CGPoint(x: end.x, y: floorY))
        body.closeSubpath()
        // The mountain the terraces are cut into, then the ledges themselves as
        // a band following the same profile. Without the band the whole lower
        // half of the window is one flat wedge; with it the steps read as slabs
        // resting on a mountain, which is the thing you can imagine jumping on.
        context.fill(body, with: .color(palette.deepColor))
        context.fill(body, with: .color(palette.stoneColor.opacity(0.32)))
        context.fill(ledgePath(runs), with: .color(palette.stoneColor))

        // Then the light: a bright tread, and the lit face of the slab under
        // it. Four values from three colours is what turns a filled outline
        // into stone you could stand on.
        var faces = Path()
        var treads = Path()
        let faceDepth = 30 * projection.scale
        let treadDepth = 8 * projection.scale
        for run in runs {
            let left = projection.point(CGPoint(x: run.minX, y: run.topY))
            guard left.y > -faceDepth, left.y < size.height else { continue }
            let right = projection.point(CGPoint(x: run.maxX, y: run.topY))
            faces.addRect(CGRect(
                x: left.x, y: left.y, width: right.x - left.x, height: faceDepth))
            treads.addRect(CGRect(
                x: left.x, y: left.y, width: right.x - left.x, height: treadDepth))
        }
        context.fill(faces, with: .color(palette.treadColor.opacity(0.4)))
        context.fill(treads, with: .color(palette.treadColor))
        drawPines(on: runs, into: &context)
    }

    /// The slab band: out along the tops of the runs, back along the same
    /// profile dropped by the ledge's thickness.
    private func ledgePath(_ runs: [WorldMap.Run]) -> Path {
        let thickness = 120 * projection.scale
        var path = Path()
        guard let first = runs.first else { return path }
        path.move(to: projection.point(CGPoint(x: first.minX, y: first.topY)))
        for run in runs {
            path.addLine(to: projection.point(CGPoint(x: run.minX, y: run.topY)))
            path.addLine(to: projection.point(CGPoint(x: run.maxX, y: run.topY)))
        }
        for run in runs.reversed() {
            let right = projection.point(CGPoint(x: run.maxX, y: run.topY))
            let left = projection.point(CGPoint(x: run.minX, y: run.topY))
            path.addLine(to: CGPoint(x: right.x, y: right.y + thickness))
            path.addLine(to: CGPoint(x: left.x, y: left.y + thickness))
        }
        path.closeSubpath()
        return path
    }

    /// Pines beside the steps, for scale. The terraces are the temples' — the
    /// flights are where anything grows. Placed off a hash of the tread's own
    /// x, so a given step always grows the same tree.
    private func drawPines(on runs: [WorldMap.Run], into context: inout GraphicsContext) {
        var grove = Path()
        for run in runs where run.maxX - run.minX < WorldMap.terraceHalfWidth {
            let worldX = (run.minX + run.maxX) / 2
            let seed = (sin(worldX * 0.041) + 1) / 2
            guard seed > 0.52 else { continue }
            appendPine(
                &grove, at: projection.point(CGPoint(x: worldX, y: run.topY)),
                height: (38 + 22 * seed) * projection.scale)
        }
        context.fill(grove, with: .color(palette.deepColor))
    }

    private func appendPine(_ path: inout Path, at foot: CGPoint, height: CGFloat) {
        path.addRect(CGRect(
            x: foot.x - height * 0.035, y: foot.y - height * 0.3,
            width: height * 0.07, height: height * 0.3))
        for tier in 0..<3 {
            let spread = height * (0.42 - CGFloat(tier) * 0.10)
            let top = foot.y - height * (0.42 + CGFloat(tier) * 0.22)
            path.move(to: CGPoint(x: foot.x, y: top - height * 0.26))
            path.addLine(to: CGPoint(x: foot.x + spread, y: top))
            path.addLine(to: CGPoint(x: foot.x - spread, y: top))
            path.closeSubpath()
        }
    }

    private func drawLandmarks(into context: inout GraphicsContext) {
        let left = projection.worldX(atScreen: -240, parallax: 1)
        let right = projection.worldX(atScreen: size.width + 240, parallax: 1)
        for destination in Destination.allCases {
            let stationX = WorldMap.stationX(destination.stationIndex)
            guard stationX > left, stationX < right else { continue }
            let terrace = CGPoint(
                x: stationX, y: WorldMap.terraceY(destination.stationIndex))
            draw(destination.landmark, on: terrace, into: &context)
            drawSign(destination, on: terrace, into: &context)
        }
    }

    /// Every terrace wears its name, cut into the cliff under the lip. Drawn
    /// inside the Canvas so the signs travel with the camera — the place you
    /// are heading for is legible from the terrace you are leaving, which is
    /// what makes the trail a map rather than a list.
    private func drawSign(_ destination: Destination, on terrace: CGPoint,
                          into context: inout GraphicsContext) {
        let anchor = projection.point(
            CGPoint(x: terrace.x - WorldMap.terraceHalfWidth + 26, y: terrace.y))
        let size = 13 * min(1.35, projection.scale)
        guard size > 7 else { return }
        // The one you are standing on is the only one at full strength.
        let here = abs(terrace.x - projection.camera.target.x) < WorldMap.terraceHalfWidth
        var text = context.resolve(
            Text(destination.title.uppercased())
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .tracking(size * 0.14))
        text.shading = .color(palette.treadColor.opacity(here ? 0.95 : 0.5))
        context.draw(text, at: CGPoint(x: anchor.x, y: anchor.y + size * 3.1),
                     anchor: .leading)
    }

    // MARK: - Shifu

    /// He stands a little right of the temple door, on whatever step is under
    /// him. His world x *is* the camera's, so he walks the flight for exactly
    /// as long as the camera does and stands still the moment it parks — no
    /// separate animation to keep in sync.
    private func drawShifu(into context: inout GraphicsContext) {
        let worldX = projection.camera.target.x - 170
        // A bounding gait while travelling, and a straight pop for a click.
        let gait = 26 * travel * abs(sin(worldX / 52))
        let feet = projection.point(
            CGPoint(x: worldX, y: WorldMap.groundY(at: worldX) - gait - 52 * hop))
        let side = 46 * projection.scale
        guard side > 4 else { return }
        let shade = projection.point(CGPoint(x: worldX, y: WorldMap.groundY(at: worldX)))
        context.fill(
            Path(ellipseIn: CGRect(
                x: shade.x - side * 0.32, y: shade.y - side * 0.06,
                width: side * 0.64, height: side * 0.12)),
            with: .color(.black.opacity(0.18)))
        // The sprite's lowest inked row is 15 of 16, so that is where his feet
        // are in the box — not the bottom edge.
        SenseiSprite.draw(
            mood: mood, into: &context,
            in: CGRect(x: feet.x - side / 2, y: feet.y - side * 0.9375,
                       width: side, height: side))
    }
}

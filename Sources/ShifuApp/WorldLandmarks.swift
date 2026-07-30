import SwiftUI

/// The three passes a landmark is built from. Everything of one colour goes
/// into one path, so a whole temple is three fills however many parts it has.
private struct LandmarkPaths {
    var stone = Path()
    var lacquer = Path()
    /// Lantern paper, lit at every hour.
    var flame = Path()
    /// Windows, lit only after dark.
    var glow = Path()
}

/// What stands on a terrace (design.md §7). Five parts — stacked pagoda roofs,
/// a vermilion gate, standing stones, a banner, a beacon — combined differently
/// per place. The tiers climb with the mountain, so a glance at the skyline
/// tells you how far up the app you are before you read a single word.
///
/// Everything is drawn in world units off the terrace's top-centre, so a
/// landmark keeps its proportions whatever the camera is doing.
extension WorldPainter {
    func draw(_ landmark: Landmark, on terrace: CGPoint, into context: inout GraphicsContext) {
        // A terrace is 3.75 units either side of its centre, and the furniture
        // sits in fixed slots inside that: Shifu at −3.04 where the steps
        // arrive, lanterns at ±2.32, the hall in the middle, and one feature —
        // gate, stones, or banner, never two — at +2.7. Nothing a place is
        // given can land on anything else it was given.
        let unit = WorldMap.terraceHalfWidth / 3.75 * projection.scale
        guard unit > 1.5 else { return }
        let base = projection.point(terrace)
        var parts = LandmarkPaths()

        if landmark.torii {
            appendTorii(&parts.lacquer, centreX: base.x + unit * 2.7, baseY: base.y, unit: unit)
        }
        for index in 0..<landmark.steles {
            let spread = CGFloat(index) - CGFloat(landmark.steles - 1) / 2
            appendStele(&parts.stone, centreX: base.x + unit * (2.9 + spread * 0.55),
                        baseY: base.y, unit: unit * (index.isMultiple(of: 2) ? 1 : 0.78))
        }
        if landmark.banner {
            appendBanner(&parts, centreX: base.x + unit * 2.7, baseY: base.y, unit: unit)
        }
        let roofTop = appendHall(&parts, landmark, centreX: base.x, baseY: base.y, unit: unit)
        // One lantern lights the arrival side; a second only where the far
        // side of the terrace has nothing else standing on it.
        for side in [-1.0, 1.0] where landmark.lanterns > (side > 0 ? 1 : 0) {
            appendLantern(&parts, centreX: base.x + CGFloat(side) * unit * 2.32,
                          baseY: base.y, unit: unit)
        }

        context.fill(parts.stone, with: .color(palette.deepColor))
        context.fill(parts.lacquer, with: .color(palette.vermilionColor))
        // Paper burns warm at any hour, so the lantern boxes are always lit;
        // windows are not — a temple with its lamps on at noon reads as a
        // mistake rather than as warmth.
        context.fill(parts.flame, with: .color(palette.lanternColor))
        if landmark.beacon {
            drawBeacon(at: CGPoint(x: base.x, y: roofTop - unit * 0.2),
                       unit: unit, into: &context)
        }
        guard palette.onDark else { return }
        context.fill(parts.glow, with: .color(palette.lanternColor))
    }

    // MARK: - Parts

    /// The hall and its stacked roofs. Each tier is a shorter, narrower box
    /// with an eave over it; the topmost gets a finial. Returns the height it
    /// reached, which is where a beacon goes.
    @discardableResult
    private func appendHall(
        _ parts: inout LandmarkPaths, _ landmark: Landmark,
        centreX: CGFloat, baseY: CGFloat, unit: CGFloat
    ) -> CGFloat {
        var floorY = baseY
        for tier in 0..<max(1, landmark.tiers) {
            let taper = 1 - CGFloat(tier) * 0.16
            let bodyWidth = unit * 1.5 * landmark.hallWidth * taper
            let bodyHeight = unit * 0.72 * taper
            parts.stone.addRect(CGRect(
                x: centreX - bodyWidth / 2, y: floorY - bodyHeight,
                width: bodyWidth, height: bodyHeight))
            if tier == 0 {
                let doorWidth = min(unit * 0.42, bodyWidth * 0.3)
                parts.glow.addRect(CGRect(
                    x: centreX - doorWidth / 2, y: floorY - bodyHeight * 0.82,
                    width: doorWidth, height: bodyHeight * 0.82))
            } else {
                parts.glow.addRect(CGRect(
                    x: centreX - bodyWidth * 0.16, y: floorY - bodyHeight * 0.7,
                    width: bodyWidth * 0.32, height: bodyHeight * 0.44))
            }
            appendRoof(&parts.lacquer, centreX: centreX, baseY: floorY - bodyHeight,
                       width: bodyWidth + unit * 1.05, height: unit * 0.62 * taper)
            floorY -= bodyHeight + unit * 0.34 * taper
        }
        parts.stone.addRect(CGRect(x: centreX - unit * 0.05, y: floorY - unit * 0.42,
                                   width: unit * 0.1, height: unit * 0.42))
        return floorY - unit * 0.42
    }

    /// One pagoda eave: flat underside, ends flicking up past the ridge line.
    private func appendRoof(
        _ path: inout Path, centreX: CGFloat, baseY: CGFloat, width: CGFloat, height: CGFloat
    ) {
        let half = width / 2
        path.move(to: CGPoint(x: centreX - half, y: baseY - height * 0.30))
        path.addQuadCurve(
            to: CGPoint(x: centreX, y: baseY - height),
            control: CGPoint(x: centreX - half * 0.42, y: baseY - height * 0.94))
        path.addQuadCurve(
            to: CGPoint(x: centreX + half, y: baseY - height * 0.30),
            control: CGPoint(x: centreX + half * 0.42, y: baseY - height * 0.94))
        path.addLine(to: CGPoint(x: centreX + half * 0.62, y: baseY))
        path.addLine(to: CGPoint(x: centreX - half * 0.62, y: baseY))
        path.closeSubpath()
    }

    /// Two posts and two lintels, the upper one curved. The only saturated
    /// thing in the scene, which is why exactly one place gets it.
    private func appendTorii(
        _ path: inout Path, centreX: CGFloat, baseY: CGFloat, unit: CGFloat
    ) {
        let half = unit * 0.85
        let height = unit * 1.85
        for side in [-1.0, 1.0] {
            path.addRect(CGRect(
                x: centreX + CGFloat(side) * half - unit * 0.09, y: baseY - height,
                width: unit * 0.18, height: height))
        }
        path.addRect(CGRect(
            x: centreX - half * 0.92, y: baseY - height * 0.72,
            width: half * 1.84, height: unit * 0.13))
        path.move(to: CGPoint(x: centreX - half * 1.30, y: baseY - height * 0.86))
        path.addQuadCurve(
            to: CGPoint(x: centreX + half * 1.30, y: baseY - height * 0.86),
            control: CGPoint(x: centreX, y: baseY - height * 1.10))
        path.addLine(to: CGPoint(x: centreX + half * 1.30, y: baseY - height * 0.98))
        path.addQuadCurve(
            to: CGPoint(x: centreX - half * 1.30, y: baseY - height * 0.98),
            control: CGPoint(x: centreX, y: baseY - height * 1.22))
        path.closeSubpath()
    }

    /// A standing stone, wider at the foot.
    private func appendStele(
        _ path: inout Path, centreX: CGFloat, baseY: CGFloat, unit: CGFloat
    ) {
        let height = unit * 0.62
        path.move(to: CGPoint(x: centreX - unit * 0.20, y: baseY))
        path.addLine(to: CGPoint(x: centreX - unit * 0.13, y: baseY - height))
        path.addLine(to: CGPoint(x: centreX + unit * 0.13, y: baseY - height))
        path.addLine(to: CGPoint(x: centreX + unit * 0.20, y: baseY))
        path.closeSubpath()
    }

    /// A stone post, a cap, and the paper box between them.
    private func appendLantern(
        _ parts: inout LandmarkPaths, centreX: CGFloat, baseY: CGFloat, unit: CGFloat
    ) {
        parts.stone.addRect(CGRect(x: centreX - unit * 0.07, y: baseY - unit * 0.72,
                                   width: unit * 0.14, height: unit * 0.72))
        parts.stone.addRect(CGRect(x: centreX - unit * 0.26, y: baseY - unit * 1.24,
                                   width: unit * 0.52, height: unit * 0.14))
        parts.flame.addRect(CGRect(x: centreX - unit * 0.18, y: baseY - unit * 1.1,
                                   width: unit * 0.36, height: unit * 0.38))
    }

    /// A pole with a hanging strip of cloth, notched at the bottom.
    private func appendBanner(
        _ parts: inout LandmarkPaths, centreX: CGFloat, baseY: CGFloat, unit: CGFloat
    ) {
        parts.stone.addRect(CGRect(x: centreX - unit * 0.045, y: baseY - unit * 2.1,
                                   width: unit * 0.09, height: unit * 2.1))
        let top = baseY - unit * 2.0
        let width = unit * 0.44
        parts.lacquer.move(to: CGPoint(x: centreX, y: top))
        parts.lacquer.addLine(to: CGPoint(x: centreX + width, y: top))
        parts.lacquer.addLine(to: CGPoint(x: centreX + width, y: top + unit * 0.95))
        parts.lacquer.addLine(to: CGPoint(x: centreX + width / 2, y: top + unit * 0.78))
        parts.lacquer.addLine(to: CGPoint(x: centreX, y: top + unit * 0.95))
        parts.lacquer.closeSubpath()
    }

    /// The watchtower's light: a disc with a halo, and two rays after dark.
    private func drawBeacon(at spot: CGPoint, unit: CGFloat,
                            into context: inout GraphicsContext) {
        let radius = unit * 0.26
        context.fill(
            Path(ellipseIn: CGRect(
                x: spot.x - radius * 5, y: spot.y - radius * 5,
                width: radius * 10, height: radius * 10)),
            with: .radialGradient(
                Gradient(colors: [
                    palette.lanternColor.opacity(palette.onDark ? 0.42 : 0.22),
                    palette.lanternColor.opacity(0)
                ]),
                center: spot, startRadius: 0, endRadius: radius * 5))
        context.fill(
            Path(ellipseIn: CGRect(
                x: spot.x - radius, y: spot.y - radius,
                width: radius * 2, height: radius * 2)),
            with: .color(palette.lanternColor))
    }
}

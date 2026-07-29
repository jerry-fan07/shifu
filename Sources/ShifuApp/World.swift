import SwiftUI

/// The map the whole app is set on (design.md §7): **one** mountain, climbed
/// left to right, with a stone terrace and a temple for every place in the app.
///
/// The app does not swap screens — it moves the camera over this map. Today is
/// the camp at the foot; Radar is the watchtower at the summit; the flights of
/// steps between them are the same steps Shifu hops up when you change places.
/// That means terrace heights, the silhouette of the mountain, the treads that
/// catch the light, and where Shifu puts his feet all come out of the numbers
/// below — there is no second copy of the terrain anywhere.
enum WorldMap {
    /// World units. At rest one unit is about one point on an 800 pt window,
    /// so these read as "how big on screen".
    static let firstStationX: CGFloat = 560
    static let stationSpacing: CGFloat = 700
    /// The altitude of the lowest terrace. Larger y is lower down.
    static let footY: CGFloat = 1_240
    /// How much higher each terrace sits than the one below it.
    static let rise: CGFloat = 150
    static let terraceHalfWidth: CGFloat = 210
    /// Treads in one flight of steps. Four over 280 units gives a 70 × 30
    /// stone — broad temple steps rather than a staircase.
    static let treadsPerFlight = 4
    /// How far above the terrace the camera aims, so a temple has sky over it
    /// and the mountain it is cut into does not fill half the window.
    static let eyeHeight: CGFloat = 112
    /// World units of height the window shows once the camera has settled.
    /// Wide enough that Shifu is a figure on a mountain rather than a mascot
    /// filling a frame — you should have to find him.
    static let restingSpan: CGFloat = 940
    /// Extra span at the midpoint of a move. The camera pulls back as it
    /// travels and settles again on arrival, which is what makes a change of
    /// place read as a journey instead of a jump cut.
    static let travelPullback: CGFloat = 0.42

    static var flightWidth: CGFloat { stationSpacing - terraceHalfWidth * 2 }
    static var treadWidth: CGFloat { flightWidth / CGFloat(treadsPerFlight) }
    /// One riser. The flight climbs in `treadsPerFlight` equal steps and the
    /// terrace itself is the last one, hence the + 1.
    static var riserHeight: CGFloat { rise / CGFloat(treadsPerFlight + 1) }

    static func stationX(_ index: Int) -> CGFloat {
        firstStationX + CGFloat(index) * stationSpacing
    }

    static func terraceY(_ index: Int) -> CGFloat {
        footY - CGFloat(index) * rise
    }

    static func camera(for destination: Destination) -> Camera {
        let index = destination.stationIndex
        return Camera(
            target: CGPoint(x: stationX(index), y: terraceY(index) - eyeHeight),
            span: restingSpan)
    }

    /// One flat run of stone: a terrace top, or one tread of a flight.
    struct Run {
        let minX: CGFloat
        let maxX: CGFloat
        let topY: CGFloat
    }

    /// Every run between two world x, in order. The single source of truth for
    /// the silhouette, the lit treads, and `groundY`.
    static func runs(from minX: CGFloat, to maxX: CGFloat) -> [Run] {
        let first = Int(((minX - firstStationX) / stationSpacing).rounded(.down)) - 1
        let last = Int(((maxX - firstStationX) / stationSpacing).rounded(.up)) + 1
        var runs: [Run] = []
        runs.reserveCapacity((last - first + 1) * (treadsPerFlight + 1))
        for index in first...last {
            let centre = stationX(index)
            let top = terraceY(index)
            runs.append(Run(minX: centre - terraceHalfWidth, maxX: centre + terraceHalfWidth,
                            topY: top))
            let flightStart = centre + terraceHalfWidth
            for step in 0..<treadsPerFlight {
                runs.append(Run(
                    minX: flightStart + CGFloat(step) * treadWidth,
                    maxX: flightStart + CGFloat(step + 1) * treadWidth,
                    topY: top - riserHeight * CGFloat(step + 1)))
            }
        }
        return runs
    }

    /// The height of the stone under a world x — where a foot lands.
    static func groundY(at worldX: CGFloat) -> CGFloat {
        let nearest = Int(((worldX - firstStationX) / stationSpacing).rounded())
        if abs(worldX - stationX(nearest)) <= terraceHalfWidth { return terraceY(nearest) }
        let lower = worldX > stationX(nearest) ? nearest : nearest - 1
        let into = worldX - (stationX(lower) + terraceHalfWidth)
        let step = min(treadsPerFlight - 1, max(0, Int(into / treadWidth)))
        return terraceY(lower) - riserHeight * CGFloat(step + 1)
    }

    /// 0 at the foot of the mountain, 1 at the summit terrace — drives the
    /// things that should only happen high up, like the sea of cloud.
    static func altitude(of cameraY: CGFloat) -> CGFloat {
        let climbed = (footY - eyeHeight) - cameraY
        return min(1, max(0, climbed / (rise * CGFloat(max(1, Destination.allCases.count - 1)))))
    }
}

// MARK: - The camera

/// Where the window is looking. `target` is the world point that lands on the
/// screen anchor; `span` is how many world units of height the window shows.
struct Camera: Equatable {
    var target: CGPoint
    var span: CGFloat
}

/// World → screen for one frame.
///
/// Background ranges move slower than the ground (`parallax`) but keep their
/// size: only the camera's travel is attenuated, never the geometry. Vertical
/// motion gets its own, gentler `drift` — a literal parallax on the climb would
/// drop the whole range off the bottom of the frame two terraces up, and the
/// point of climbing is to watch the horizon sink slowly, not to lose it.
struct Projection {
    let camera: Camera
    let size: CGSize
    let anchor: UnitPoint

    var scale: CGFloat { size.height / camera.span }

    var anchorPoint: CGPoint {
        CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
    }

    /// A point on the ground plane, where parallax is 1.
    func point(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: anchorPoint.x + (world.x - camera.target.x) * scale,
            y: anchorPoint.y + (world.y - camera.target.y) * scale)
    }

    /// The world x showing at a screen x, for sampling a procedural skyline
    /// straight across the window.
    func worldX(atScreen screenX: CGFloat, parallax: CGFloat) -> CGFloat {
        (screenX - anchorPoint.x) / scale + camera.target.x * parallax
    }

    func baselineY(_ range: Ridgeline.Range) -> CGFloat {
        anchorPoint.y
            + (range.baseY - camera.target.y) * range.drift * scale
            + range.screenOffset * size.height
    }
}

// MARK: - Procedural skylines

/// The ranges behind the mountain, sampled straight from world x — so a ridge
/// is endless in both directions and never has to be tiled or clipped.
enum Ridgeline {
    struct Range {
        let parallax: CGFloat
        /// World altitude the range is measured from.
        var baseY: CGFloat = WorldMap.footY
        /// Share of the camera's climb this range takes. Small for far things.
        let drift: CGFloat
        /// Nudge in screen heights, for the foreground bank that is pinned to
        /// the bottom of the window rather than to any altitude.
        var screenOffset: CGFloat = 0
        /// World units from the baseline to a full summit.
        let amplitude: CGFloat
        let period: CGFloat
        let seed: CGFloat
        let colorIndex: Int
        /// Angular peaks read as mountains; rolling ones read as hills.
        let angular: Bool
    }

    /// Far → near. Three ranges plus the near bank is the most depth flat
    /// colour can carry before the planes stop reading as separate.
    static let ranges = [
        Range(parallax: 0.14, drift: 0.06, screenOffset: -0.02,
              amplitude: 430, period: 520, seed: 0.7, colorIndex: 0, angular: true),
        Range(parallax: 0.34, drift: 0.12,
              amplitude: 340, period: 380, seed: 2.9, colorIndex: 1, angular: true),
        Range(parallax: 0.62, drift: 0.22, screenOffset: 0.02,
              amplitude: 300, period: 340, seed: 5.1, colorIndex: 2, angular: false)
    ]

    /// The bank in front of everything, including Shifu — drawn last, moving
    /// fastest, which is where most of the sense of speed comes from. It is
    /// also what keeps the bottom of the window from being a flat wedge of
    /// stone, so it is pinned to the frame rather than to an altitude.
    static let foreground = Range(
        parallax: 1.35, drift: 0, screenOffset: 0.44,
        amplitude: 170, period: 420, seed: 3.3, colorIndex: 4, angular: false)

    static func profile(_ range: Range, at worldX: CGFloat) -> CGFloat {
        range.angular
            ? peaks(worldX, period: range.period, seed: range.seed)
            : hills(worldX, period: range.period, seed: range.seed)
    }

    /// A triangle per cell, its summit from a hash of the cell index, over a
    /// floor so the valleys never cut back to the baseline.
    private static func peaks(_ worldX: CGFloat, period: CGFloat, seed: CGFloat) -> CGFloat {
        let unit = worldX / period + seed
        let cell = unit.rounded(.down)
        let into = unit - cell
        let summit = 0.42 + 0.58 * hash(cell + seed)
        return 0.26 + 0.74 * summit * (1 - abs(into * 2 - 1))
    }

    /// Three sines whose periods share no common factor, so the hills never
    /// visibly repeat however far you walk.
    private static func hills(_ worldX: CGFloat, period: CGFloat, seed: CGFloat) -> CGFloat {
        0.5
            + 0.24 * sin(worldX / period + seed)
            + 0.14 * sin(worldX / (period * 0.37) + seed * 2.7)
            + 0.12 * sin(worldX / (period * 2.31) + seed * 0.6)
    }

    private static func hash(_ value: CGFloat) -> CGFloat {
        let raw = sin(value * 12.9898) * 43_758.5453
        return raw - raw.rounded(.down)
    }
}

// MARK: - What is built on a terrace

/// A handful of parts, combined differently per place — enough for seven
/// distinct silhouettes without drawing seven buildings.
struct Landmark {
    /// Stacked pagoda roofs. One is a shrine, four is a watchtower.
    var tiers = 1
    /// Widens the hall under the roofs without making it taller.
    var hallWidth: CGFloat = 1
    /// A vermilion gate on the terrace edge.
    var torii = false
    /// Standing stones in front of the hall.
    var steles = 0
    /// A banner on a pole, which is the only thing here that moves.
    var banner = false
    /// A light at the top, lit at dusk and night.
    var beacon = false
    var lanterns = 2
}

extension Destination {
    /// Where the place sits on the climb: Today at the foot, Radar at the
    /// summit, in the order the trail lists them.
    var stationIndex: Int { Destination.allCases.firstIndex(of: self) ?? 0 }

    /// The buildings get taller as you climb, so altitude alone tells you how
    /// far into the app you are.
    var landmark: Landmark {
        switch self {
        case .today: return Landmark(tiers: 1, hallWidth: 1.15, banner: true, lanterns: 1)
        case .time: return Landmark(tiers: 1, torii: true, lanterns: 1)
        case .themes: return Landmark(tiers: 2, steles: 3, lanterns: 1)
        case .tasks: return Landmark(tiers: 1, hallWidth: 1.9, steles: 2, lanterns: 1)
        case .practice: return Landmark(tiers: 2, hallWidth: 1.5, banner: true, lanterns: 1)
        case .scrolls: return Landmark(tiers: 3)
        case .radar: return Landmark(tiers: 4, beacon: true)
        }
    }
}

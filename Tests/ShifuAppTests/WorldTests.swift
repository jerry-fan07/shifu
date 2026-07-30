import Foundation
import SwiftUI
import Testing
@testable import ShifuApp

/// The mountain (design.md §7). `WorldMap.runs` is documented as "the single
/// source of truth for the silhouette, the lit treads, and `groundY`" — so the
/// thing worth testing is that those really are one geometry and not two that
/// happen to look alike, plus that the arithmetic survives the degenerate
/// frames SwiftUI hands a `Canvas`.
@Suite struct WorldMapTests {
    @Test func terracesClimbAndAreEvenlySpaced() {
        #expect(WorldMap.terraceY(0) == WorldMap.footY)
        #expect(WorldMap.terraceY(1) == WorldMap.footY - WorldMap.rise)
        #expect(WorldMap.stationX(1) - WorldMap.stationX(0) == WorldMap.stationSpacing)
    }

    /// The flight has to land exactly on the next terrace: the terrace is the
    /// last step, which is why `riserHeight` divides by `treadsPerFlight + 1`.
    @Test func aFlightOfStepsLandsExactlyOnTheNextTerrace() {
        let climbed = WorldMap.riserHeight * CGFloat(WorldMap.treadsPerFlight + 1)
        #expect(abs(climbed - WorldMap.rise) < 0.0001)
    }

    @Test func runsTileTheGroundWithoutGapsOrOverlaps() {
        let runs = WorldMap.runs(from: 0, to: 3_000)
        #expect(runs.count > 1)
        for (lower, upper) in zip(runs, runs.dropFirst()) {
            #expect(abs(lower.maxX - upper.minX) < 0.0001, "gap or overlap at \(lower.maxX)")
        }
    }

    /// The claim the whole scene rests on: Shifu's feet and the painted stone
    /// come from the same numbers.
    @Test func groundYAgreesWithTheRunItFallsIn() {
        let runs = WorldMap.runs(from: 0, to: 2_500)
        for run in runs {
            for sample in [0.1, 0.5, 0.9] {
                let worldX = run.minX + (run.maxX - run.minX) * sample
                #expect(abs(WorldMap.groundY(at: worldX) - run.topY) < 0.0001,
                        "foot at \(worldX) lands off the stone under it")
            }
        }
    }

    @Test func theGroundNeverRisesGoingLeft() {
        let heights = stride(from: CGFloat(0), to: 3_000, by: 17)
            .map { WorldMap.groundY(at: $0) }
        // Larger y is lower down, so a climb is a non-increasing sequence.
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// SwiftUI lays a `Canvas` out at zero size while a window comes up, which
    /// makes the projection report ±infinity. `Int(_: Double)` traps on those.
    @Test func aDegenerateFrameYieldsNoRunsInsteadOfTrapping() {
        #expect(WorldMap.runs(from: -.infinity, to: .infinity).isEmpty)
        #expect(WorldMap.runs(from: .nan, to: .nan).isEmpty)
        #expect(WorldMap.runs(from: 1_000, to: 0).isEmpty)   // reversed
    }

    @Test func groundYIsFiniteForANonFiniteX() {
        #expect(WorldMap.groundY(at: .infinity) == WorldMap.footY)
        #expect(WorldMap.groundY(at: .nan) == WorldMap.footY)
    }

    @Test func altitudeRunsFromZeroAtTheFootToOneAtTheSummit() {
        let foot = WorldMap.camera(for: .today)
        let summit = WorldMap.camera(for: .radar)
        #expect(WorldMap.altitude(of: foot.target.y) == 0)
        #expect(WorldMap.altitude(of: summit.target.y) == 1)
        #expect(WorldMap.altitude(of: -100_000) == 1)    // clamped, never over
        #expect(WorldMap.altitude(of: 100_000) == 0)
    }

    @Test func everyDestinationHasItsOwnStationInTrailOrder() {
        let indices = Destination.allCases.map(\.stationIndex)
        #expect(indices == Array(0..<Destination.allCases.count))
    }

    @Test func theCameraAimsAboveTheTerraceItIsParkedOn() {
        for destination in Destination.allCases {
            let camera = WorldMap.camera(for: destination)
            #expect(camera.target.x == WorldMap.stationX(destination.stationIndex))
            #expect(camera.target.y < WorldMap.terraceY(destination.stationIndex))
            #expect(camera.span == WorldMap.restingSpan)
        }
    }
}

@Suite struct ProjectionTests {
    private static func projection(
        size: CGSize = CGSize(width: 800, height: 600),
        span: CGFloat = WorldMap.restingSpan
    ) -> Projection {
        Projection(
            camera: Camera(target: CGPoint(x: 1_000, y: 500), span: span),
            size: size, anchor: .center)
    }

    @Test func theCameraTargetLandsOnTheAnchor() {
        let projection = Self.projection()
        let point = projection.point(projection.camera.target)
        #expect(abs(point.x - projection.anchorPoint.x) < 0.0001)
        #expect(abs(point.y - projection.anchorPoint.y) < 0.0001)
    }

    @Test func worldXRoundTripsThroughTheGroundPlane() {
        let projection = Self.projection()
        let worldX = projection.worldX(atScreen: 250, parallax: 1)
        let screen = projection.point(CGPoint(x: worldX, y: 0))
        #expect(abs(screen.x - 250) < 0.0001)
    }

    /// A zero-height frame used to make `scale` zero and every world x
    /// infinite, which took the window down inside `WorldMap.runs`.
    @Test func aZeroSizedFrameStaysFinite() {
        let flat = Self.projection(size: CGSize(width: 800, height: 0))
        #expect(flat.scale == 0)
        #expect(flat.worldX(atScreen: -60, parallax: 1).isFinite)
        #expect(flat.worldX(atScreen: 900, parallax: 0.1).isFinite)
        // The painter's own call, which is where the trap used to happen.
        let runs = WorldMap.runs(from: flat.worldX(atScreen: -60, parallax: 1),
                                 to: flat.worldX(atScreen: 860, parallax: 1))
        #expect(runs.allSatisfy { $0.topY.isFinite })
    }

    @Test func aZeroSpanCameraStaysFinite() {
        let collapsed = Self.projection(span: 0)
        #expect(collapsed.scale == 0)
        #expect(collapsed.worldX(atScreen: 100, parallax: 1).isFinite)
    }
}

@Suite struct RidgelineTests {
    @Test func everyRangeProfileStaysInAPaintableBand() {
        for range in Ridgeline.ranges + [Ridgeline.foreground] {
            for worldX in stride(from: CGFloat(-5_000), through: 5_000, by: 61) {
                let height = Ridgeline.profile(range, at: worldX)
                #expect(height.isFinite)
                #expect(height > -0.1 && height < 1.6, "profile \(height) at \(worldX)")
            }
        }
    }

    @Test func rangesAreOrderedFarToNear() {
        let parallaxes = Ridgeline.ranges.map(\.parallax)
        #expect(parallaxes == parallaxes.sorted())
        // The near bank moves faster than anything behind it, including Shifu.
        #expect(Ridgeline.foreground.parallax > parallaxes.last!)
    }

    @Test func theProfileIsDeterministic() {
        let first = Ridgeline.profile(Ridgeline.ranges[0], at: 1_234)
        #expect(Ridgeline.profile(Ridgeline.ranges[0], at: 1_234) == first)
    }
}

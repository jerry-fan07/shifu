import Testing
@testable import ShifuCore

@Suite struct SessionizerTests {
    private func obs(
        id: Int64, start: Int64, seen: Int64? = nil, bundle: String,
        title: String? = nil, url: String? = nil, kind: CaptureKind = .ax
    ) -> Observation {
        Observation(id: id, startedAt: start, lastSeen: seen, appBundle: bundle,
                    windowTitle: title, url: url, captureKind: kind)
    }

    @Test func contiguousSameAppFoldsIntoOneBlock() {
        let blocks = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 50_000, bundle: "com.apple.dt.Xcode", title: "A"),
            obs(id: 2, start: 60_000, seen: 110_000, bundle: "com.apple.dt.Xcode", title: "B")
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].startedAt == 0)
        #expect(blocks[0].endedAt == 110_000)
        #expect(blocks[0].observationIDs == [1, 2])
        #expect(blocks[0].titles == ["A", "B"])
    }

    @Test func idleGapSplitsBlock() {
        let blocks = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 30_000, bundle: "com.apple.dt.Xcode"),
            obs(id: 2, start: 30_000 + 121_000, bundle: "com.apple.dt.Xcode")
        ])
        #expect(blocks.count == 2)
        // Idle time is credited to neither block.
        #expect(blocks[0].endedAt == 30_000)
    }

    @Test func appSwitchClosesBlockAndCreditsIntervalToOldBlock() {
        let blocks = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 10_000, bundle: "com.apple.dt.Xcode"),
            obs(id: 2, start: 40_000, bundle: "com.apple.Safari", url: "https://github.com/x")
        ])
        #expect(blocks.count == 2)
        // User stayed in Xcode until the switch at 40s.
        #expect(blocks[0].endedAt == 40_000)
        #expect(blocks[1].domain == "github.com")
    }

    @Test func differentDomainsSplitBrowserBlocks() {
        let blocks = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 5_000, bundle: "com.apple.Safari",
                url: "https://www.github.com/a"),
            obs(id: 2, start: 10_000, seen: 20_000, bundle: "com.apple.Safari",
                url: "https://youtube.com/watch"),
            obs(id: 3, start: 25_000, seen: 30_000, bundle: "com.apple.Safari",
                url: "https://youtube.com/other")
        ])
        #expect(blocks.count == 2)
        #expect(blocks[0].domain == "github.com")   // www. stripped
        #expect(blocks[1].domain == "youtube.com")
        #expect(blocks[1].observationIDs == [2, 3])
    }

    @Test func excludedFlagOnlyWhenAllObservationsExcluded() {
        let blocks = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 5_000, bundle: "com.1password.1password", kind: .excluded),
            obs(id: 2, start: 6_000, seen: 9_000, bundle: "com.1password.1password", kind: .excluded)
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].excluded)

        let mixed = Sessionizer.sessionize([
            obs(id: 1, start: 0, seen: 5_000, bundle: "com.apple.Safari", kind: .excluded),
            obs(id: 2, start: 6_000, seen: 9_000, bundle: "com.apple.Safari", kind: .ax)
        ])
        #expect(mixed.count == 1)
        #expect(!mixed[0].excluded)
    }

    @Test func emptyInputYieldsNoBlocks() {
        #expect(Sessionizer.sessionize([]).isEmpty)
    }

    @Test func syntheticDayReducesSanely() {
        // 8 h alternating between 3 apps every ~5 min with heartbeat updates:
        // should fold to roughly the number of app visits, not observations.
        var observations: [Observation] = []
        var id: Int64 = 1
        let apps = ["com.apple.dt.Xcode", "com.apple.Safari", "com.tinyspeck.slackmacgap"]
        var time: Int64 = 0
        while time < 8 * 3_600_000 {
            let bundle = apps[Int(time / 300_000) % apps.count]
            observations.append(obs(id: id, start: time, seen: time + 50_000, bundle: bundle))
            id += 1
            time += 60_000
        }
        let blocks = Sessionizer.sessionize(observations)
        let visits = 8 * 12  // one app visit per 5-minute slot
        #expect(blocks.count == visits)
        // Total block time ≈ 8 h (continuous switching, no idle).
        let total = blocks.reduce(Int64(0)) { $0 + $1.durationMs }
        #expect(total > 7 * 3_600_000 && total <= 8 * 3_600_000 + 60_000)
    }
}

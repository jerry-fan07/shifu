import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct DigestGeneratorTests {
    @Test func rendersBreakdownAndAnomaly() {
        let markdown = DigestGenerator.render(.init(
            date: Date(timeIntervalSince1970: 1_752_700_000),
            totals: [.work: 14_400_000, .social: 7_200_000],
            topBlocks: [DigestGenerator.TopBlock(label: "github.com", category: .work, ms: 3_600_000)],
            topics: ["debugging shifu daemon"],
            weekAverages: [.work: 14_400_000, .social: 1_800_000]
        ))
        #expect(markdown.contains("**work**: 4.0 h"))
        #expect(markdown.contains("**social**: 2.0 h"))
        #expect(markdown.contains("4.0× your daily average"))   // 2h vs 30min avg
        #expect(!markdown.contains("work**: 4.0 h  ⚠️"))         // work is at its average
        #expect(markdown.contains("github.com"))
        #expect(markdown.contains("debugging shifu daemon"))
    }

    /// The digest is the one thing that has to land in the real `~/Shifu`
    /// layout, so this case moves `SHIFU_HOME` — through `ShifuHomeOverride`,
    /// because that variable is process-global and another suite moving it
    /// mid-test is enough to make `generate` write somewhere this can't read.
    @Test func generateWritesFileOncePerDay() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-digest-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try ShifuHomeOverride.with(scratch.path) {
            let db = try ShifuDatabase.inMemory()
            let dayStart = Calendar.current.startOfDay(for: Date())
            let base = Int64(dayStart.timeIntervalSince1970 * 1_000)
            try db.queue.write { sqlite in
                var activity = Activity(
                    startedAt: base + 3_600_000, endedAt: base + 7_200_000,
                    appBundle: "com.apple.dt.Xcode", category: .work, topic: "shifu phase 3")
                try activity.insert(sqlite)
            }

            let first = try #require(try DigestGenerator.generate(database: db))
            let contents = try String(contentsOf: first, encoding: .utf8)
            #expect(contents.contains("**work**: 1.0 h"))
            #expect(contents.contains("shifu phase 3"))

            // Second run same day: idempotent, no rewrite.
            let second = try DigestGenerator.generate(database: db)
            #expect(second == nil)
        }
    }
}

import Foundation
import ShifuCore
import Testing
@testable import shifu_cli

/// The CLI's parsing and formatting helpers. Everything here is reachable by
/// typing at a prompt, so the failure mode for a bad parse is a user deleting
/// the wrong data or reading a wrong number — worth pinning even though the
/// functions are small.
@Suite struct ForgetRangeTests {
    @Test func everyUnitTheUsageLineAdvertises() {
        #expect(parseForgetRangeSpec("30m") == 1_800)
        #expect(parseForgetRangeSpec("2h") == 7_200)
        #expect(parseForgetRangeSpec("1d") == 86_400)
        #expect(parseForgetRangeSpec("7d") == 604_800)
    }

    @Test func fractionalAmountsAreAccepted() {
        #expect(parseForgetRangeSpec("1.5h") == 5_400)
    }

    /// `shifu forget last <spec>` deletes captured data. A spec that isn't
    /// understood must be nil so the command can refuse — never a default.
    @Test func anythingUnrecognizedIsRefusedRatherThanGuessed() {
        for junk in ["", "h", "d", "2", "2w", "2y", "two hours", "-", "2 h", "h2"] {
            #expect(parseForgetRangeSpec(junk) == nil, "'\(junk)' should not parse")
        }
    }

    /// Both callers subtract this from *now*, so a negative or zero amount
    /// builds a window that runs backwards from the future — which deletes
    /// nothing and still reports success.
    @Test func negativeAndZeroRangesAreRefused() {
        #expect(parseForgetRangeSpec("-3d") == nil)
        #expect(parseForgetRangeSpec("-1h") == nil)
        #expect(parseForgetRangeSpec("0d") == nil)
        #expect(parseForgetRangeSpec("infd") == nil)
    }
}

/// Captured screen text goes into the export verbatim. A fence shorter than a
/// backtick run inside the text lets that text break out of the code block and
/// become Markdown — which is how OCR'd content ends up rendering as headings
/// and links in the user's own log file.
@Suite struct FencedBlockTests {
    private func fenceLength(_ output: String) -> Int {
        output.prefix { $0 == "`" }.count
    }

    @Test func plainTextGetsTheOrdinaryThreeBacktickFence() {
        let block = fencedBlock("just some text")
        #expect(fenceLength(block) == 3)
        #expect(block.hasPrefix("```text\n"))
        #expect(block.hasSuffix("\n```"))
    }

    @Test func theFenceAlwaysOutgrowsTheLongestBacktickRunInside() {
        for run in 1...8 {
            let text = "before " + String(repeating: "`", count: run) + " after"
            let block = fencedBlock(text)
            #expect(fenceLength(block) > run, "run of \(run) escaped its fence")
            #expect(fenceLength(block) >= 3)
        }
    }

    @Test func theLongestRunWinsNotTheLastOne() {
        let block = fencedBlock("`` a ````` b ```")
        #expect(fenceLength(block) == 6)
    }

    @Test func theTextItselfIsCarriedThroughUnchanged() {
        let text = "line one\n``` not a fence\nline two"
        #expect(fencedBlock(text).contains(text))
    }

    @Test func emptyTextStillProducesAWellFormedBlock() {
        #expect(fencedBlock("") == "```text\n\n```")
    }
}

@Suite struct DurationFormattingTests {
    @Test func secondsMinutesAndHoursEachGetTheirOwnShape() {
        #expect(formatDuration(0) == "0s")
        #expect(formatDuration(45_000) == "45s")
        #expect(formatDuration(60_000) == "1m")
        #expect(formatDuration(90_000) == "1m30s")
        #expect(formatDuration(3_600_000) == "1h0m")
        #expect(formatDuration(5_430_000) == "1h30m")
    }

    @Test func aWholeNumberOfMinutesOmitsTheSeconds() {
        #expect(formatDuration(300_000) == "5m")
        #expect(!formatDuration(300_000).contains("0s"))
    }
}

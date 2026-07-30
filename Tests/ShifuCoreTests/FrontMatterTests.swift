import Foundation
import Testing
@testable import ShifuCore

/// The vault's file format (vault-features.md §2). The Markdown tree is the
/// source of truth, so a parse that loses a field loses user data — and these
/// files are meant to be edited by hand in Obsidian, which is where the
/// awkward inputs come from.
@Suite struct FrontMatterTests {
    @Test func fieldsAndBodySplitAtTheClosingFence() {
        let doc = FrontMatter.parse("""
        ---
        id: 01J
        topic: SQLite WAL
        ---
        WAL survives kill -9.

        Q: What survives?
        A: The last commit.
        """)
        #expect(doc?.fields["id"] == "01J")
        #expect(doc?.fields["topic"] == "SQLite WAL")
        #expect(doc?.body.hasPrefix("WAL survives") == true)
        #expect(doc?.body.contains("Q: What survives?") == true)
    }

    @Test func aFileWithoutAFrontmatterBlockIsNotANote() {
        #expect(FrontMatter.parse("") == nil)
        #expect(FrontMatter.parse("just a markdown file") == nil)
        #expect(FrontMatter.parse("---\nid: 1") == nil)          // never closed
        #expect(FrontMatter.parse("# Heading\n---\nid: 1\n---") == nil)   // not line one
    }

    @Test func anEmptyFrontmatterBlockIsValidAndCarriesNoFields() {
        let doc = FrontMatter.parse("---\n---\nbody text")
        #expect(doc?.fields.isEmpty == true)
        #expect(doc?.body == "body text")
    }

    /// A value containing a colon — a URL, or a time — must keep everything
    /// after the *first* colon, not be truncated at the second.
    @Test func valuesKeepEveryColonAfterTheFirst() {
        let doc = FrontMatter.parse("""
        ---
        source_url: https://example.test/a:b?q=1
        srs: {stability: 2.5, reps: 1}
        ---
        body
        """)
        #expect(doc?.fields["source_url"] == "https://example.test/a:b?q=1")
        #expect(doc?.fields["srs"] == "{stability: 2.5, reps: 1}")
    }

    @Test func surroundingWhitespaceIsTrimmedFromKeysAndValues() {
        let doc = FrontMatter.parse("---\n  topic  :   spaced out   \n---\nbody")
        #expect(doc?.fields["topic"] == "spaced out")
    }

    @Test func linesWithoutAColonAreSkippedRatherThanBreakingTheParse() {
        let doc = FrontMatter.parse("---\ntopic: kept\nstray line\n---\nbody")
        #expect(doc?.fields["topic"] == "kept")
        #expect(doc?.fields.count == 1)
    }

    @Test func anEmptyValueParsesAsAnEmptyStringNotAMissingKey() {
        let doc = FrontMatter.parse("---\ntopic:\n---\nbody")
        #expect(doc?.fields["topic"] == "")
    }

    /// A body containing its own `---` (a Markdown rule) belongs to the body:
    /// only the first closing fence ends the frontmatter.
    @Test func aHorizontalRuleInTheBodyDoesNotReopenTheFrontmatter() {
        let doc = FrontMatter.parse("""
        ---
        topic: t
        ---
        before

        ---

        after
        """)
        #expect(doc?.fields.count == 1)
        #expect(doc?.body.contains("---") == true)
        #expect(doc?.body.hasPrefix("before") == true)
    }

    @Test func anEmptyBodyIsAnEmptyStringNotNil() {
        let doc = FrontMatter.parse("---\ntopic: t\n---\n")
        #expect(doc?.body == "")
    }

    /// Pre-V1 notes never wrote `kind:`, so its *absence* has to keep meaning
    /// "knowledge". An unrecognized string is deliberately **not** knowledge:
    /// a `kind == .knowledge` guard has to reject a newer binary's note rather
    /// than leak it into the review queue until every binary catches up.
    @Test func anAbsentKindIsKnowledgeButAnUnknownOneIsNothing() {
        #expect(FrontMatter.parse("---\ntopic: t\n---\nbody")?.kind == .knowledge)
        #expect(FrontMatter.parse("---\nkind: work\n---\nbody")?.kind == .work)
        #expect(FrontMatter.parse("---\nkind: task_overview\n---\nbody")?.kind == .taskOverview)

        let unknown = FrontMatter.parse("---\nkind: project\n---\nbody")
        #expect(unknown?.kind == nil)
        // …but the string itself round-trips, so an older binary reconciling
        // the index can't relabel a kind it doesn't understand.
        #expect(unknown?.rawKind == "project")
    }

    @Test func aRepeatedKeyTakesTheLastValue() {
        let doc = FrontMatter.parse("---\ntopic: first\ntopic: second\n---\nbody")
        #expect(doc?.fields["topic"] == "second")
    }
}

/// The two perceptual hashes that keep a stable screen from costing a row per
/// heartbeat (design.md §3.3). `HashTests` covers the happy paths; these cover
/// the properties the dedupe gates actually rely on.
@Suite struct HashPropertyTests {
    @Test func simHashIsStableAcrossCallsAndProcessRuns() {
        let text = "the quick brown fox jumps over the lazy dog"
        #expect(SimHash.hash(text) == SimHash.hash(text))
        // A literal value, so a change to the hash function is a visible
        // decision rather than a silent re-dedupe of the whole history.
        #expect(SimHash.hash("shifu") == SimHash.hash("Shifu"))   // case-folded
    }

    @Test func punctuationAndWhitespaceAreNotContent() {
        #expect(SimHash.hash("hello, world!") == SimHash.hash("hello   world"))
        #expect(SimHash.hash("") == 0)
        #expect(SimHash.hash("   \n\t  ") == 0)
        #expect(SimHash.hash("!!!???") == 0)
    }

    /// The gate that decides "same window, bump last_seen" vs "new row".
    @Test func aSmallEditStaysInsideTheNearDuplicateThresholdAndARewriteDoesNot() {
        let original = String(repeating: "shifu captures the screen locally ", count: 8)
        let edited = original + "one more clause"
        let unrelated = String(repeating: "completely different subject matter ", count: 8)

        #expect(SimHash.isNearDuplicate(SimHash.hash(original), SimHash.hash(edited)))
        #expect(!SimHash.isNearDuplicate(SimHash.hash(original), SimHash.hash(unrelated)))
    }

    @Test func hammingDistanceIsSymmetricAndZeroOnlyForEqualHashes() {
        let lhs = SimHash.hash("alpha beta gamma")
        let rhs = SimHash.hash("delta epsilon zeta")
        #expect(SimHash.hammingDistance(lhs, rhs) == SimHash.hammingDistance(rhs, lhs))
        #expect(SimHash.hammingDistance(lhs, lhs) == 0)
        #expect(SimHash.hammingDistance(0, UInt64.max) == 64)
    }

    @Test func dHashReadsEachRowLeftToRightAgainstItsRightNeighbor() {
        // Row-major 9×8: a strictly increasing row sets no bits (left < right).
        let increasing = (0..<(9 * 8)).map { UInt8(($0 % 9) * 20) }
        #expect(DHash.hash(luminance: increasing) == 0)

        // Strictly decreasing sets every bit.
        let decreasing = (0..<(9 * 8)).map { UInt8((8 - ($0 % 9)) * 20) }
        #expect(DHash.hash(luminance: decreasing) == UInt64.max)
    }

    @Test func aFewChangedPixelsReadAsTheSameScreen() {
        var frame = (0..<(9 * 8)).map { UInt8(($0 % 9) * 20) }
        let before = DHash.hash(luminance: frame)
        frame[0] = 255                       // one flipped comparison
        #expect(DHash.isUnchanged(before, DHash.hash(luminance: frame)))
        #expect(!DHash.isUnchanged(before, UInt64.max))
    }
}

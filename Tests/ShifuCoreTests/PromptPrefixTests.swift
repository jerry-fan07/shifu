import Foundation
import Testing
@testable import ShifuCore

/// Cache-prefix alignment (design.md §12). A provider's context cache
/// discounts only the longest byte-identical *prefix* a prompt shares with a
/// recent one, rounded down to a 128-token block — so a stage whose prompts
/// diverge in their first line pays full price on every call, however much
/// text they otherwise have in common. That failure is invisible: the prompts
/// are correct, the answers are correct, and the only symptom is a column in
/// `llm_usage` reading zero.
///
/// These tests pin the property the prompt builders were reordered to get:
/// two calls of one stage that differ only in what moves between calls share
/// a prefix worth at least one cache block. They are pure string assertions —
/// no backend, no network — following `DeepSeekBackend.requestBody`, which is
/// split out so the wire format can be asserted without a live call.
@Suite("Prompt cache-prefix alignment")
struct PromptPrefixTests {
    private let floor = LLMTokens.cacheBlockBytes

    // MARK: - Work-note narratives

    /// The stage that measured 0% cached on all 19 of its calls: the day and
    /// the task name used to open the prompt, so two calls shared 19 bytes.
    /// Both tiers, because the light one carries the shorter rules block and
    /// is the common case — it clears the floor by less.
    @Test("day-note prompts of one tier share their rules block",
          arguments: [WorkNoteCompiler.Tier.light, .detailed])
    func workNoteRulesArePrefix(tier: WorkNoteCompiler.Tier) {
        let first = WorkNoteCompiler.prompt(
            taskName: "NMF research", day: "2026-07-30",
            sessions: [.init(start: "09:12", end: "11:40")],
            samples: "gradient descent notes", tier: tier)
        let second = WorkNoteCompiler.prompt(
            taskName: "Shifu development", day: "2026-08-01",
            sessions: [.init(start: "13:05", end: "14:20")],
            samples: "capture ladder teardown", tier: tier)

        #expect(LLMTokens.sharedPrefixBytes(first, second) >= floor)
    }

    /// The win this reordering was actually for. An open day is regenerated
    /// every few hours over a sample list that only grows at the end, so the
    /// later prompt must contain the earlier one's evidence verbatim, in
    /// place — the whole earlier prompt up to its fence bills at cache rate.
    @Test("a grown day's prompt extends the earlier prompt's prefix")
    func workNoteSamplesAppendOnly() {
        let morning = "09:12 opened the proof\n---\n10:30 stuck on lemma 3"
        let afternoon = morning + "\n---\n14:02 lemma 3 falls out of convexity"
        func render(_ samples: String, sessions: [WorkNote.Session]) -> String {
            WorkNoteCompiler.prompt(
                taskName: "NMF research", day: "2026-07-30",
                sessions: sessions, samples: samples, tier: .detailed)
        }
        let earlier = render(morning, sessions: [.init(start: "09:12", end: "11:40")])
        // The later call has a session the earlier one didn't — the exact
        // change that used to end the shared prefix on line 2.
        let later = render(afternoon, sessions: [.init(start: "09:12", end: "11:40"),
                                                 .init(start: "14:02", end: "15:30")])

        let shared = LLMTokens.sharedPrefixBytes(earlier, later)
        #expect(shared >= floor)
        // Not merely a block: everything through the earlier evidence.
        #expect(shared > morning.utf8.count)
        #expect(later.contains(morning))
    }

    /// Truncation keeps the head, so the budget loop can shrink a prompt
    /// without moving the bytes above the cut.
    @Test("a truncated day-note prompt stays a prefix-sharer")
    func workNoteTruncationKeepsPrefix() {
        let full = String(repeating: "screen text sample. ", count: 400)
        func render(_ samples: String) -> String {
            WorkNoteCompiler.prompt(
                taskName: "NMF research", day: "2026-07-30",
                sessions: [.init(start: "09:12", end: "11:40")],
                samples: samples, tier: .detailed)
        }
        let cut = render(String(full.prefix(full.count * 2 / 3)))
        #expect(LLMTokens.sharedPrefixBytes(render(full), cut) >= floor)
    }

    // MARK: - Task overviews

    /// `previous` is a different document on every call by construction, so
    /// it may never precede the day notes — 9 of 10 measured calls cached
    /// zero when it did.
    @Test("overview prompts share their day notes across revisions")
    func overviewDayNotesArePrefix() {
        let days = [
            TaskOverviewCompiler.DayNote(
                day: "2026-07-29", summary: "Read three papers.",
                sessionsProse: "**09:00–11:00** — literature.", detailProse: nil),
            TaskOverviewCompiler.DayNote(
                day: "2026-07-30", summary: "Proved the lemma.",
                sessionsProse: "**13:00–17:00** — convexity.", detailProse: nil)
        ]
        let first = TaskOverviewCompiler.prompt(
            taskName: "NMF research", gist: "publishable NMF result",
            previous: "## Status\nEarly.", days: days)
        let second = TaskOverviewCompiler.prompt(
            taskName: "NMF research", gist: "publishable NMF result",
            previous: "## Status\nMid-flight, lemma 3 closed.", days: days)

        #expect(LLMTokens.sharedPrefixBytes(first, second) >= floor)
        // The whole day-note block, not just the rules.
        #expect(LLMTokens.sharedPrefixBytes(first, second) > 900)
    }

    /// The prior draft goes last, but never *actually* last: the order to
    /// replace it has to be the final thing read, or the draft becomes a
    /// template to copy.
    @Test("the rewrite instruction follows the prior overview")
    func overviewInstructionFollowsPriorDraft() throws {
        let prompt = TaskOverviewCompiler.prompt(
            taskName: "NMF research", gist: nil,
            previous: "## Status\nEarly.",
            days: [.init(day: "2026-07-29", summary: "Read three papers.",
                         sessionsProse: nil, detailProse: nil)])
        let draft = try #require(prompt.range(of: "The current overview, to revise:"))
        let order = try #require(prompt.range(of: "Now rewrite it in full"))
        #expect(draft.lowerBound < order.lowerBound)
    }

    // MARK: - Theme narratives and decks

    @Test("theme narratives share their day entries across runs")
    func themeNarrativeDayLinesArePrefix() {
        let lines = (1...12).map { "2026-07-\($0 + 10) (2.\($0 % 10)h): reading, writing" }
        let first = ThemeClusterer.narrativePrompt(
            name: "Shifu development", gist: "the screen observer", dayLines: lines)
        let second = ThemeClusterer.narrativePrompt(
            name: "Shifu development", gist: "the screen observer",
            dayLines: lines + ["2026-07-23 (1.0h): shipping"])

        #expect(LLMTokens.sharedPrefixBytes(first, second) >= floor)
    }

    /// One deck build issues several batches; `written` moves on each, and it
    /// used to sit on line 3.
    @Test("deck batches of one deck share their preamble")
    func deckBatchesSharePreamble() {
        let blocks = [DeckBuilder.BlockText(id: 1, text: "NMF minimizes reconstruction error.")]
        let first = DeckBuilder.prompt(
            title: "NMF", taskName: "NMF research", instructions: nil,
            range: nil, written: 0, blocks: blocks)
        let second = DeckBuilder.prompt(
            title: "NMF", taskName: "NMF research", instructions: nil,
            range: nil, written: 7, blocks: blocks)

        #expect(LLMTokens.sharedPrefixBytes(first, second) >= floor)
    }

    // MARK: - The measurement itself

    @Test("shared prefix counts bytes, and stops at the first difference")
    func sharedPrefixCountsBytes() {
        #expect(LLMTokens.sharedPrefixBytes("abc", "abd") == 2)
        #expect(LLMTokens.sharedPrefixBytes("abc", "abc") == 3)
        #expect(LLMTokens.sharedPrefixBytes("", "abc") == 0)
        // Multi-byte scalars count as their UTF-8 length, which is what a
        // tokenizer and a byte-keyed cache both see.
        #expect(LLMTokens.sharedPrefixBytes("é", "é") == 2)
        #expect(LLMTokens.sharedPrefixBytes("→x", "→y") == 3)
    }
}

import Foundation
import Testing
@testable import ShifuCore

/// Rate parsing and the dollars-from-tokens arithmetic (`LLMPrices`). The
/// estimate is only as honest as the cached split — a cache hit bills at a
/// fiftieth of a miss — so that arithmetic is what these pin down.
@Suite struct LLMPricesTests {
    @Test func aRateTripleParsesAsInCachedOut() throws {
        let prices = try #require(LLMPrices.parse("0.14/0.0028/0.28"))
        #expect(prices == LLMPrices(inPerM: 0.14, cachedPerM: 0.0028, outPerM: 0.28))
        // Whitespace is what a hand-edited settings row looks like.
        #expect(LLMPrices.parse(" 0.66 / 0.022 / 1.98 ") == LLMPrices.reasoningDefault)
    }

    /// A triple that doesn't parse must fall back to the slot default whole —
    /// pricing a day at half-garbage would be worse than ignoring the setting.
    @Test func anythingButThreeNonNegativeNumbersIsRejected() {
        #expect(LLMPrices.parse(nil) == nil)
        #expect(LLMPrices.parse("") == nil)
        #expect(LLMPrices.parse("0.14/0.28") == nil)
        #expect(LLMPrices.parse("0.14/0.0028/0.28/0.5") == nil)
        #expect(LLMPrices.parse("cheap/free/cheap") == nil)
        #expect(LLMPrices.parse("-0.14/0.0028/0.28") == nil)
    }

    @Test func costSplitsCachedTokensOutOfThePromptTotal() {
        let prices = LLMPrices(inPerM: 1.0, cachedPerM: 0.1, outPerM: 2.0)
        // 40k prompt of which 30k cached: 10k at 1.0 + 30k at 0.1 + 4k at 2.0
        // = 0.010 + 0.003 + 0.008 dollars.
        let totals = LLMUsage.Totals(
            model: "m", calls: 1, promptTokens: 40_000,
            cachedPromptTokens: 30_000, completionTokens: 4_000)
        #expect(abs(prices.cost(of: totals) - 0.021) < 1e-9)
    }
}

@Suite struct LLMPriceBookTests {
    /// The invoice may carry a dated snapshot of the requested alias; either
    /// direction of prefix match must price it as the reasoning slot, and
    /// everything unrecognized prices as fast.
    @Test func theReasoningSlotIsMatchedByPrefixEitherWay() {
        let book = LLMPriceBook(
            fast: LLMPrices.fastDefault, reasoning: LLMPrices.reasoningDefault,
            reasoningModel: "deepseek-v4-pro", localModel: "qwen3.5-9b")
        #expect(book.prices(forModel: "deepseek-v4-pro") == LLMPrices.reasoningDefault)
        #expect(book.prices(forModel: "deepseek-v4-pro-0728") == LLMPrices.reasoningDefault)
        #expect(book.prices(forModel: "deepseek-v4-flash") == LLMPrices.fastDefault)
        #expect(book.prices(forModel: "some-proxy-model") == LLMPrices.fastDefault)
    }

    /// The blind week's phantom: local rows priced as flash because
    /// "everything unrecognized is fast". A local-tier row costs the user's
    /// own electricity, and the estimate must say $0, not a DeepSeek rate.
    @Test func theLocalModelPricesAsFree() {
        let book = LLMPriceBook(
            fast: LLMPrices.fastDefault, reasoning: LLMPrices.reasoningDefault,
            reasoningModel: "deepseek-v4-pro", localModel: "qwen3.5-9b")
        #expect(book.prices(forModel: "qwen3.5-9b") == LLMPrices.free)
        // llama-server's invoice may carry a longer file-ish name.
        #expect(book.prices(forModel: "qwen3.5-9b-instruct-q4") == LLMPrices.free)
    }

    @Test func loadFallsBackToPublishedRatesAndConfiguredModel() throws {
        let database = try ShifuDatabase.inMemory()
        let blank = LLMPriceBook.load(database: database)
        #expect(blank.fast == LLMPrices.fastDefault)
        #expect(blank.reasoning == LLMPrices.reasoningDefault)
        #expect(blank.reasoningModel == "deepseek-v4-pro")
        #expect(blank.localModel == LocalLLMDefaults.model)

        try Settings.set(LLMPrices.fastKey, to: "1/0.1/2", database: database)
        try Settings.set(LLMPrices.reasoningKey, to: "not a triple", database: database)
        try Settings.set(Settings.deepseekReasoningModelKey, to: "my-pro", database: database)
        try Settings.set(Settings.localModelKey, to: "my-qwen", database: database)
        let configured = LLMPriceBook.load(database: database)
        #expect(configured.fast == LLMPrices(inPerM: 1, cachedPerM: 0.1, outPerM: 2))
        #expect(configured.reasoning == LLMPrices.reasoningDefault)
        #expect(configured.reasoningModel == "my-pro")
        #expect(configured.localModel == "my-qwen")
    }

    @Test func windowCostSumsBothSlotsAtTheirOwnRates() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(LLMPrices.fastKey, to: "1/1/1", database: database)
        try Settings.set(LLMPrices.reasoningKey, to: "10/10/10", database: database)
        LLMUsage.record(
            LLMUsage.Call(
                model: "deepseek-v4-flash", promptTokens: 500_000,
                cachedPromptTokens: 0, completionTokens: 500_000),
            at: 1_000, database: database)
        LLMUsage.record(
            LLMUsage.Call(
                model: "deepseek-v4-pro", promptTokens: 50_000,
                cachedPromptTokens: 0, completionTokens: 50_000),
            at: 2_000, database: database)
        let book = LLMPriceBook.load(database: database)
        // 1M flash tokens at $1/M + 100k pro tokens at $10/M.
        #expect(abs(book.cost(from: 0, to: 3_000, database: database) - 2.0) < 1e-9)
        // Outside the window there is nothing to price.
        #expect(book.cost(from: 3_000, to: 4_000, database: database) == 0)
    }

    @Test func theWarnThresholdReadsItsSettingAndDefaultsToTenCents() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(LLMPriceBook.dailyWarnUSD(database: database) == 0.10)
        try Settings.set(LLMPriceBook.dailyWarnKey, to: "0.05", database: database)
        #expect(LLMPriceBook.dailyWarnUSD(database: database) == 0.05)
        try Settings.set(LLMPriceBook.dailyWarnKey, to: "ten cents", database: database)
        #expect(LLMPriceBook.dailyWarnUSD(database: database) == 0.10)
    }
}

/// DeepSeek doubles every rate in its weekday peak windows (01:00–04:00 and
/// 06:00–10:00 UTC). Half the dogfood ledger's spend landed there, so a meter
/// that ignores it under-reports by a third.
@Suite struct DeepSeekPeakTests {
    /// 2026-09-21 was a Monday; UTC throughout.
    private func utc(day: Int, hour: Int, minute: Int = 0) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    @Test func peakIsTwoWeekdayWindowsInUTC() {
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 21, hour: 0, minute: 59)))
        #expect(DeepSeekPeak.contains(unixMs: utc(day: 21, hour: 1)))
        #expect(DeepSeekPeak.contains(unixMs: utc(day: 21, hour: 3, minute: 59)))
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 21, hour: 4)))
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 21, hour: 5, minute: 30)))
        #expect(DeepSeekPeak.contains(unixMs: utc(day: 25, hour: 9, minute: 59)))   // Friday
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 25, hour: 10)))
        // Weekends are off-peak all day.
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 26, hour: 2)))   // Saturday
        #expect(!DeepSeekPeak.contains(unixMs: utc(day: 27, hour: 7)))   // Sunday
    }

    /// The rollup classifies rows in SQL; it must agree with the Swift
    /// predicate hour by hour across a whole week.
    @Test func theSQLFormAgreesWithTheSwiftOne() throws {
        let database = try ShifuDatabase.inMemory()
        var expectedPeak = 0
        for day in 21...27 {
            for hour in 0..<24 {
                let at = utc(day: day, hour: hour, minute: 30)
                if DeepSeekPeak.contains(unixMs: at) { expectedPeak += 1 }
                LLMUsage.record(
                    LLMUsage.Call(model: "deepseek-flash", promptTokens: 1,
                                  cachedPromptTokens: 0, completionTokens: 0),
                    at: at, database: database)
            }
        }
        let totals = try #require(try LLMUsage.totals(
            from: 0, to: Int64.max, database: database).first)
        #expect(expectedPeak == 5 * 7)
        #expect(totals.promptTokens == 7 * 24)
        #expect(totals.peakPromptTokens == expectedPeak)
    }

    @Test func peakTokensBillAtDoubleOnlyForDeepSeekModels() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(LLMPrices.fastKey, to: "1/1/1", database: database)
        for model in ["deepseek-flash", "some-proxy-model"] {
            // One million tokens off-peak, one million at peak.
            LLMUsage.record(
                LLMUsage.Call(model: model, promptTokens: 1_000_000,
                              cachedPromptTokens: 0, completionTokens: 0),
                at: utc(day: 21, hour: 12), database: database)
            LLMUsage.record(
                LLMUsage.Call(model: model, promptTokens: 1_000_000,
                              cachedPromptTokens: 0, completionTokens: 0),
                at: utc(day: 21, hour: 2), database: database)
        }
        let book = LLMPriceBook.load(database: database)
        let byModel = Dictionary(uniqueKeysWithValues: try LLMUsage.totals(
            from: 0, to: Int64.max, database: database).map { ($0.model, book.cost(of: $0)) })
        #expect(abs((byModel["deepseek-flash"] ?? 0) - 3.0) < 1e-9)
        // A custom endpoint's own model isn't billed on DeepSeek's clock.
        #expect(abs((byModel["some-proxy-model"] ?? 0) - 2.0) < 1e-9)
    }
}

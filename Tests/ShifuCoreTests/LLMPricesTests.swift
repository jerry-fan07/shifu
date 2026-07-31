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
        #expect(LLMPrices.parse(" 0.435 / 0.003625 / 0.87 ") == LLMPrices.reasoningDefault)
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
    /// everything unrecognized prices as fast — there are only two slots.
    @Test func theReasoningSlotIsMatchedByPrefixEitherWay() {
        let book = LLMPriceBook(
            fast: LLMPrices.fastDefault, reasoning: LLMPrices.reasoningDefault,
            reasoningModel: "deepseek-v4-pro")
        #expect(book.prices(forModel: "deepseek-v4-pro") == LLMPrices.reasoningDefault)
        #expect(book.prices(forModel: "deepseek-v4-pro-0728") == LLMPrices.reasoningDefault)
        #expect(book.prices(forModel: "deepseek-v4-flash") == LLMPrices.fastDefault)
        #expect(book.prices(forModel: "some-proxy-model") == LLMPrices.fastDefault)
    }

    @Test func loadFallsBackToPublishedRatesAndConfiguredModel() throws {
        let database = try ShifuDatabase.inMemory()
        let blank = LLMPriceBook.load(database: database)
        #expect(blank.fast == LLMPrices.fastDefault)
        #expect(blank.reasoning == LLMPrices.reasoningDefault)
        #expect(blank.reasoningModel == "deepseek-v4-pro")

        try Settings.set(LLMPrices.fastKey, to: "1/0.1/2", database: database)
        try Settings.set(LLMPrices.reasoningKey, to: "not a triple", database: database)
        try Settings.set(Settings.deepseekReasoningModelKey, to: "my-pro", database: database)
        let configured = LLMPriceBook.load(database: database)
        #expect(configured.fast == LLMPrices(inPerM: 1, cachedPerM: 0.1, outPerM: 2))
        #expect(configured.reasoning == LLMPrices.reasoningDefault)
        #expect(configured.reasoningModel == "my-pro")
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

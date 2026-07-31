import Foundation

/// Per-million-token rates for one model slot, and the arithmetic that turns
/// `llm_usage` token counts into an estimated dollar figure.
///
/// `llm_usage` deliberately stores no prices — they change without warning and
/// differ per endpoint — so the rates live in two editable settings and the
/// multiplication happens here, at read time. A stale rate mis-prices history
/// and future alike, which is exactly what an estimate can afford: the number
/// answers "is this a cheap day or an expensive one?", not an invoice.
///
/// One setting per slot, holding all three rates as `in/cached/out` dollars
/// per million tokens (`"0.14/0.0028/0.28"`). The cached rate matters: a
/// context-cache hit bills at a fiftieth of a miss, so pricing the whole
/// prompt at the miss rate would overstate a resend-heavy day several-fold.
public struct LLMPrices: Sendable, Equatable {
    public let inPerM: Double
    public let cachedPerM: Double
    public let outPerM: Double

    /// Settings keys (`SettingsCatalog.llmPriceFast` / `.llmPriceReasoning`).
    public static let fastKey = "llm.price.fast"
    public static let reasoningKey = "llm.price.reasoning"

    /// DeepSeek's published rates (July 2026) — what a blank setting means.
    /// The two slots are priced ~3× apart on paper, further in practice: the
    /// reasoning model bills its chain-of-thought as output.
    public static let fastDefault = LLMPrices(inPerM: 0.14, cachedPerM: 0.0028, outPerM: 0.28)
    public static let reasoningDefault = LLMPrices(
        inPerM: 0.435, cachedPerM: 0.003625, outPerM: 0.87)

    public init(inPerM: Double, cachedPerM: Double, outPerM: Double) {
        self.inPerM = inPerM
        self.cachedPerM = cachedPerM
        self.outPerM = outPerM
    }

    /// `"in/cached/out"` per million tokens. Nil for anything else — a triple
    /// that doesn't parse falls back to the slot default rather than pricing
    /// a day at half-garbage.
    public static func parse(_ raw: String?) -> LLMPrices? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "/").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 3,
              let inPerM = parts[0], let cachedPerM = parts[1], let outPerM = parts[2],
              inPerM >= 0, cachedPerM >= 0, outPerM >= 0 else { return nil }
        return LLMPrices(inPerM: inPerM, cachedPerM: cachedPerM, outPerM: outPerM)
    }

    /// Estimated dollars for one model's rolled-up token counts.
    public func cost(of totals: LLMUsage.Totals) -> Double {
        let missed = Double(max(0, totals.promptTokens - totals.cachedPromptTokens))
        return (missed * inPerM
            + Double(totals.cachedPromptTokens) * cachedPerM
            + Double(totals.completionTokens) * outPerM) / 1_000_000
    }
}

/// Both slots' rates plus the one fact needed to pick between them: which
/// model name the reasoning slot answers to. `llm_usage.model` is whatever
/// the server put on the invoice — possibly a dated snapshot of the requested
/// alias — so matching is by prefix either way, and everything that isn't the
/// reasoning model prices as fast (there are only two slots).
public struct LLMPriceBook: Sendable {
    public let fast: LLMPrices
    public let reasoning: LLMPrices
    let reasoningModel: String

    /// A blank `deepseek.reasoning_model` means this — must stay in step with
    /// `DeepSeekBackend.defaultReasoningModel` (analyzer target, so it can't
    /// be referenced from here).
    static let defaultReasoningModel = "deepseek-v4-pro"

    public static func load(database: ShifuDatabase) -> LLMPriceBook {
        let fast = LLMPrices.parse(
            (try? Settings.get(LLMPrices.fastKey, database: database)) ?? nil)
            ?? LLMPrices.fastDefault
        let reasoning = LLMPrices.parse(
            (try? Settings.get(LLMPrices.reasoningKey, database: database)) ?? nil)
            ?? LLMPrices.reasoningDefault
        let model = ((try? Settings.get(
            Settings.deepseekReasoningModelKey, database: database)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultReasoningModel
        return LLMPriceBook(fast: fast, reasoning: reasoning, reasoningModel: model)
    }

    /// Daily estimated spend above which the analyzer's spend line carries a
    /// warning. A warning, not a governor: the user chose visibility over
    /// throttling, so no stage is ever skipped on budget grounds.
    public static let dailyWarnKey = "llm.daily_warn_usd"
    public static let dailyWarnDefault = 0.10

    public static func dailyWarnUSD(database: ShifuDatabase) -> Double {
        Double(((try? Settings.get(dailyWarnKey, database: database)) ?? nil) ?? "")
            ?? dailyWarnDefault
    }

    public func prices(forModel model: String) -> LLMPrices {
        model.hasPrefix(reasoningModel) || reasoningModel.hasPrefix(model) ? reasoning : fast
    }

    public func cost(of totals: LLMUsage.Totals) -> Double {
        prices(forModel: totals.model).cost(of: totals)
    }

    /// Estimated dollars across every model in `[from, to)` — the "what did
    /// today cost" number the analyzer prints and the warn threshold compares
    /// against.
    public func cost(from: Int64, to: Int64, database: ShifuDatabase) -> Double {
        let totals = (try? LLMUsage.totals(from: from, to: to, database: database)) ?? []
        return totals.reduce(0) { $0 + cost(of: $1) }
    }
}

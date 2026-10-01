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
/// per million tokens (`"0.15/0.003/0.6"`). The cached rate matters: a
/// context-cache hit bills at a fiftieth of a miss, so pricing the whole
/// prompt at the miss rate would overstate a resend-heavy day several-fold.
///
/// The rates are DeepSeek's *off-peak* ones. DeepSeek bills twice that in
/// its weekday peak windows (`DeepSeekPeak`), and `LLMPriceBook` applies the
/// surcharge by each row's own timestamp.
public struct LLMPrices: Sendable, Equatable {
    public let inPerM: Double
    public let cachedPerM: Double
    public let outPerM: Double

    /// Settings keys (`SettingsCatalog.llmPriceFast` / `.llmPriceReasoning`).
    public static let fastKey = "llm.price.fast"
    public static let reasoningKey = "llm.price.reasoning"

    /// DeepSeek's published off-peak rates, read off
    /// api-docs.deepseek.com/quick_start/pricing on 2026-09-25 — what a blank
    /// setting means. The fast slot's alias is served by `deepseek-flash`
    /// (V4.1-Flash), which is what `llm_usage.model` records. The July 2026
    /// rates these replaced (0.14/0.0028/0.28 and 0.435/0.003625/0.87) had
    /// gone stale: priced at them, the dogfood ledger's 2026-09-11..24 read
    /// $0.055 a day against $0.108 billed. The slots are priced 4.4× apart
    /// on input and 3.3× on output. (A thinking model would also bill its
    /// chain-of-thought as output; neither slot runs with thinking on.)
    public static let fastDefault = LLMPrices(inPerM: 0.15, cachedPerM: 0.003, outPerM: 0.6)
    public static let reasoningDefault = LLMPrices(
        inPerM: 0.66, cachedPerM: 0.022, outPerM: 1.98)
    /// The local tier's rates: the user's own electricity, not an invoice.
    public static let free = LLMPrices(inPerM: 0, cachedPerM: 0, outPerM: 0)

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
    /// `peakSurcharge` bills the rollup's peak-window share twice — DeepSeek's
    /// peak rate is double its off-peak one — so it is only for a model
    /// DeepSeek hosts (`LLMPriceBook.billsPeakHours`).
    public func cost(of totals: LLMUsage.Totals, peakSurcharge: Bool = false) -> Double {
        let base = cost(prompt: totals.promptTokens, cached: totals.cachedPromptTokens,
                        completion: totals.completionTokens)
        guard peakSurcharge else { return base }
        return base + cost(prompt: totals.peakPromptTokens,
                           cached: totals.peakCachedPromptTokens,
                           completion: totals.peakCompletionTokens)
    }

    private func cost(prompt: Int, cached: Int, completion: Int) -> Double {
        let missed = Double(max(0, prompt - cached))
        return (missed * inPerM + Double(cached) * cachedPerM
            + Double(completion) * outPerM) / 1_000_000
    }
}

/// DeepSeek's peak windows, when every rate is doubled: 01:00–04:00 and
/// 06:00–10:00 UTC, Monday to Friday (api-docs.deepseek.com, read
/// 2026-09-25). Chinese public holidays are off-peak all day and are not
/// modelled here, so on those days an estimate over-counts — an estimate
/// that errs high.
///
/// One definition in two forms — a Swift predicate and the same test as SQL
/// over a unix-ms column — so a window changed in one place can't drift from
/// the other.
public enum DeepSeekPeak {
    /// UTC hours, half-open.
    static let windows: [Range<Int>] = [1..<4, 6..<10]

    public static func contains(unixMs: Int64) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let date = Date(timeIntervalSince1970: Double(unixMs) / 1_000)
        // Gregorian weekdays run Sunday 1 … Saturday 7.
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return (2...6).contains(weekday) && windows.contains { $0.contains(hour) }
    }

    /// `contains` as a SQL boolean over `column` (unix ms). SQLite's `%w` is
    /// Sunday 0 … Saturday 6.
    static func sql(column: String) -> String {
        let day = "strftime('%w', \(column) / 1000, 'unixepoch')"
        let hour = "CAST(strftime('%H', \(column) / 1000, 'unixepoch') AS INTEGER)"
        let hours = windows.map { "(\(hour) >= \($0.lowerBound) AND \(hour) < \($0.upperBound))" }
        return "(\(day) IN ('1','2','3','4','5') AND (\(hours.joined(separator: " OR "))))"
    }
}

/// Both hosted slots' rates plus the two facts needed to pick between them:
/// which model name the reasoning slot answers to, and which the local tier
/// does. `llm_usage.model` is whatever the server put on the invoice —
/// possibly a dated snapshot of the requested alias — so matching is by
/// prefix either way. Local-tier rows price at zero (the rows still matter:
/// token counts are how a local server's load is read); everything else
/// that isn't the reasoning model prices as fast.
public struct LLMPriceBook: Sendable {
    public let fast: LLMPrices
    public let reasoning: LLMPrices
    let reasoningModel: String
    let localModel: String

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
        // Read even when the backend is no longer "local": a week of Qwen
        // rows must not start pricing as flash the day the user switches.
        let localModel = ((try? Settings.get(
            Settings.localModelKey, database: database)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 } ?? LocalLLMDefaults.model
        return LLMPriceBook(
            fast: fast, reasoning: reasoning, reasoningModel: model, localModel: localModel)
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

    /// Whether DeepSeek bills this invoice name, and so doubles it at peak.
    /// Keyed on the name the server answered with, the same way the rates
    /// are: a local model or a custom endpoint's model never is.
    public static func billsPeakHours(_ model: String) -> Bool {
        model.lowercased().hasPrefix("deepseek")
    }

    public func prices(forModel model: String) -> LLMPrices {
        if model.hasPrefix(localModel) || localModel.hasPrefix(model) {
            return .free
        }
        return model.hasPrefix(reasoningModel) || reasoningModel.hasPrefix(model)
            ? reasoning : fast
    }

    public func cost(of totals: LLMUsage.Totals) -> Double {
        prices(forModel: totals.model).cost(
            of: totals, peakSurcharge: Self.billsPeakHours(totals.model))
    }

    /// Estimated dollars across every model in `[from, to)` — the "what did
    /// today cost" number the analyzer prints and the warn threshold compares
    /// against.
    public func cost(from: Int64, to: Int64, database: ShifuDatabase) -> Double {
        let totals = (try? LLMUsage.totals(from: from, to: to, database: database)) ?? []
        return totals.reduce(0) { $0 + cost(of: $1) }
    }
}

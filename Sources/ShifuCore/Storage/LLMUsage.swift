import Foundation
import GRDB

/// What each LLM call cost, in tokens (`llm_usage`).
///
/// The provider bills tokens, not calls, and the numbers are already in every
/// response — so the only way to know what a day of analysis cost is to keep
/// them. One row per HTTP response rather than a daily counter: a daily row
/// would need a local-midnight key, and those drift when the machine changes
/// time zone (the bug `task_logs` has), while a timestamped row can be rolled
/// up by whatever day the reader means. The rows are ~50 bytes and the
/// analyzer makes tens of calls an hour at most, so keeping them all is
/// cheaper than the arithmetic to avoid it.
///
/// Lives in ShifuCore (no network here — the parsing takes JSON someone else
/// fetched) because the writer is the analyzer and the readers are the CLI and
/// the app. Prices are deliberately absent: they change without warning and
/// differ per model, so this stores the counts and leaves the multiplication
/// to whoever is looking.
public enum LLMUsage {
    /// One billed response.
    public struct Call: Sendable, Equatable {
        public let model: String
        /// Input tokens, *including* the cached ones — providers report the
        /// total and then split out the discounted part.
        public let promptTokens: Int
        /// The part of `promptTokens` that hit the provider's context cache
        /// and bills at the lower rate. Zero when the endpoint doesn't say.
        public let cachedPromptTokens: Int
        /// Output tokens. For a thinking model this includes the
        /// chain-of-thought, which is billed like any other output token.
        public let completionTokens: Int

        public init(
            model: String, promptTokens: Int, cachedPromptTokens: Int, completionTokens: Int
        ) {
            self.model = model
            self.promptTokens = promptTokens
            self.cachedPromptTokens = cachedPromptTokens
            self.completionTokens = completionTokens
        }

        /// Reads the `usage` object of an OpenAI-compatible chat completion.
        /// Nil when there is no usage to record — a body without it is a
        /// protocol oddity, not something to store zeros for.
        ///
        /// Two spellings of the cache split are in the wild and DeepSeek sends
        /// both: `prompt_tokens_details.cached_tokens` (OpenAI's, so it also
        /// works for whatever endpoint `deepseek.base_url` points at) and
        /// `prompt_cache_hit_tokens` (DeepSeek's own).
        ///
        /// The response's own `model` wins over `requested`: a server is free
        /// to resolve an alias or a dated snapshot, and the name it answers
        /// with is the one on the invoice.
        public static func parse(response: [String: Any], requested: String) -> Call? {
            guard let usage = response["usage"] as? [String: Any] else { return nil }
            let details = usage["prompt_tokens_details"] as? [String: Any]
            let cached = (details?["cached_tokens"] as? Int)
                ?? (usage["prompt_cache_hit_tokens"] as? Int) ?? 0
            let billed = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Call(
                model: billed ?? requested,
                promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                cachedPromptTokens: cached,
                completionTokens: usage["completion_tokens"] as? Int ?? 0)
        }
    }

    /// Records a billed response. Bookkeeping must never take down the call it
    /// is describing, so failures are swallowed: the answer is already paid
    /// for and worth more than the row.
    public static func record(_ call: Call, at unixMs: Int64, database: ShifuDatabase) {
        try? database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO llm_usage
                    (at_ms, model, prompt_tokens, cached_prompt_tokens, completion_tokens)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    unixMs, call.model, call.promptTokens,
                    call.cachedPromptTokens, call.completionTokens
                ])
        }
    }

    /// Tokens spent by one model over a window.
    public struct Totals: Sendable, Equatable {
        public let model: String
        public let calls: Int
        public let promptTokens: Int
        public let cachedPromptTokens: Int
        public let completionTokens: Int
    }

    /// Per-model totals in `[from, to)`, biggest spender first. Split by model
    /// because that is the grain prices come at — the fast and reasoning slots
    /// differ by an order of magnitude, so a combined token count says nothing
    /// about cost.
    public static func totals(
        from: Int64, to: Int64, database: ShifuDatabase
    ) throws -> [Totals] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT model, COUNT(*) AS calls,
                       SUM(prompt_tokens) AS prompt_tokens,
                       SUM(cached_prompt_tokens) AS cached_prompt_tokens,
                       SUM(completion_tokens) AS completion_tokens
                FROM llm_usage WHERE at_ms >= ? AND at_ms < ?
                GROUP BY model
                ORDER BY prompt_tokens + completion_tokens DESC
                """, arguments: [from, to]).map { row in
                Totals(
                    model: row["model"], calls: row["calls"],
                    promptTokens: row["prompt_tokens"],
                    cachedPromptTokens: row["cached_prompt_tokens"],
                    completionTokens: row["completion_tokens"])
            }
        }
    }
}

import Foundation

/// Self-describing user settings (design.md §9).
///
/// Every tunable is declared once, here, with its key, default, bounds and
/// presentation together. The daemon and the app both read the same
/// declaration, so they cannot disagree about a bound — the failure mode this
/// replaces is a clamp written twice, in two targets, that drifts apart.
///
/// Adding a setting: add one entry to `SettingsCatalog` and append it to the
/// matching list. Storage, defaulting, validation and UI follow automatically.
/// The one thing that does *not* follow is live reload in `shifud` — see
/// `Daemon.reloadIntervals()`.

/// Groups settings in the UI, and — since the Settings page is a rail of
/// sections rather than one scroll — *is* the page's navigation. Declaration
/// order is the order of the rail, so it runs from what Shifu does most often
/// to what it is: capture, analysis, what it refuses to look at, the one
/// switch, and the machine's own facts.
///
/// A section may exist with no catalog entry in it at all (Privacy's
/// exclusions live in their own table, About has nothing to store), so the
/// page decides what a section is worth showing — see `SettingsPanel`.
public enum SettingsSection: String, CaseIterable, Sendable {
    case capture = "Capture"
    case analysis = "Analysis"
    case privacy = "Privacy"
    case focusMode = "Focus Mode"
    case about = "About"

    /// The one line under the section's title: what the dials below it govern.
    public var summary: String {
        switch self {
        case .capture:
            return "How often Shifu looks at the frontmost window, and how much "
                + "it takes when it does."
        case .analysis:
            return "How raw captures become tasks, themes and cards — and what "
                + "leaves this Mac to do it."
        case .privacy:
            return "What Shifu refuses to look at. Exclusions are enforced in the "
                + "daemon before capture, so excluded content never reaches the "
                + "database at all."
        case .focusMode:
            return "A gentle glow when a distracting site holds the screen — "
                + "a nudge, not a block."
        case .about:
            return "Where everything lives on disk, and what this build is."
        }
    }

    /// The rule that governs this section, for the foot of the rail. Not a
    /// reassurance — each one is a guarantee stated elsewhere as an invariant,
    /// repeated here because the screen where you change a dial is the screen
    /// where you need to know what the dial cannot do.
    public var promise: String {
        switch self {
        case .capture:
            return "Pixels are never persisted. A screenshot lives in memory for "
                + "one OCR call."
        case .analysis:
            return "Changes reach the running daemon immediately. No restart."
        case .privacy:
            return "Exclusions apply to capture, not just display — excluded text "
                + "is never written."
        case .focusMode:
            return "The glow only. Nothing listed here changes how your time is "
                + "classified."
        case .about:
            return "Raw observations never leave this Mac."
        }
    }
}

/// An integer setting stored as seconds. `unit` affects display only.
public struct IntSetting: Identifiable, Sendable {
    public let key: String
    public let section: SettingsSection
    public let title: String
    public let help: String
    public let defaultValue: Int
    public let range: ClosedRange<Int>
    public let step: Int
    public let unit: Unit

    public var id: String { key }

    public enum Unit: Sendable { case seconds, minutes, days }

    public init(
        key: String, section: SettingsSection, title: String, help: String,
        defaultValue: Int, range: ClosedRange<Int>, step: Int, unit: Unit
    ) {
        self.key = key
        self.section = section
        self.title = title
        self.help = help
        self.defaultValue = defaultValue
        self.range = range
        self.step = step
        self.unit = unit
    }

    /// The single source of truth for this setting's bounds — applied on both
    /// read and write, so a hand-edited DB row can't escape them either.
    public func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public func display(_ value: Int) -> String {
        switch unit {
        case .seconds: return "\(value)s"
        case .minutes: return "\(value / 60) min"
        case .days: return value == 1 ? "1 day" : "\(value) days"
        }
    }
}

/// A user-managed list of domains, stored newline-separated.
public struct DomainListSetting: Identifiable, Sendable {
    public let key: String
    public let section: SettingsSection
    public let title: String
    public let help: String
    public let placeholder: String

    public var id: String { key }

    public init(
        key: String, section: SettingsSection, title: String, help: String, placeholder: String
    ) {
        self.key = key
        self.section = section
        self.title = title
        self.help = help
        self.placeholder = placeholder
    }

    /// Accepts what a user would actually paste — `https://www.Reddit.com/r/x`,
    /// `reddit.com:8080` — and reduces it to the same shape
    /// `Sessionizer.domain(of:)` produces, so the two can be compared directly.
    /// Returns nil when the input isn't a usable domain.
    public func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        text = text.components(separatedBy: "/")[0]
        text = text.components(separatedBy: "?")[0]
        text = text.components(separatedBy: "#")[0]
        text = text.components(separatedBy: ":")[0]   // port
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        guard text.contains("."), !text.contains(" "),
              !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        return text
    }
}

/// A closed set of values rendered as a picker (e.g. the analysis backend).
public struct ChoiceSetting: Identifiable, Sendable {
    public struct Option: Identifiable, Sendable {
        public let value: String
        public let label: String

        public var id: String { value }

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let key: String
    public let section: SettingsSection
    public let title: String
    public let help: String
    public let options: [Option]
    public let defaultValue: String
    /// Same gate as `TextSetting.visibleWhen`: hides the row unless another
    /// setting has the given value, so backend-specific dials only show for
    /// their backend.
    public let visibleWhen: (key: String, value: String)?

    public var id: String { key }

    public init(key: String, section: SettingsSection, title: String, help: String,
                options: [Option], defaultValue: String,
                visibleWhen: (key: String, value: String)? = nil) {
        self.key = key
        self.section = section
        self.title = title
        self.help = help
        self.options = options
        self.defaultValue = defaultValue
        self.visibleWhen = visibleWhen
    }

    /// Unknown stored values collapse to the default — applied on read *and*
    /// write, mirroring `IntSetting.clamp`.
    public func normalize(_ raw: String) -> String {
        options.contains { $0.value == raw } ? raw : defaultValue
    }
}

/// Free-text setting (API keys, endpoints, model names). `secure` renders as
/// a SecureField; `visibleWhen` hides the row unless another setting has the
/// given value, so each backend only shows its own fields.
public struct TextSetting: Identifiable, Sendable {
    public let key: String
    public let section: SettingsSection
    public let title: String
    public let help: String
    public let placeholder: String
    public let secure: Bool
    public let visibleWhen: (key: String, value: String)?

    public var id: String { key }

    public init(key: String, section: SettingsSection, title: String, help: String,
                placeholder: String, secure: Bool = false,
                visibleWhen: (key: String, value: String)? = nil) {
        self.key = key
        self.section = section
        self.title = title
        self.help = help
        self.placeholder = placeholder
        self.secure = secure
        self.visibleWhen = visibleWhen
    }
}

/// The catalog. **This is the only file a new setting has to touch.**
public enum SettingsCatalog {
    public static let heartbeatSeconds = IntSetting(
        key: "capture.heartbeat_seconds", section: .capture,
        title: "Heartbeat interval",
        help: "How often Shifu samples the frontmost window while you're active.",
        // Floor is 30s, not 15s: the perf harness measures cost *per trigger*
        // on the AX path only, so it can't validate a cadence that changes how
        // often the OCR rung runs (design.md §3.4, §12).
        defaultValue: 60, range: 30...300, step: 15, unit: .seconds
    )

    public static let analysisIntervalSeconds = IntSetting(
        key: "analysis.interval_seconds", section: .analysis,
        title: "Analysis interval",
        help: "How often the analyzer folds new captures into your ledger.",
        defaultValue: 3_600, range: 300...21_600, step: 300, unit: .minutes
    )

    /// Design.md §8 promises "raw text 14 days (configurable 1–90)"; the range
    /// here is that promise, and `Retention.defaultDays` is its default. The
    /// analyzer reads this on every run, so shortening it takes effect at the
    /// next scrub rather than at the next release.
    public static let textRetentionDays = IntSetting(
        key: "privacy.text_retention_days", section: .privacy,
        title: "Text retention",
        help: "Captured text is nulled out of older observations after this long. "
            + "The derived ledger — blocks, tasks, themes, notes — is kept indefinitely.",
        defaultValue: Retention.defaultDays, range: 1...90, step: 1, unit: .days
    )

    public static let focusModeDistractingDomains = DomainListSetting(
        key: "focusmode.distracting_domains", section: .focusMode,
        title: "Distracting sites",
        help: "Visiting these during Focus Mode triggers the glow. Your ledger "
            + "categories are unchanged. Takes effect the next time Focus Mode turns on.",
        placeholder: "reddit.com"
    )

    // AI backend (design.md §4.2, §8). DeepSeek is the only LLM backend and
    // it is analyzer-only; the API key is the opt-in — without one, analysis
    // is rules-only and nothing ever leaves this Mac.
    public static let analysisBackend = ChoiceSetting(
        key: Settings.analysisBackendKey, section: .analysis,
        title: "AI backend",
        help: "Names tasks, classifies ambiguous time, and writes work-log narratives. "
            + "DeepSeek receives only redacted text samples, after exclusions — never "
            + "pixels or raw captures. \"Rules only\" disables AI entirely.",
        options: [
            .init(value: "deepseek", label: "DeepSeek"),
            .init(value: "off", label: "Rules only")
        ],
        defaultValue: "deepseek"
    )

    public static let deepseekAPIKey = TextSetting(
        key: Settings.deepseekAPIKeyKey, section: .analysis,
        title: "API key",
        help: "Stored locally. The DEEPSEEK_API_KEY environment variable overrides it. "
            + "Until a key is set, analysis runs rules-only and stays on this Mac.",
        placeholder: "sk-…", secure: true,
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let deepseekBaseURL = TextSetting(
        key: Settings.deepseekBaseURLKey, section: .analysis,
        title: "Endpoint",
        help: "Any OpenAI-compatible /chat/completions server. Blank uses DeepSeek.",
        placeholder: "https://api.deepseek.com",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let deepseekModel = TextSetting(
        key: Settings.deepseekModelKey, section: .analysis,
        title: "Model",
        help: "Classifies time and writes notes and narratives. Blank uses "
            + "deepseek-v4-flash (cheap, fast).",
        placeholder: "deepseek-v4-flash",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let deepseekReasoningModel = TextSetting(
        key: Settings.deepseekReasoningModelKey, section: .analysis,
        title: "Reasoning model",
        help: "Groups your time into tasks and themes — the judgment-heavy "
            + "stages. Blank uses deepseek-v4-pro (thinking model, slower and "
            + "pricier but better at naming intent).",
        placeholder: "deepseek-v4-pro",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    // The local profile (design.md §4.2): point Endpoint at a local
    // OpenAI-compatible server, shrink the window to what it serves, and turn
    // reasoning thinking off. Every stage then re-sizes its batches through
    // invariant 7 — no other dial has to move.
    public static let deepseekContextTokens = TextSetting(
        key: Settings.deepseekContextTokensKey, section: .analysis,
        title: "Context window",
        help: "Tokens per call, prompt and response combined — analysis sizes "
            + "its batches to fit. Blank uses 60,000, which suits DeepSeek; "
            + "for a local server, enter what it actually serves (e.g. 16000).",
        placeholder: "60000",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let deepseekReasoningThinking = ChoiceSetting(
        key: Settings.deepseekReasoningThinkingKey, section: .analysis,
        title: "Reasoning thinking",
        help: "Whether the reasoning model thinks before answering. Keep on "
            + "for DeepSeek; turn off for a local model, or its chain-of-"
            + "thought reserve would eat a small context window whole.",
        options: [
            .init(value: "on", label: "On"),
            .init(value: "off", label: "Off")
        ],
        defaultValue: "on",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    // Cost estimation (LLMPrices). Rates as settings, not code: they change
    // without warning, and an estimate that can be corrected in a text field
    // beats one that waits for a release.
    public static let llmPriceFast = TextSetting(
        key: LLMPrices.fastKey, section: .analysis,
        title: "Model price",
        help: "Dollars per million tokens as in/cached/out, for estimating "
            + "daily spend. Blank uses DeepSeek's published V4 Flash rates.",
        placeholder: "0.14/0.0028/0.28",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let llmPriceReasoning = TextSetting(
        key: LLMPrices.reasoningKey, section: .analysis,
        title: "Reasoning model price",
        help: "Dollars per million tokens as in/cached/out. Blank uses "
            + "DeepSeek's published V4 Pro rates.",
        placeholder: "0.435/0.003625/0.87",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let llmDailyWarn = TextSetting(
        key: LLMPriceBook.dailyWarnKey, section: .analysis,
        title: "Daily spend warning",
        help: "The analyzer flags its spend line once today's estimate passes "
            + "this many dollars. A warning only — analysis never stops.",
        placeholder: "0.10",
        visibleWhen: (key: Settings.analysisBackendKey, value: "deepseek")
    )

    public static let ints: [IntSetting] = [
        heartbeatSeconds, analysisIntervalSeconds, textRetentionDays
    ]
    public static let domainLists: [DomainListSetting] = [focusModeDistractingDomains]
    public static let choices: [ChoiceSetting] = [analysisBackend, deepseekReasoningThinking]
    public static let texts: [TextSetting] = [
        deepseekAPIKey, deepseekBaseURL, deepseekModel, deepseekReasoningModel,
        deepseekContextTokens, llmPriceFast, llmPriceReasoning, llmDailyWarn
    ]
}

/// Exact match, then parent domains (`old.reddit.com` → `reddit.com` hits).
/// Same walk `RulesClassifier` uses for its own tables, against a plain set.
public enum DomainMatcher {
    public static func matches(_ domain: String, in domains: Set<String>) -> Bool {
        if domains.contains(domain) { return true }
        var parts = domain.split(separator: ".")
        while parts.count > 2 {
            parts.removeFirst()
            if domains.contains(parts.joined(separator: ".")) { return true }
        }
        return false
    }

    /// Focus Mode's off-task decision for one capture (design.md §4.4): returns
    /// the listed domain that matched, or nil when this capture isn't off-task.
    ///
    /// Excluded captures are opaque private time and are never nagged (§13.5) —
    /// that guard is the whole reason this lives here rather than inline in
    /// `FocusModeController`: `shifud` has no test target, and whether a private
    /// window can trigger a nudge is exactly the kind of thing a test should pin.
    public static func distracting(
        domain: String?, excluded: Bool, listed: Set<String>
    ) -> String? {
        guard !excluded, let domain, matches(domain, in: listed) else { return nil }
        return domain
    }
}

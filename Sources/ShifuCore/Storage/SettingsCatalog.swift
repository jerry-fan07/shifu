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

/// Groups settings in the UI. A new group is one case.
public enum SettingsSection: String, CaseIterable, Sendable {
    case capture = "Capture"
    case analysis = "Analysis"
    case workMode = "Work Mode"
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

    public enum Unit: Sendable { case seconds, minutes }

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

    public var id: String { key }

    public init(key: String, section: SettingsSection, title: String, help: String,
                options: [Option], defaultValue: String) {
        self.key = key
        self.section = section
        self.title = title
        self.help = help
        self.options = options
        self.defaultValue = defaultValue
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

    public static let workModeDistractingDomains = DomainListSetting(
        key: "workmode.distracting_domains", section: .workMode,
        title: "Distracting sites",
        help: "Visiting these during Work Mode triggers the glow. Your ledger "
            + "categories are unchanged. Takes effect the next time Work Mode turns on.",
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

    public static let ints: [IntSetting] = [heartbeatSeconds, analysisIntervalSeconds]
    public static let domainLists: [DomainListSetting] = [workModeDistractingDomains]
    public static let choices: [ChoiceSetting] = [analysisBackend]
    public static let texts: [TextSetting] = [
        deepseekAPIKey, deepseekBaseURL, deepseekModel, deepseekReasoningModel
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

    /// Work Mode's off-task decision for one capture (design.md §4.4): returns
    /// the listed domain that matched, or nil when this capture isn't off-task.
    ///
    /// Excluded captures are opaque private time and are never nagged (§13.5) —
    /// that guard is the whole reason this lives here rather than inline in
    /// `WorkModeController`: `shifud` has no test target, and whether a private
    /// window can trigger a nudge is exactly the kind of thing a test should pin.
    public static func distracting(
        domain: String?, excluded: Bool, listed: Set<String>
    ) -> String? {
        guard !excluded, let domain, matches(domain, in: listed) else { return nil }
        return domain
    }
}

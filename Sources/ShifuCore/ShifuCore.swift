import Foundation

/// ShifuCore — shared models, storage, and pure logic for all Shifu binaries.
/// See design.md §2 for the process architecture.
public enum Shifu {
    /// Marketing version — the About page, `--version`, the daemon's first log
    /// line, and the `app_version` we send the cloud proxy all read this.
    /// Inside the app bundle the stamped Info.plist wins, so a shipped build
    /// cannot report a version other than the one it was cut as. The four
    /// helpers live in Contents/MacOS, so `Bundle.main` is the .app for them
    /// too; only a bare binary (`swift run`, ~/Shifu/bin) falls back.
    public static let version: String = {
        guard Bundle.main.bundleIdentifier == "com.shifu.app",
              let stamped = Bundle.main
                  .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !stamped.isEmpty
        else { return fallbackVersion }
        return stamped
    }()

    /// Compiled in for unbundled binaries, and the number scripts/bundle-app.sh
    /// stamps into the plist — so this literal is where a release is bumped.
    /// That script parses this line: keep it a plain string.
    static let fallbackVersion = "0.1.2"
}

/// Which Shifu this build is sold as (design.md §4.2): one codebase, two
/// bundles. The standard bundle offers the hosted tiers; the Qwen bundle
/// offers only the local one — Qwen in place of the cloud server and API
/// keys, nothing to send anything to. The difference is a stamped Info.plist
/// key, not a fork: bundle-app.sh writes `ShifuEdition` the same way it
/// stamps the version, and every binary in the bundle reads it back here.
/// The edition gates which backend *choices exist* — the tier code itself is
/// shared, so main's changes reach both bundles by ordinary merge.
public enum Edition: String, Sendable {
    case standard
    case qwen

    /// Resolved once per process: the SHIFU_EDITION environment variable
    /// (how a dev build or test run becomes the Qwen edition without
    /// assembling a bundle), else the stamped plist, else standard.
    public static let current: Edition = resolve(
        environment: ProcessInfo.processInfo.environment,
        stamped: Bundle.main.bundleIdentifier == "com.shifu.app"
            ? Bundle.main.object(forInfoDictionaryKey: "ShifuEdition") as? String : nil)

    static func resolve(environment: [String: String], stamped: String?) -> Edition {
        if let forced = environment["SHIFU_EDITION"].flatMap(Edition.init(rawValue:)) {
            return forced
        }
        return stamped.flatMap(Edition.init(rawValue:)) ?? .standard
    }

    /// The `analysis.backend` values this edition offers, in display order.
    /// A stored value outside this list reads as rules-only, never as some
    /// other backend — a database that has seen the other edition must not
    /// silently reroute its text to an endpoint the user never chose here.
    public var analysisBackends: [String] {
        switch self {
        case .standard: return ["shifu-cloud", "deepseek", "off"]
        case .qwen: return ["local", "off"]
        }
    }

    /// What an untouched install's backend row means. Standard keeps
    /// "deepseek" (the stored identifier the key-as-opt-in era wrote);
    /// the Qwen edition starts rules-only until the user points it at
    /// their server.
    public var defaultAnalysisBackend: String {
        switch self {
        case .standard: return "deepseek"
        case .qwen: return "off"
        }
    }
}

/// The hosted LLM proxy (server/ in this repo). Constants only — the client
/// that talks to it lives in shifu-analyzer, the one binary allowed to touch
/// the network (§8).
public enum ShifuCloudDefaults {
    /// Where the proxy is deployed.
    public static let baseURL = "https://shifu-cloud.shifuapp.workers.dev"
}

/// The local tier (§4.2): an OpenAI-compatible model server the user runs
/// themselves. Constants only, for the same reason as `ShifuCloudDefaults` —
/// the client lives in shifu-analyzer.
public enum LocalLLMDefaults {
    /// llama-server's stock address.
    public static let baseURL = "http://127.0.0.1:8080"
    /// What the wire's `model` field claims when the user hasn't named one.
    /// llama-server serves whatever it loaded regardless; routers that pick
    /// a model by name (Ollama, LM Studio) need the real one typed in.
    public static let model = "qwen3.5-9b"
    /// Prompt + response window every stage sizes its batches to (invariant
    /// 7) — the 16k the 2026-07-31 spike actually served, not DeepSeek's 60k.
    public static let contextWindowTokens = 16_000
}

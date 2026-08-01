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
    static let fallbackVersion = "0.1.1"
}

/// The hosted LLM proxy (server/ in this repo). Constants only — the client
/// that talks to it lives in shifu-analyzer, the one binary allowed to touch
/// the network (§8).
public enum ShifuCloudDefaults {
    /// Where the proxy is deployed.
    public static let baseURL = "https://shifu-cloud.shifuapp.workers.dev"
}

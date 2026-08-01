/// ShifuCore — shared models, storage, and pure logic for all Shifu binaries.
/// See design.md §2 for the process architecture.
public enum Shifu {
    public static let version = "0.1.0"
}

/// The hosted LLM proxy (server/ in this repo). Constants only — the client
/// that talks to it lives in shifu-analyzer, the one binary allowed to touch
/// the network (§8).
public enum ShifuCloudDefaults {
    /// Where the proxy is deployed.
    public static let baseURL = "https://shifu-cloud.shifuapp.workers.dev"
}

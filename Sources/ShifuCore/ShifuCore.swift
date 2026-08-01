/// ShifuCore — shared models, storage, and pure logic for all Shifu binaries.
/// See design.md §2 for the process architecture.
public enum Shifu {
    public static let version = "0.1.0"
}

/// The hosted LLM proxy (server/ in this repo). Constants only — the client
/// that talks to it lives in shifu-analyzer, the one binary allowed to touch
/// the network (§8).
public enum ShifuCloudDefaults {
    /// Where the proxy is deployed. Placeholder until the Worker in server/
    /// is deployed under the real domain; overridable at runtime via the
    /// shifu_cloud.base_url setting either way.
    public static let baseURL = "https://api.shifu.jerryfan.dev"
}

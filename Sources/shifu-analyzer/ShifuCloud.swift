import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShifuCore

/// Client for the hosted Shifu Cloud proxy (server/ in this repo): resolves
/// its endpoint and mints the device token that authenticates the analyzer's
/// /chat/completions calls, so a user never handles an API key. Analyzer-only
/// for the same reason as DeepSeekBackend — network symbols must never link
/// into shifud (CLAUDE.md invariant 1).
///
/// The token is not the opt-in and never gates privacy: nothing reaches this
/// code unless the user chose the "shifu-cloud" backend (§8), and everything
/// sent through the proxy is the same post-exclusion, post-redaction text the
/// direct DeepSeek path sends.
enum ShifuCloud {
    /// The proxy endpoint: the shifu_cloud.base_url setting, defaulting to
    /// the built-in deployment. Trailing slash trimmed like deepseek.base_url.
    static func baseURL(database: ShifuDatabase) -> String {
        let raw = (try? Settings.get(Settings.shifuCloudBaseURLKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? ShifuCloudDefaults.baseURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Returns the stored device token, registering with the proxy to mint
    /// one the first time. Nil when registration fails (offline, proxy down):
    /// callers skip their LLM stages exactly as a keyless install does, and
    /// the next hourly run retries — never fatal, like every other backend
    /// failure (design.md §10).
    static func ensureToken(database: ShifuDatabase) async -> String? {
        if case .shifuCloud(let stored?) = (try? Settings.llmCredential(database: database)) ?? nil {
            return stored
        }
        guard let url = URL(string: baseURL(database: database) + "/v1/register") else {
            print("shifu cloud: bad base URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "platform": "macos",
            "app_version": Shifu.version
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String, !token.isEmpty else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("shifu cloud: registration failed (HTTP \(status)) — retrying next run")
                return nil
            }
            try Settings.set(Settings.shifuCloudTokenKey, to: token, database: database)
            print("shifu cloud: registered this Mac")
            return token
        } catch {
            print("shifu cloud: registration failed (\(error)) — retrying next run")
            return nil
        }
    }
}

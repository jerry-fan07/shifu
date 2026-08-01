import Foundation
import ShifuCore

/// The Qwen edition's server lifecycle (design.md §4.2): when the local tier
/// is chosen, the stock loopback endpoint is configured, and downloaded
/// weights plus a bundled llama-server exist, the analyzer brings the server
/// up for the length of its run and takes it down after — 6 GB of RSS is a
/// working set, not furniture. Analyzer-only for the same reason as the wire
/// client above it: probing and spawning a loopback server is this binary's
/// business, and shifud must never link any of it.
///
/// A server that is already answering is used, never owned — unless the pid
/// file says an earlier run spawned it and died before its stop, in which
/// case it is adopted and torn down like our own. A custom `local.base_url`
/// disables all of this: the user runs that server, and the §4.2 contract —
/// "state what the server serves and the pipeline adapts" — stays theirs.
enum LlamaServer {
    /// A running server this run is responsible for stopping — one this run
    /// spawned, or (`process` nil) an orphan a crashed run left behind,
    /// re-owned through its recorded pid.
    final class Handle {
        private let process: Process?
        private let pid: Int32

        fileprivate init(spawned: Process) {
            process = spawned
            pid = spawned.processIdentifier
        }

        fileprivate init(adoptedPid: Int32) {
            process = nil
            pid = adoptedPid
        }

        func stop() {
            if let process {
                process.terminate()
                process.waitUntilExit()
            } else {
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: LlamaServer.pidFile)
        }
    }

    /// Where a spawned server's pid is recorded, so a crashed run's orphan is
    /// adopted and stopped by the next run instead of holding 6 GB forever.
    static var pidFile: URL { ShifuPaths.home.appendingPathComponent("llama-server.pid") }

    /// Loading 5.7 GB of weights off a cold disk is tens of seconds; past
    /// two minutes the server is not coming up and the run proceeds to fail
    /// soft, stage by stage, exactly as with no server at all (§10).
    static let startupTimeout: TimeInterval = 120

    /// Brings the local server up if this run needs one, and hands back the
    /// obligation to stop it. Nil means nothing to stop: not the local tier,
    /// a user-run server answering (or configured), or no weights/binary —
    /// every LLM stage then fails soft as it always has.
    static func startIfNeeded(database: ShifuDatabase) async -> Handle? {
        guard ((try? Settings.llmCredential(database: database)) ?? nil) == .localServer else {
            return nil
        }
        let base = (try? Settings.get(Settings.localBaseURLKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? LocalLLMDefaults.baseURL
        // A custom endpoint is the user's server, wherever it runs. Only the
        // stock loopback is ours to manage.
        guard base == LocalLLMDefaults.baseURL else { return nil }

        if await healthy(baseURL: base) {
            // Answering already: an orphan of ours (pid file survives a
            // crash) is adopted; anything else is the user's and stays up.
            let orphan = recordedPid()
            if orphan > 0, kill(orphan, 0) == 0 {
                print("local model: adopting llama-server left by an earlier run")
                return Handle(adoptedPid: orphan)
            }
            return nil
        }

        guard let tier = LocalModel.installedTier(),
              let binary = ShifuPaths.helper("llama-server")
        else { return nil }
        return await spawn(
            tier: tier, binary: binary, base: base,
            contextTokens: DeepSeekBackend.localContextWindow(database: database))
    }

    /// Launch, record the pid, and wait out the load. Nil when the server
    /// never got healthy — it is stopped again, and the run proceeds to fail
    /// soft exactly as with no server at all.
    private static func spawn(
        tier: LocalModel.Tier, binary: URL, base: String, contextTokens: Int
    ) async -> Handle? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments(
            weightsPath: LocalModel.weightsURL(for: tier).path,
            contextTokens: contextTokens)
        // The server's own log is noise here; the analyzer's log stays the
        // analyzer's. Load failures surface as the health timeout below.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("local model: llama-server failed to launch: \(error)")
            return nil
        }
        try? String(process.processIdentifier).write(
            to: pidFile, atomically: true, encoding: .utf8)

        let started = Date()
        while Date().timeIntervalSince(started) < startupTimeout {
            if await healthy(baseURL: base) {
                print(String(
                    format: "local model: %@ up in %.1fs",
                    tier.displayName, Date().timeIntervalSince(started)))
                return Handle(spawned: process)
            }
            if !process.isRunning {
                print("local model: llama-server exited during load — check the weights")
                try? FileManager.default.removeItem(at: pidFile)
                return nil
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        print("local model: llama-server not healthy after \(Int(startupTimeout))s — "
            + "stopping it; stages will skip")
        process.terminate()
        try? FileManager.default.removeItem(at: pidFile)
        return nil
    }

    /// The launch line, pure for the test that pins it: the §4.2 profile —
    /// the window every stage sizes to, one slot (the analyzer is a single
    /// sequential caller), everything offloaded, and the small prefill
    /// bursts (`-ub 256 -b 512`) design.md prescribes for power draw.
    static func arguments(weightsPath: String, contextTokens: Int) -> [String] {
        [
            "-m", weightsPath,
            "-c", String(contextTokens),
            "--host", "127.0.0.1",
            "--port", "8080",
            "--parallel", "1",
            "-ngl", "999",
            "-ub", "256",
            "-b", "512",
            // Thinking always off on the local tier (§4.2). Enforced at the
            // server because the wire can't: the analyzer's `thinking:
            // disabled` field is DeepSeek's dialect, which llama-server
            // ignores — measured 2026-08-01, a 10-token budget came back all
            // reasoning and no answer.
            "--reasoning", "off",
            "--no-webui"
        ]
    }

    /// llama-server answers /health 200 once the model is loaded, 503 while
    /// loading — only 200 counts, or the first completion call would race
    /// the load it was waiting out.
    static func healthy(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func recordedPid() -> Int32 {
        guard let raw = try? String(contentsOf: pidFile, encoding: .utf8) else { return 0 }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

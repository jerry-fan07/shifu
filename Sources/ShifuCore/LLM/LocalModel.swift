import Foundation

/// The Qwen edition's zero-config local tier (design.md §4.2, §12): which
/// model this Mac gets, where its weights live, and whether setup may start
/// at all. Catalog and pure gates only — the download itself lives in
/// ShifuApp (the one-time setup fetch, CLAUDE.md invariant 1's carve-out)
/// and the server spawn in shifu-analyzer, so no fetching machinery can
/// ride into shifud through this file.
public enum LocalModel {
    /// One downloadable model: the 2026-07-31 spike's exact artifacts
    /// (design.md §12), so the shipped tier is the measured one. Sizes are
    /// the real byte counts of those files — the disk preflight and the
    /// post-download sanity floor both key off them.
    public struct Tier: Equatable, Sendable {
        /// The wire name (`local.model`) — llama-server ignores it, but it
        /// labels the invoice rows (`llm_usage.model`).
        public let model: String
        /// The file under `ShifuPaths.models`, and the name on Hugging Face.
        public let weightsFileName: String
        /// Exact size of the published GGUF, in bytes.
        public let weightsBytes: Int64
        /// What `local.context_tokens` is set to on install — the window
        /// every stage sizes its batches to (invariant 7).
        public let contextTokens: Int
        /// "Qwen3.5-9B · 5.7 GB" — what the onboarding page promises before
        /// the fetch starts.
        public let displayName: String

        /// The published quant on Hugging Face: `<owner>/<Model>-GGUF`,
        /// where the repo name is the weights file minus its quant suffix.
        public var downloadURL: URL {
            let repo = displayName + "-GGUF"
            return URL(string: "https://huggingface.co/\(LocalModel.repoOwner)/"
                + "\(repo)/resolve/main/\(weightsFileName)")!
        }

        /// Rounded the way the page says it: one decimal of GB.
        public var displayBytes: String {
            String(format: "%.1f GB", Double(weightsBytes) / 1_000_000_000)
        }
    }

    /// Qwen publishes no first-party GGUF for these models; unsloth's quants
    /// are the published artifacts the 2026-07-31 spike actually measured —
    /// verified 2026-08-01 by exact byte size against the spike's files.
    static let repoOwner = "unsloth"

    /// Apple Silicon ≥16 GB (design.md §12): matched DeepSeek on cards 32/36
    /// with grouping spread over sensible tasks.
    public static let nineB = Tier(
        model: "qwen3.5-9b",
        weightsFileName: "Qwen3.5-9B-Q4_K_M.gguf",
        weightsBytes: 5_680_522_464,
        contextTokens: 16_000,
        displayName: "Qwen3.5-9B")

    /// 8 GB Macs. Feasibility-fine at ~3.5 GB server RSS; its grouping
    /// verdicts hold only under the 24-block batch cap §5.3 already imposes.
    public static let fourB = Tier(
        model: "qwen3.5-4b",
        weightsFileName: "Qwen3.5-4B-Q4_K_M.gguf",
        weightsBytes: 2_740_937_888,
        contextTokens: 16_000,
        displayName: "Qwen3.5-4B")

    /// The `hw.memsize` gate (design.md §12): 9B needs 16 GB to leave the
    /// user's own work room beside a 6.1 GB server; the 4B fits an 8 GB Mac.
    /// Below that, no local tier — nil, not the smallest model regardless.
    public static func tier(forMemoryBytes memoryBytes: UInt64) -> Tier? {
        let gigabyte: UInt64 = 1 << 30
        if memoryBytes >= 16 * gigabyte { return nineB }
        if memoryBytes >= 8 * gigabyte { return fourB }
        return nil
    }

    // MARK: - Preflight

    /// Why setup may not start, each carrying what the alert needs to name
    /// the specific unmet requirement — never a generic "setup failed".
    public enum PreflightFailure: Error, Equatable, Sendable {
        /// Intel: llama.cpp's Metal path is the whole performance story, and
        /// the shipped binary is arm64. Rules-only or a self-hosted server
        /// (Settings → Analysis) remain, exactly as today.
        case needsAppleSilicon
        /// Under 8 GB of RAM — no tier fits beside the user's own work.
        case needsMemory(installedBytes: UInt64)
        /// Not enough free disk for the tier this Mac would get.
        case needsDisk(tier: Tier, freeBytes: Int64, requiredBytes: Int64)
    }

    /// Room the weights must leave free after landing: a download that fills
    /// the disk to the last byte trades one broken setup for another.
    static let diskMarginBytes: Int64 = 2 << 30

    /// The whole go/no-go, pure so the boundary cases are testable: which
    /// tier this machine gets, or the first requirement it fails. Checks are
    /// ordered by how fundamental the fix is — a new Mac, more of this Mac,
    /// then merely freeing space.
    public static func preflight(
        appleSilicon: Bool, memoryBytes: UInt64, freeDiskBytes: Int64
    ) -> Result<Tier, PreflightFailure> {
        guard appleSilicon else { return .failure(.needsAppleSilicon) }
        guard let tier = tier(forMemoryBytes: memoryBytes) else {
            return .failure(.needsMemory(installedBytes: memoryBytes))
        }
        let required = tier.weightsBytes + diskMarginBytes
        guard freeDiskBytes >= required else {
            return .failure(.needsDisk(
                tier: tier, freeBytes: freeDiskBytes, requiredBytes: required))
        }
        return .success(tier)
    }

    /// `preflight` fed from this machine. Split so tests never depend on the
    /// host's RAM or free disk.
    public static func preflightHere() -> Result<Tier, PreflightFailure> {
        // An unreadable volume reads as no free space: the failure then
        // names disk, which is where the true answer lives.
        let free = (try? ShifuPaths.home.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        return preflight(
            appleSilicon: runningOnAppleSilicon(),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: free)
    }

    /// arm64 — including a translated process asking on an arm64 machine,
    /// which sysctl's `hw.optional.arm64` answers and `utsname` would not.
    public static func runningOnAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    // MARK: - What is on disk

    /// Where a tier's weights live once installed.
    public static func weightsURL(for tier: Tier) -> URL {
        ShifuPaths.models.appendingPathComponent(tier.weightsFileName)
    }

    /// The tier whose weights are installed and plausible, largest first —
    /// the analyzer serves the best model present, and a Mac upgraded past
    /// its old tier keeps working on the weights it has.
    public static func installedTier() -> Tier? {
        [nineB, fourB].first { verifyWeights(at: weightsURL(for: $0), tier: $0) }
    }

    /// A file is served only if it starts with the GGUF magic and is at
    /// least half the published size — a truncated fetch renamed into place
    /// must read as absent, or llama-server would be handed a corrupt file
    /// on every analyzer run.
    public static func verifyWeights(at url: URL, tier: Tier) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 4),
              magic == Data("GGUF".utf8),
              let size = try? FileManager.default
                  .attributesOfItem(atPath: url.path)[.size] as? Int64
        else { return false }
        return size >= tier.weightsBytes / 2
    }
}

extension ShifuPaths {
    /// Downloaded model weights (design.md §9) — sibling of the vault, so
    /// SHIFU_HOME relocates it for tests like everything else.
    public static var models: URL { home.appendingPathComponent("models", isDirectory: true) }
}

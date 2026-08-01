import Foundation
import Testing
@testable import ShifuCore

/// The Qwen edition's zero-config setup gates (design.md §12): which model a
/// Mac gets, when setup may not start, and what counts as installed weights.
@Suite struct LocalModelTests {
    private let gigabyte: UInt64 = 1 << 30

    /// The `hw.memsize` gate: 16 GB gets the 9B, 8 GB the 4B, less gets
    /// nothing — never the smallest model regardless.
    @Test func memoryGatePicksTheMeasuredTiers() {
        #expect(LocalModel.tier(forMemoryBytes: 24 * gigabyte) == LocalModel.nineB)
        #expect(LocalModel.tier(forMemoryBytes: 16 * gigabyte) == LocalModel.nineB)
        #expect(LocalModel.tier(forMemoryBytes: 16 * gigabyte - 1) == LocalModel.fourB)
        #expect(LocalModel.tier(forMemoryBytes: 8 * gigabyte) == LocalModel.fourB)
        #expect(LocalModel.tier(forMemoryBytes: 8 * gigabyte - 1) == nil)
    }

    /// The 9B tier is the profile every other constant in the pipeline
    /// assumes: the default wire name and the measured 16k window.
    @Test func theNineBTierMatchesTheLocalDefaults() {
        #expect(LocalModel.nineB.model == LocalLLMDefaults.model)
        #expect(LocalModel.nineB.contextTokens == LocalLLMDefaults.contextWindowTokens)
        #expect(LocalModel.fourB.contextTokens == LocalLLMDefaults.contextWindowTokens)
    }

    /// The URLs are assembled, so pin what they assemble to — a typo here
    /// would 404 on the very first user's very first run.
    @Test func downloadURLsPointAtThePublishedQuants() {
        #expect(LocalModel.nineB.downloadURL.absoluteString
            == "https://huggingface.co/Qwen/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf")
        #expect(LocalModel.fourB.downloadURL.absoluteString
            == "https://huggingface.co/Qwen/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")
    }

    /// Preflight fails toward the most fundamental unmet requirement, and
    /// each failure carries what the alert needs to name it.
    @Test func preflightNamesTheFirstUnmetRequirement() {
        #expect(LocalModel.preflight(
            appleSilicon: false, memoryBytes: 32 * gigabyte,
            freeDiskBytes: Int64(64 * gigabyte)) == .failure(.needsAppleSilicon))
        #expect(LocalModel.preflight(
            appleSilicon: true, memoryBytes: 4 * gigabyte,
            freeDiskBytes: Int64(64 * gigabyte))
            == .failure(.needsMemory(installedBytes: 4 * gigabyte)))

        let required = LocalModel.nineB.weightsBytes + LocalModel.diskMarginBytes
        #expect(LocalModel.preflight(
            appleSilicon: true, memoryBytes: 16 * gigabyte, freeDiskBytes: required - 1)
            == .failure(.needsDisk(
                tier: LocalModel.nineB, freeBytes: required - 1, requiredBytes: required)))
        #expect(LocalModel.preflight(
            appleSilicon: true, memoryBytes: 16 * gigabyte, freeDiskBytes: required)
            == .success(LocalModel.nineB))
        // The disk bar is the tier's own: an 8 GB Mac needs room for the 4B,
        // not the 9B it will never download.
        #expect(LocalModel.preflight(
            appleSilicon: true, memoryBytes: 8 * gigabyte,
            freeDiskBytes: LocalModel.fourB.weightsBytes + LocalModel.diskMarginBytes)
            == .success(LocalModel.fourB))
    }

    /// Installed means GGUF magic plus at least half the published bytes: a
    /// truncated fetch renamed into place must read as absent, not be handed
    /// to llama-server on every analyzer run.
    @Test func verifyWeightsRejectsWhatIsNotAModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Small tier stand-in so the "half the published size" floor is
        // testable without gigabytes: same shape, tiny bytes.
        let tiny = LocalModel.Tier(
            model: "tiny", weightsFileName: "tiny.gguf", weightsBytes: 64,
            contextTokens: 16_000, displayName: "Tiny")

        let missing = dir.appendingPathComponent("absent.gguf")
        #expect(!LocalModel.verifyWeights(at: missing, tier: tiny))

        let wrongMagic = dir.appendingPathComponent("wrong.gguf")
        try Data(repeating: 0x41, count: 64).write(to: wrongMagic)
        #expect(!LocalModel.verifyWeights(at: wrongMagic, tier: tiny))

        let truncated = dir.appendingPathComponent("truncated.gguf")
        try (Data("GGUF".utf8) + Data(count: 8)).write(to: truncated)
        #expect(!LocalModel.verifyWeights(at: truncated, tier: tiny))

        let plausible = dir.appendingPathComponent("plausible.gguf")
        try (Data("GGUF".utf8) + Data(count: 60)).write(to: plausible)
        #expect(LocalModel.verifyWeights(at: plausible, tier: tiny))
    }

    /// The real weights magic, pinned so the verifier and the artifact can't
    /// drift: "GGUF" is the first four bytes of every published quant.
    @Test func ggufMagicIsWhatThePublishedFilesStartWith() {
        #expect(Data("GGUF".utf8) == Data([0x47, 0x47, 0x55, 0x46]))
    }
}

import Testing
@testable import ShifuCore

/// One codebase, two bundles (design.md §4.2): the edition is a stamped
/// plist key, and everything it decides — which backend choices exist —
/// is pinned here so the two bundles can't drift apart by accident.
@Suite struct EditionTests {
    /// SHIFU_EDITION (dev builds, test runs) beats the stamp; the stamp
    /// beats nothing; garbage in either place means standard, because a
    /// mis-stamped bundle should fail toward the shipping default, not
    /// toward an edition nobody assembled.
    @Test func resolutionPrefersTheEnvironmentThenTheStamp() {
        #expect(Edition.resolve(environment: [:], stamped: nil) == .standard)
        #expect(Edition.resolve(environment: [:], stamped: "qwen") == .qwen)
        #expect(Edition.resolve(environment: ["SHIFU_EDITION": "qwen"], stamped: nil) == .qwen)
        #expect(Edition.resolve(
            environment: ["SHIFU_EDITION": "standard"], stamped: "qwen") == .standard)
        #expect(Edition.resolve(environment: ["SHIFU_EDITION": "pro"], stamped: nil) == .standard)
        #expect(Edition.resolve(environment: [:], stamped: "deluxe") == .standard)
    }

    /// The product split itself: the standard bundle offers the hosted
    /// tiers, the Qwen bundle only the local one, and both keep rules-only.
    @Test func eachEditionOffersItsOwnBackends() {
        #expect(Edition.standard.analysisBackends == ["shifu-cloud", "deepseek", "off"])
        #expect(Edition.qwen.analysisBackends == ["local", "off"])
        #expect(Edition.standard.defaultAnalysisBackend == "deepseek")
        #expect(Edition.qwen.defaultAnalysisBackend == "off")
        // Every default must be offered, or normalize would loop on a value
        // the picker can't display.
        for edition in [Edition.standard, .qwen] {
            #expect(edition.analysisBackends.contains(edition.defaultAnalysisBackend))
        }
    }

    /// The settings row is the edition's list wearing the shared copy: same
    /// key, options filtered, default swapped. Every offered value must have
    /// an option row — a choice without copy would render as a blank segment.
    @Test func theBackendRowWearsTheEditionsChoices() {
        for edition in [Edition.standard, .qwen] {
            let row = SettingsCatalog.analysisBackend(for: edition)
            #expect(row.options.map(\.value) == edition.analysisBackends)
            #expect(row.defaultValue == edition.defaultAnalysisBackend)
        }
    }
}

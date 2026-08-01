import Testing
@testable import ShifuCore

/// The consent gate (design.md §8): `Settings.llmCredential` is the one
/// answer both binaries consult before anything can leave the machine, so
/// its off-by-default shape is pinned here. The deepseek branch is not
/// asserted key-absent because the DEEPSEEK_API_KEY environment variable
/// legitimately overrides settings on dev machines.
@Suite struct LLMCredentialTests {
    @Test func offMeansNoCredentialEver() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "off", database: database)
        // Even with leftovers from an earlier opt-in: off is off.
        try Settings.set(Settings.deepseekAPIKeyKey, to: "sk-left-behind", database: database)
        try Settings.set(Settings.shifuCloudTokenKey, to: "st-left-behind", database: database)
        #expect(try Settings.llmCredential(database: database) == nil)
    }

    /// Choosing the hosted backend is itself the opt-in — the credential
    /// exists before any token does, with the token minted later by the
    /// analyzer.
    @Test func cloudChoiceIsTheOptInBeforeAnyTokenExists() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "shifu-cloud", database: database)
        #expect(try Settings.llmCredential(database: database) == .shifuCloud(token: nil))

        try Settings.set(Settings.shifuCloudTokenKey, to: "st-device", database: database)
        #expect(try Settings.llmCredential(database: database) == .shifuCloud(token: "st-device"))
    }

    /// The local tier needs nothing beyond the choice: no key, no token —
    /// the endpoint is a server the user runs, and both binaries must read
    /// "an LLM backend exists" from the choice alone.
    @Test func localChoiceIsAnOptInWithNoCredentialAtAll() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "local", database: database)
        #expect(try Settings.llmCredential(database: database, edition: .qwen) == .localServer)
    }

    /// One ~/Shifu may meet both bundles. A stored backend the running
    /// edition doesn't offer must read as rules-only, never as some other
    /// backend: the standard bundle honoring "local" would call an endpoint
    /// it never surfaced, and the Qwen bundle rerouting to DeepSeek over a
    /// leftover key would be an opt-in nobody made.
    @Test func aBackendTheEditionDoesNotOfferReadsAsRulesOnly() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.deepseekAPIKeyKey, to: "sk-left-behind", database: database)
        try Settings.set(Settings.shifuCloudTokenKey, to: "st-left-behind", database: database)

        try Settings.set(Settings.analysisBackendKey, to: "local", database: database)
        #expect(try Settings.llmCredential(database: database, edition: .standard) == nil)

        for hosted in ["deepseek", "shifu-cloud"] {
            try Settings.set(Settings.analysisBackendKey, to: hosted, database: database)
            #expect(try Settings.llmCredential(database: database, edition: .qwen) == nil,
                    "stored \(hosted)")
        }
    }

    /// An untouched Qwen-edition install is rules-only — even under the
    /// DEEPSEEK_API_KEY environment variable, which on the standard edition
    /// legitimately stands in for a pasted key.
    @Test func aFreshQwenInstallHasNoCredential() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(try Settings.llmCredential(database: database, edition: .qwen) == nil)
    }

    @Test func ownKeyIsStillAnOptIn() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "deepseek", database: database)
        try Settings.set(Settings.deepseekAPIKeyKey, to: "sk-mine", database: database)
        guard case .deepseek(let key)? = try Settings.llmCredential(database: database) else {
            Issue.record("expected a deepseek credential")
            return
        }
        // The env var may override the value, but never the branch.
        #expect(!key.isEmpty)
    }
}

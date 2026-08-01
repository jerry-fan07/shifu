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

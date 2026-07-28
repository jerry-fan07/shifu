import Testing
@testable import ShifuCore

@Suite struct SettingsCatalogTests {
    private let heartbeat = SettingsCatalog.heartbeatSeconds
    private let sites = SettingsCatalog.workModeDistractingDomains

    // MARK: - Bounds

    @Test func clampPinsToRange() {
        #expect(heartbeat.clamp(1) == heartbeat.range.lowerBound)
        #expect(heartbeat.clamp(10_000) == heartbeat.range.upperBound)
        #expect(heartbeat.clamp(90) == 90)
    }

    /// The catalog is the only place bounds are stated, so a new entry whose
    /// default sits outside its own range would silently ship a value the
    /// daemon immediately clamps away. Guards every present and future entry.
    @Test func everyDefaultIsInsideItsOwnRange() {
        for setting in SettingsCatalog.ints {
            #expect(setting.range.contains(setting.defaultValue), "\(setting.key)")
        }
    }

    @Test func keysAreUnique() {
        let keys = SettingsCatalog.ints.map(\.key) + SettingsCatalog.domainLists.map(\.key)
            + SettingsCatalog.choices.map(\.key) + SettingsCatalog.texts.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    // MARK: - Choice & text settings (AI backend config)

    @Test func choiceNormalizesUnknownValuesToDefault() throws {
        let backend = SettingsCatalog.analysisBackend
        #expect(backend.normalize("off") == "off")
        #expect(backend.normalize("banana") == "deepseek")

        let db = try ShifuDatabase.inMemory()
        #expect(Settings.value(backend, database: db) == "deepseek")   // missing
        try Settings.set(backend.key, to: "banana", database: db)      // hand-edited row
        #expect(Settings.value(backend, database: db) == "deepseek")
        try Settings.set(backend, to: "off", database: db)
        #expect(Settings.value(backend, database: db) == "off")
    }

    @Test func textSettingTrimsAndDefaultsToEmpty() throws {
        let db = try ShifuDatabase.inMemory()
        let key = SettingsCatalog.deepseekAPIKey
        #expect(Settings.value(key, database: db).isEmpty)
        try Settings.set(key, to: "  sk-secret \n", database: db)
        #expect(Settings.value(key, database: db) == "sk-secret")
    }

    /// Every gated text row must point at a real choice setting and one of
    /// its options — a typo here would silently hide a field forever.
    @Test func visibilityGatesReferenceRealChoices() {
        for text in SettingsCatalog.texts {
            guard let gate = text.visibleWhen else { continue }
            let choice = SettingsCatalog.choices.first { $0.key == gate.key }
            #expect(choice != nil)
            #expect(choice?.options.contains { $0.value == gate.value } == true)
        }
    }

    // MARK: - Int round-trip

    @Test func missingValueFallsBackToDefault() throws {
        let db = try ShifuDatabase.inMemory()
        #expect(Settings.value(heartbeat, database: db) == heartbeat.defaultValue)
    }

    @Test func garbageValueFallsBackToDefault() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(heartbeat.key, to: "not a number", database: db)
        #expect(Settings.value(heartbeat, database: db) == heartbeat.defaultValue)
    }

    @Test func roundTripReturnsStoredValue() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(heartbeat, to: 120, database: db)
        #expect(Settings.value(heartbeat, database: db) == 120)
    }

    @Test func writesAreClamped() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(heartbeat, to: 5, database: db)
        #expect(Settings.value(heartbeat, database: db) == heartbeat.range.lowerBound)
    }

    /// A hand-edited row (or a future CLI writer) can't escape the bounds
    /// either — reads clamp too, so the daemon never sees an out-of-range value.
    @Test func outOfRangeRowIsClampedOnRead() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(heartbeat.key, to: "1", database: db)
        #expect(Settings.value(heartbeat, database: db) == heartbeat.range.lowerBound)
    }

    // MARK: - Domain normalization

    @Test func normalizeStripsSchemeHostDecorationAndPath() {
        #expect(sites.normalize("https://www.Reddit.com/r/swift") == "reddit.com")
        #expect(sites.normalize("  YouTube.com  ") == "youtube.com")
        #expect(sites.normalize("example.com:8080") == "example.com")
        #expect(sites.normalize("http://news.ycombinator.com/item?id=1") == "news.ycombinator.com")
    }

    @Test func normalizeRejectsUnusableInput() {
        #expect(sites.normalize("") == nil)
        #expect(sites.normalize("   ") == nil)
        #expect(sites.normalize("localhost") == nil)      // no dot
        #expect(sites.normalize("two words.com") == nil)
        #expect(sites.normalize(".com") == nil)
        #expect(sites.normalize("trailing.") == nil)
    }

    // MARK: - Domain list round-trip

    @Test func domainListRoundTripsNormalized() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(sites, to: ["https://www.Reddit.com/r/x", "Twitch.tv"], database: db)
        #expect(Settings.value(sites, database: db) == ["reddit.com", "twitch.tv"])
    }

    @Test func domainListDropsDuplicatesAndJunk() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(sites, to: ["reddit.com", "www.reddit.com", "", "nope"], database: db)
        #expect(Settings.value(sites, database: db) == ["reddit.com"])
    }

    @Test func emptyDomainListReadsAsEmpty() throws {
        let db = try ShifuDatabase.inMemory()
        #expect(Settings.value(sites, database: db).isEmpty)
    }

    // MARK: - Matching

    @Test func matcherHitsExactAndParentDomains() {
        let listed: Set<String> = ["reddit.com", "news.ycombinator.com"]
        #expect(DomainMatcher.matches("reddit.com", in: listed))
        #expect(DomainMatcher.matches("old.reddit.com", in: listed))
        #expect(DomainMatcher.matches("news.ycombinator.com", in: listed))
    }

    @Test func matcherIgnoresUnlistedAndLookalikeDomains() {
        let listed: Set<String> = ["reddit.com"]
        #expect(!DomainMatcher.matches("github.com", in: listed))
        #expect(!DomainMatcher.matches("notreddit.com", in: listed))
        #expect(!DomainMatcher.matches("reddit.com.evil.net", in: listed))
        #expect(!DomainMatcher.matches("reddit.com", in: []))
    }

    // MARK: - Work Mode off-task decision

    @Test func listedSiteIsDistractingIncludingSubdomains() {
        let listed: Set<String> = ["reddit.com"]
        #expect(DomainMatcher.distracting(
            domain: "reddit.com", excluded: false, listed: listed) == "reddit.com")
        #expect(DomainMatcher.distracting(
            domain: "old.reddit.com", excluded: false, listed: listed) == "old.reddit.com")
    }

    @Test func unlistedSiteIsNotDistracting() {
        #expect(DomainMatcher.distracting(
            domain: "github.com", excluded: false, listed: ["reddit.com"]) == nil)
        #expect(DomainMatcher.distracting(
            domain: "reddit.com", excluded: false, listed: []) == nil)
    }

    /// Private/excluded browsing is opaque and must never trigger a nudge, even
    /// when the domain is listed (design.md §13.5).
    @Test func excludedCaptureIsNeverDistracting() {
        #expect(DomainMatcher.distracting(
            domain: "reddit.com", excluded: true, listed: ["reddit.com"]) == nil)
    }

    /// Non-browser captures carry no URL; they're judged by the classifier, not
    /// by this list.
    @Test func captureWithoutDomainIsNotDistracting() {
        #expect(DomainMatcher.distracting(
            domain: nil, excluded: false, listed: ["reddit.com"]) == nil)
    }

    /// End-to-end: what the Settings window stores must match what the daemon
    /// derives from a live browser URL via `Sessionizer.domain(of:)`. This is
    /// the join the feature actually depends on — the two normalizations are
    /// written in different files and could drift apart.
    @Test func storedSettingMatchesLiveBrowserURL() throws {
        let db = try ShifuDatabase.inMemory()
        try Settings.set(sites, to: ["https://www.Reddit.com/"], database: db)
        let listed = Set(Settings.value(sites, database: db))

        let visited = Sessionizer.domain(of: "https://old.reddit.com/r/swift/comments/1")
        #expect(DomainMatcher.distracting(
            domain: visited, excluded: false, listed: listed) == "old.reddit.com")

        let unrelated = Sessionizer.domain(of: "https://github.com/apple/swift")
        #expect(DomainMatcher.distracting(
            domain: unrelated, excluded: false, listed: listed) == nil)
    }
}

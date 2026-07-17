import Testing
@testable import ShifuCore

@Suite struct RulesClassifierTests {
    private func block(
        bundle: String, domain: String? = nil, excluded: Bool = false
    ) -> Sessionizer.Block {
        Sessionizer.Block(appBundle: bundle, domain: domain, startedAt: 0, endedAt: 60_000,
                          observationIDs: [], titles: [], excluded: excluded)
    }

    @Test func knownAppClassifies() {
        let classifier = RulesClassifier()
        let result = classifier.classify(block: block(bundle: "com.apple.dt.Xcode"))
        #expect(result.category == .work)
        #expect(!result.ambiguous)
    }

    @Test func domainBeatsBundle() {
        let classifier = RulesClassifier()
        let result = classifier.classify(
            block: block(bundle: "com.apple.Safari", domain: "youtube.com"))
        #expect(result.category == .entertainment)
        #expect(result.ambiguous)   // youtube is a *-marked default (§4.2)
    }

    @Test func subdomainMatchesParentRule() {
        let classifier = RulesClassifier()
        let result = classifier.classify(
            block: block(bundle: "com.google.Chrome", domain: "gist.github.com"))
        #expect(result.category == .work)
    }

    @Test func unknownIsUnclassifiedAndAmbiguous() {
        let classifier = RulesClassifier()
        let result = classifier.classify(block: block(bundle: "com.random.app"))
        #expect(result.category == .unclassified)
        #expect(result.ambiguous)
    }

    @Test func excludedBlockIsPrivate() {
        let classifier = RulesClassifier()
        let result = classifier.classify(
            block: block(bundle: "com.1password.1password", excluded: true))
        #expect(result.category == .privateTime)
        #expect(!result.ambiguous)
    }

    @Test func userRuleOverridesSeed() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO rules (kind, value, category, ambiguous)
                VALUES ('domain', 'youtube.com', 'learning', 0)
                """)
        }
        let classifier = try RulesClassifier(database: db)
        let result = classifier.classify(
            block: block(bundle: "com.apple.Safari", domain: "youtube.com"))
        #expect(result.category == .learning)
        #expect(!result.ambiguous)
        #expect(result.source == "user")
    }
}

import Testing
@testable import ShifuCore

@Suite struct ExclusionsTests {
    @Test func passwordManagerExcluded() {
        let exclusions = Exclusions()
        #expect(exclusions.isExcluded(bundleID: "com.1password.1password"))
        #expect(!exclusions.isExcluded(bundleID: "com.apple.dt.Xcode"))
    }

    @Test func bankingDomainExcludedIncludingSubdomains() {
        let exclusions = Exclusions()
        #expect(exclusions.isExcluded(url: "https://chase.com/login"))
        #expect(exclusions.isExcluded(url: "https://secure.chase.com/account"))
        #expect(!exclusions.isExcluded(url: "https://notchase.com/x"))
        #expect(!exclusions.isExcluded(url: "https://developer.apple.com/docs"))
    }

    @Test func userExclusionsMergeFromDatabase() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            try sqlite.execute(
                sql: "INSERT INTO exclusions (kind, value) VALUES ('bundle', ?), ('domain', ?)",
                arguments: ["com.example.private", "Example-Health.org"]
            )
        }
        let exclusions = try Exclusions(database: db)
        #expect(exclusions.isExcluded(bundleID: "com.example.private"))
        #expect(exclusions.isExcluded(url: "https://portal.example-health.org/records"))
        // Defaults still present.
        #expect(exclusions.isExcluded(bundleID: "com.apple.keychainaccess"))
    }
}

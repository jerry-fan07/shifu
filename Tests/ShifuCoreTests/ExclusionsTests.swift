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

    // MARK: - Editing (the Settings page writes these rows)

    /// The join the Privacy page depends on: what it adds is what the daemon
    /// reads on its next capture. Written in two files, so worth pinning.
    @Test func addedRowsReachTheMergedList() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("com.example.private", kind: .bundle, database: db)
        try Exclusions.add("Example-Health.org", kind: .domain, database: db)

        let exclusions = try Exclusions(database: db)
        #expect(exclusions.isExcluded(bundleID: "com.example.private"))
        #expect(exclusions.isExcluded(url: "https://portal.example-health.org/records"))
    }

    /// Domains are compared lower-cased, so they are stored that way — a row
    /// added as "Example.com" that never matched would be the worst kind of
    /// privacy bug: silent.
    @Test func domainsAreStoredFolded() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("  Example-Health.ORG  ", kind: .domain, database: db)
        #expect(try Exclusions.userValues(kind: .domain, database: db)
            == ["example-health.org"])
    }

    /// Adding something already built in is a no-op rather than a row: a
    /// duplicate would show in the user's list with a "remove" beside it,
    /// implying an exclusion could be turned off that cannot.
    @Test func addingABuiltInStoresNothing() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("com.1password.1password", kind: .bundle, database: db)
        try Exclusions.add("chase.com", kind: .domain, database: db)
        #expect(try Exclusions.userValues(kind: .bundle, database: db).isEmpty)
        #expect(try Exclusions.userValues(kind: .domain, database: db).isEmpty)
        // Still excluded — by the built-in list, which is the point.
        #expect(try Exclusions(database: db).isExcluded(bundleID: "com.1password.1password"))
    }

    @Test func addingTwiceStoresOneRow() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("com.example.private", kind: .bundle, database: db)
        try Exclusions.add("com.example.private", kind: .bundle, database: db)
        #expect(try Exclusions.userValues(kind: .bundle, database: db).count == 1)
    }

    @Test func removeDropsTheRowAndOnlyThatKind() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("example.com", kind: .domain, database: db)
        try Exclusions.add("example.com", kind: .bundle, database: db)
        try Exclusions.remove("example.com", kind: .domain, database: db)
        #expect(try Exclusions.userValues(kind: .domain, database: db).isEmpty)
        #expect(try Exclusions.userValues(kind: .bundle, database: db) == ["example.com"])
    }

    @Test func blankInputStoresNothing() throws {
        let db = try ShifuDatabase.inMemory()
        try Exclusions.add("   ", kind: .domain, database: db)
        #expect(try Exclusions.userValues(kind: .domain, database: db).isEmpty)
    }
}

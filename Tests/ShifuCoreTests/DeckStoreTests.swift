import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct DeckStoreTests {
    private func scratch() throws -> (ShifuDatabase, VaultStore) {
        let database = try ShifuDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-deck-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (database, VaultStore(root: dir, database: database))
    }

    @discardableResult
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String
    ) throws -> Int64 {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name, createdAt: 0, lastActiveAt: 0)
            try task.insert(db)
            return task.id!
        }
    }

    private func sample(_ topic: String) -> DeckStore.SampleCard {
        DeckStore.SampleCard(
            topic: topic, note: "Reference paragraph about \(topic).",
            question: "What does \(topic) do?", answer: "It does the \(topic) thing.")
    }

    private func suggestion(
        _ database: ShifuDatabase, taskKey: String, samples: [DeckStore.SampleCard]
    ) throws -> DeckStore.PendingSuggestion {
        try DeckStore.suggest(taskKey: taskKey, title: "FSRS internals",
                              samples: samples, database: database)
        return try #require(try DeckStore.pendingSuggestions(database: database).first)
    }

    // MARK: - Create

    @Test func createIsIdempotentAndKeysOffTheTaskKey() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")

        let first = try DeckStore.create(title: "FSRS internals", taskKey: "sem:fsrs-tuning",
                                         database: database)
        #expect(first == "deck:fsrs-tuning")
        // A second Create — or a second suggestion accept — is a no-op, not a
        // second deck: one deck per task (regeneration is deferred, §12).
        let second = try DeckStore.create(title: "Something else", taskKey: "sem:fsrs-tuning",
                                          database: database)
        #expect(second == first)

        let decks = try DeckStore.decks(database: database)
        #expect(decks.count == 1)
        #expect(decks[0].title == "FSRS internals")
        #expect(decks[0].status == .pending)
        #expect(decks[0].taskName == "FSRS tuning")
        #expect(decks[0].cardCount == 0)
    }

    /// The JOIN, not a delete, is what hides a deck whose task went away —
    /// the cards stay in the vault and keep serving the All queue.
    @Test func deckForAPrunedTaskDropsOutOfTheListButKeepsItsRow() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:gone", name: "Gone")
        try DeckStore.create(title: "Gone deck", taskKey: "sem:gone", database: database)
        try database.queue.write { db in try db.execute(sql: "DELETE FROM tasks") }

        #expect(try DeckStore.decks(database: database).isEmpty)
        #expect(try DeckStore.deck(taskKey: "sem:gone", database: database) == nil)
        let rows = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks")
        }
        #expect(rows == 1)
    }

    // MARK: - Accept / dismiss

    @Test func acceptWritesKeptSeededStampedCards() throws {
        let (database, vault) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let pending = try suggestion(database, taskKey: "sem:fsrs-tuning",
                                     samples: [sample("stability"), sample("difficulty")])
        #expect(pending.samples.count == 2)
        #expect(pending.taskName == "FSRS tuning")

        let deckKey = try #require(
            try DeckStore.accept(pending, database: database, vault: vault))

        // The request is the confirmation: cards skip the inbox entirely.
        #expect(try vault.inbox().isEmpty)
        let cards = try vault.deckNotes(deckKey: deckKey).sorted { $0.topic < $1.topic }
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.state == .kept })
        #expect(cards.allSatisfy { $0.srs != nil })
        #expect(cards.allSatisfy { $0.deck == deckKey })
        #expect(cards.allSatisfy { $0.taskKey == "sem:fsrs-tuning" })
        #expect(cards[0].questionAnswer?.question == "What does difficulty do?")
        // Born kept and seeded ⇒ immediately reviewable.
        #expect(try vault.due().count == 2)
        #expect(try DeckStore.cardCount(deckKey: deckKey, database: database) == 2)

        // The proposal is closed and never resurfaces.
        #expect(try DeckStore.pendingSuggestions(database: database).isEmpty)
    }

    @Test func dismissedSuggestionNeverResurfaces() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let pending = try suggestion(database, taskKey: "sem:fsrs-tuning",
                                     samples: [sample("stability")])

        try DeckStore.dismiss(suggestionID: pending.id, database: database)
        #expect(try DeckStore.pendingSuggestions(database: database).isEmpty)
        // …and the suggester must not propose the same task again.
        #expect(try DeckStore.spokenForTaskKeys(database: database)
            .contains("sem:fsrs-tuning"))
        // A second suggest is swallowed by the unique key rather than
        // reopening the dismissal.
        try DeckStore.suggest(taskKey: "sem:fsrs-tuning", title: "Again",
                              samples: [sample("x")], database: database)
        #expect(try DeckStore.pendingSuggestions(database: database).isEmpty)
    }

    @Test func declinedTaskIsRememberedAndInvisible() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:admin-chores", name: "Admin chores")
        try DeckStore.decline(taskKey: "sem:admin-chores", database: database)

        #expect(try DeckStore.pendingSuggestions(database: database).isEmpty)
        #expect(try DeckStore.openSuggestionCount(database: database) == 0)
        #expect(try DeckStore.spokenForTaskKeys(database: database)
            .contains("sem:admin-chores"))
    }

    // MARK: - Build lifecycle

    @Test func claimLetsExactlyOneBuilderThrough() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let deckKey = try #require(
            try DeckStore.create(title: "FSRS", taskKey: "sem:fsrs-tuning", database: database))

        let first = try DeckStore.claimForBuild(key: deckKey, database: database)
        #expect(first?.taskKey == "sem:fsrs-tuning")
        #expect(first?.title == "FSRS")
        // No lock exists between analyzer processes — the compare-and-set is
        // the whole guard, so a second claimant must come back empty.
        #expect(try DeckStore.claimForBuild(key: deckKey, database: database) == nil)
        #expect(try DeckStore.decks(database: database)[0].status == .building)

        try DeckStore.markReady(key: deckKey, database: database)
        let ready = try DeckStore.decks(database: database)[0]
        #expect(ready.status == .ready)
        #expect(ready.builtAt != nil)
        // A ready deck is not claimable again (refresh is deferred, §12).
        #expect(try DeckStore.claimForBuild(key: deckKey, database: database) == nil)
    }

    @Test func staleClaimIsReclaimableAndFailureHandsItBack() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let deckKey = try #require(
            try DeckStore.create(title: "FSRS", taskKey: "sem:fsrs-tuning", database: database))

        let start = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(try DeckStore.claimForBuild(key: deckKey, database: database, now: start) != nil)
        // Still fresh: the deck belongs to the process that has it.
        let soon = start.addingTimeInterval(60)
        #expect(try DeckStore.claimForBuild(key: deckKey, database: database, now: soon) == nil)
        // An hour on, the claimant is presumed dead and the deck is takeable —
        // otherwise a crash would strand it in "Building…" forever.
        let later = start.addingTimeInterval(3_700)
        #expect(try DeckStore.claimForBuild(key: deckKey, database: database, now: later) != nil)

        // A failed build hands the claim straight back to the next drain.
        try DeckStore.releaseClaim(key: deckKey, database: database, now: later)
        #expect(try DeckStore.decks(database: database)[0].status == .pending)
        #expect(try DeckStore.pendingDeckKeys(database: database) == [deckKey])
    }

    // MARK: - Deck-scoped dedupe

    /// A deck dedupes within itself, never against the rest of the vault:
    /// merging a requested card into an unrelated inbox note would leave the
    /// deck quietly short a card, with no `deck:` stamp to show where it went.
    @Test func deckDedupeIgnoresIdenticalNonDeckNotes() throws {
        let (database, vault) = try scratch()
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let deckKey = try #require(
            try DeckStore.create(title: "FSRS", taskKey: "sem:fsrs-tuning", database: database))

        let card = sample("stability")
        let body = Note.composeBody(reference: card.note, question: card.question,
                                    answer: card.answer)
        let stranger = Note(topic: card.topic, body: body)   // inbox, no deck
        try vault.save(stranger)

        #expect(try DeckStore.write(card, deckKey: deckKey, taskKey: "sem:fsrs-tuning",
                                    vault: vault))
        #expect(try vault.deckNotes(deckKey: deckKey).count == 1)
        // The bystander is untouched — no seen_count bump, still in the inbox.
        let untouched = try #require(try vault.inbox().first { $0.id == stranger.id })
        #expect(untouched.seenCount == 1)

        // Within the deck, though, the same card does dedupe.
        #expect(try DeckStore.write(card, deckKey: deckKey, taskKey: "sem:fsrs-tuning",
                                    vault: vault) == false)
        #expect(try vault.deckNotes(deckKey: deckKey).count == 1)
        #expect(try vault.deckNotes(deckKey: deckKey)[0].seenCount == 2)
    }

    @Test func reconcileRebuildsDeckKeyFromFrontmatter() throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs-tuning", name: "FSRS tuning")
        let deckKey = try #require(
            try DeckStore.create(title: "FSRS", taskKey: "sem:fsrs-tuning", database: database))
        try DeckStore.write(sample("stability"), deckKey: deckKey,
                            taskKey: "sem:fsrs-tuning", vault: vault)

        // The index is disposable: dropping it and reconciling from the files
        // must restore the deck membership.
        try database.queue.write { db in try db.execute(sql: "DELETE FROM vault_index") }
        #expect(try DeckStore.cardCount(deckKey: deckKey, database: database) == 0)
        try VaultIndexer.reconcile(root: vault.root, database: database)
        #expect(try DeckStore.cardCount(deckKey: deckKey, database: database) == 1)
    }

    // MARK: - Task lifecycle

    @Test func pruneAndMergeClearOpenProposalsButKeepResolvedOnes() throws {
        let (database, _) = try scratch()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let stale = Int64(now.timeIntervalSince1970 * 1_000) - 30 * 86_400_000

        // Two prune-eligible noise tasks: one with an open proposal, one that
        // was already dismissed.
        try database.queue.write { db in
            for key in ["domain:nytimes.com", "domain:wsj.com"] {
                var task = WorkTask(key: key, name: String(key.dropFirst(7)),
                                    createdAt: stale, lastActiveAt: stale)
                try task.insert(db)
                var activity = Activity(startedAt: stale - 60_000, endedAt: stale,
                                        appBundle: "com.apple.Safari", category: .work)
                try activity.insert(db)
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                               arguments: [task.id, activity.id])
            }
        }
        try DeckStore.suggest(taskKey: "domain:nytimes.com", title: "News",
                              samples: [sample("x")], database: database)
        try DeckStore.decline(taskKey: "domain:wsj.com", database: database)

        #expect(try TaskStore.prune(database: database, now: now) == 2)
        let afterPrune = try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT task_key, status FROM deck_suggestions")
        }
        #expect(afterPrune.count == 1)
        #expect(afterPrune[0]["task_key"] == "domain:wsj.com")   // the memory survives

        // Merge: the absorbed task's open proposal goes the same way.
        let survivor = try seedTask(database, key: "sem:trip", name: "Trip planning")
        let absorbed = try seedTask(database, key: "sem:flights", name: "Flights")
        try DeckStore.suggest(taskKey: "sem:flights", title: "Flights deck",
                              samples: [sample("y")], database: database)
        try TaskStore.merge(survivorID: survivor, absorbedID: absorbed, database: database)

        let afterMerge = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT task_key FROM deck_suggestions ORDER BY task_key")
        }
        #expect(afterMerge == ["domain:wsj.com"])
    }
}

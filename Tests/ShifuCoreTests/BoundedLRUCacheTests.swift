import Testing
@testable import ShifuCore

@Suite struct BoundedLRUCacheTests {
    @Test func missingKeyReturnsNil() {
        var cache = BoundedLRUCache<String, Int>(capacity: 4)
        #expect(cache.get("missing") == nil)
    }

    @Test func setThenGetReturnsStoredValue() {
        var cache = BoundedLRUCache<String, Int>(capacity: 4)
        cache.set(42, forKey: "alpha")
        #expect(cache.get("alpha") == 42)
    }

    @Test func updatingExistingKeyLeavesCountUnchanged() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.set(1, forKey: "alpha")
        cache.set(2, forKey: "alpha")
        #expect(cache.count == 1)
        #expect(cache.get("alpha") == 2)
    }

    /// Updating an existing key while the cache is full must not evict
    /// anything — there is no new key to make room for. The updated key is
    /// deliberately *not* the least-recently-used one: evicting on an update
    /// of the LRU key happens to reinsert it and lands back at the same
    /// count, so only updating a non-LRU key exposes the missing guard.
    @Test func updatingExistingKeyAtCapacityEvictsNothing() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.set(1, forKey: "alpha")
        cache.set(2, forKey: "beta")   // full; "alpha" is least-recently-used
        cache.set(20, forKey: "beta")  // update the most-recently-used key
        #expect(cache.count == 2)
        #expect(cache.get("alpha") == 1)
        #expect(cache.get("beta") == 20)
    }

    /// Write-only baseline: with no reads in between, the insertion order is
    /// the usage order, so the first key written is the first evicted.
    @Test func overflowEvictsLeastRecentlyUsedKey() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.set(1, forKey: "alpha")
        cache.set(2, forKey: "beta")
        cache.set(3, forKey: "gamma")
        #expect(cache.get("alpha") == nil)
        #expect(cache.get("beta") == 2)
        #expect(cache.get("gamma") == 3)
        #expect(cache.count == 2)
    }

    /// This is the design.md §10 "fullscreen video" shape: a key that is
    /// looked up on every heartbeat but written only once must not be
    /// evicted just because it is never re-written. If `get` did not
    /// promote to most-recently-used, this test would fail because the
    /// third `set` would evict "alpha" instead of "beta".
    @Test func readPromotesKeyAheadOfEviction() {
        var cache = BoundedLRUCache<String, Int>(capacity: 2)
        cache.set(1, forKey: "alpha")
        cache.set(2, forKey: "beta")
        // "alpha" is the least-recently-used entry until this read touches it.
        #expect(cache.get("alpha") == 1)
        cache.set(3, forKey: "gamma")
        // "beta" was never re-read after being written, so it is now the
        // least-recently-used entry and is the one evicted.
        #expect(cache.get("beta") == nil)
        #expect(cache.get("alpha") == 1)
        #expect(cache.get("gamma") == 3)
    }

    @Test func capacityOneRetainsOnlyTheLatestKey() {
        var cache = BoundedLRUCache<String, Int>(capacity: 1)
        cache.set(1, forKey: "alpha")
        cache.set(2, forKey: "beta")
        #expect(cache.get("alpha") == nil)
        #expect(cache.get("beta") == 2)
        #expect(cache.count == 1)
    }

    @Test func countStaysAtCapacityUnderSustainedInserts() {
        var cache = BoundedLRUCache<String, Int>(capacity: 5)
        for index in 0..<50 {
            cache.set(index, forKey: "key\(index)")
        }
        #expect(cache.count == 5)
        // Only the most recently inserted five keys survive.
        #expect(cache.get("key49") == 49)
        #expect(cache.get("key45") == 45)
        #expect(cache.get("key44") == nil)
    }
}

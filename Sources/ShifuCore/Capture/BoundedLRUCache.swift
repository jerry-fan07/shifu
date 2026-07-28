/// Fixed-capacity, least-recently-used key/value map.
///
/// `shifud` runs for weeks as a LaunchAgent (design.md §2.2) and must keep
/// its dedupe state within the memory budget in design.md §3.4 (<80 MB
/// steady RSS) even though the keys it tracks — one per window, keyed on
/// title — are unbounded in cardinality (every file, browser tab, terminal
/// cwd). Once `capacity` entries are held, inserting a new key evicts the
/// least-recently-used one to make room.
///
/// Both `get` and `set` count as a "use" and move the entry to
/// most-recently-used. This matters for design.md §3.3/§10: a fullscreen
/// video's dHash is looked up on every heartbeat but only ever written once
/// (it never changes), so a cache that promoted on write alone would let
/// that hot key age out from underneath it and start missing the "one
/// observation for the whole movie" dedupe it exists to provide.
public struct BoundedLRUCache<Key: Hashable, Value> {
    /// Maximum number of entries retained; the least-recently-used entry is
    /// evicted once a new key would exceed it.
    public let capacity: Int

    private var values: [Key: Value] = [:]
    /// Usage order: least-recently-used first, most-recently-used last.
    private var order: [Key] = []

    /// - Parameter capacity: must be positive. Tests use small values to
    ///   exercise eviction; `shifud` wires in `CaptureEngine.defaultDHashCacheCapacity`.
    public init(capacity: Int) {
        precondition(capacity > 0, "BoundedLRUCache capacity must be positive")
        self.capacity = capacity
    }

    /// Current number of entries. Never exceeds `capacity`.
    public var count: Int { values.count }

    /// Looks up `key`, promoting it to most-recently-used on a hit.
    /// Returns `nil` without side effects on a miss.
    public mutating func get(_ key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// Inserts or updates the value for `key`, promoting it to
    /// most-recently-used. If `key` is not already present and the cache is
    /// at `capacity`, evicts the least-recently-used entry first.
    public mutating func set(_ value: Value, forKey key: Key) {
        if values[key] == nil, values.count >= capacity, let leastRecent = order.first {
            values.removeValue(forKey: leastRecent)
            order.removeFirst()
        }
        values[key] = value
        touch(key)
    }

    /// Moves `key` to the most-recently-used end of `order`, inserting it
    /// if this is its first use.
    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}

extension BoundedLRUCache: Sendable where Key: Sendable, Value: Sendable {}

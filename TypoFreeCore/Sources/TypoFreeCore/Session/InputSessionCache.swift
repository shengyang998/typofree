// InputSessionCache — the small LRU that reconnects composition state after the
// IMK controller is rebuilt (CapsLock / mode switch recreate the controller, but
// the client keeps focus). DESIGN.md §2.5/§4. Keyed by the client's address
// token; capacity 5, LRU eviction. It is pure (Int keys → `InputSession`, no
// IMKit/AppKit), so it lives in Core and is unit-tested there; the app shell
// owns one instance. The session itself references its client *weakly*, so the
// cache never keeps a dead client alive — it only preserves the session's own
// state (buffer, 中英 mode) across a controller rebuild.
@MainActor public final class InputSessionCache {
    public let capacity: Int
    private var map: [Int: InputSession] = [:]
    /// LRU order — least-recently-used first, most-recent last.
    private var order: [Int] = []

    public init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { map.count }

    /// Retrieve the session for `key`, or create + insert one via `make`. Either
    /// way the key becomes most-recently-used; inserting past `capacity` evicts
    /// the least-recently-used session.
    public func session(forKey key: Int, make: () -> InputSession) -> InputSession {
        if let existing = map[key] {
            touch(key)
            return existing
        }
        let session = make()
        map[key] = session
        order.append(key)
        evictIfNeeded()
        return session
    }

    /// The cached session for `key` without creating one.
    public func peek(forKey key: Int) -> InputSession? { map[key] }

    /// Drop the session for `key` (e.g. its client went away for good).
    public func remove(forKey key: Int) {
        map[key] = nil
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Int) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while map.count > capacity, let oldest = order.first {
            order.removeFirst()
            map[oldest] = nil
        }
    }
}

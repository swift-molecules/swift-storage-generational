// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-primitives open source project
//
// Copyright (c) 2024-2026 Coen ten Thije Boonkkamp and the swift-primitives project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

// Behavioral tests for the reshaped `Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>`
// — the un-fused `Storage.Arena`: a slotmap over a heap pool with generation tokens
// (insert / contains / remove / validated subscript) and the deinit oracle.
//
// ONE `@Suite(.serialized)` so the Probe-using teardown drops run serially against the shared
// destruction recorder (the binding deterministic-gate rule).

import Index_Primitives
import Memory_Allocator_Primitive
import Memory_Heap_Primitives
import Storage_Generational_Primitives
import Testing

/// The canonical sparse storage spelling: generation-token slotmap over a heap pool.
private typealias Slots<Element: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>

private final class Item: @unchecked Sendable {
    let id: Int
    var value: Int
    init(_ id: Int, value: Int = 0) {
        self.id = id
        self.value = value
    }
    deinit { Probe.record(id) }
}

extension Item {
    func bump() { value += 1 }
}

private enum Probe {}

extension Probe {
    // SAFETY: allocated once at first access, mutated only through `reset()` /
    // `record(_:)` on the single-threaded test-runner path — this is a
    // test-fixture deinit tally, never touched concurrently.
    nonisolated(unsafe) static var _destroyed: [Int] = []
    static func reset() { unsafe _destroyed = [] }
    static func record(_ id: Int) { unsafe _destroyed.append(id) }
    static var destroyed: [Int] { unsafe _destroyed }
    static var sorted: [Int] { unsafe _destroyed.sorted() }
}

@Suite(.serialized)
struct `Storage Generational Tests` {
    @Suite struct Unit {}
    @Suite struct `Edge Case` {}
    @Suite struct Integration {}

    @Test
    func `grow preserves the incarnation history — live handles resolve, stale stay stale`() {
        Probe.reset()
        do {
            var s = Slots<Item>.create(slotCapacity: 2)
            let hStale = s.insert(Item(1))
            _ = s.remove(hStale)  // gen bumps; slot 0 freed
            let hLive = s.insert(Item(2, value: 20))  // reuses slot 0 at gen 1
            let hAlso = s.insert(Item(3, value: 30))  // slot 1
            s.grow(to: Index<Item>.Count(UInt(8)))  // the relocating door
            let grown = s.capacity
            #expect(grown == Index<Item>.Count(UInt(8)))
            let liveHeld = s.contains(hLive) && s.contains(hAlso)
            #expect(liveHeld)  // (α) live positions survive
            let staleHeld = s.contains(hStale)
            #expect(!staleHeld)  // (β) stale stays stale
            let v = s[hLive].value
            #expect(v == 20)
            // The fresh tail is usable: fill past the old capacity.
            let h4 = s.insert(Item(4, value: 40))
            let v4 = s[h4].value
            #expect(v4 == 40)
            let n = s.count
            #expect(n == Index<Item>.Count(UInt(3)))
            // No element died during the move (1 died at its remove above).
            let midGrow = Probe.sorted
            #expect(midGrow == [1])
        }
        // Exactly one teardown per element — the move never double-destroys.
        let all = Probe.sorted
        #expect(all == [1, 2, 3, 4])
    }

    @Test
    func `insert Contains Subscript`() {
        Probe.reset()
        var s = Slots<Item>.create(slotCapacity: 4)
        let h = s.insert(Item(1, value: 10))
        let has = s.contains(h)
        let cnt = s.count
        let v = s[h].value
        #expect(has)
        #expect(cnt == Index<Item>.Count(UInt(1)))
        #expect(v == 10)
        s[h].bump()  // _modify through the validated subscript
        let v2 = s[h].value
        #expect(v2 == 11)
    }

    @Test
    func `remove Returns Element And Stales Handle`() {
        Probe.reset()
        var s = Slots<Item>.create(slotCapacity: 4)
        let h = s.insert(Item(7, value: 70))
        let removed = s.remove(h)
        let id = removed?.id
        let val = removed?.value
        let stillThere = s.contains(h)
        let cnt = s.count
        let dEmpty = Probe.destroyed.isEmpty  // moved out, not destroyed
        #expect(id == 7)
        #expect(val == 70)
        #expect(!stillThere)  // handle is stale after remove
        #expect(cnt == Index<Item>.Count(UInt(0)))
        #expect(dEmpty)
        _ = consume removed
        let dAfter = Probe.destroyed
        #expect(dAfter == [7])
    }

    @Test
    func `reuse After Remove Stales Old Handle`() {
        Probe.reset()
        var s = Slots<Item>.create(slotCapacity: 2)
        let h1 = s.insert(Item(1, value: 10))
        _ = s.remove(h1)  // frees slot 0, bumps its generation
        let h2 = s.insert(Item(2, value: 20))  // reuses slot 0 at the new generation
        let oldStale = s.contains(h1)
        let newLive = s.contains(h2)
        let v = s[h2].value
        #expect(!oldStale)  // the pre-reuse handle is rejected
        #expect(newLive)
        #expect(v == 20)
    }

    @Test
    func `teardown Destroys Occupied Once`() {
        Probe.reset()
        do {
            var s = Slots<Item>.create(slotCapacity: 8)
            _ = s.insert(Item(1))
            _ = s.insert(Item(2))
            _ = s.insert(Item(3))
        }  // the oracle destroys the 3 occupied slots; then the pool frees the region once
        let ds = Probe.sorted
        #expect(ds == [1, 2, 3])
    }
}

// MARK: - The Position-decode door (Round M B2 spike)

extension `Storage Generational Tests` {
    @Test
    func `handle(at:) reconstructs exactly the live handle and rejects free or reused slots`() {
        Probe.reset()
        var s = Slots<Item>.create(slotCapacity: 4)
        let h = s.insert(Item(1))
        // A live slot reconstructs the exact outstanding handle.
        #expect(s.handle(at: Index<Item>(Ordinal(UInt(h.index)))) == h)
        // A never-occupied slot decodes to nil.
        #expect(s.handle(at: Index<Item>(Ordinal(UInt(h.index + 1)))) == nil)
        // A freed slot decodes to nil; after reuse it decodes to the NEW handle only.
        _ = s.remove(h)
        #expect(s.handle(at: Index<Item>(Ordinal(UInt(h.index)))) == nil)
        let h2 = s.insert(Item(2))
        let decoded = s.handle(at: Index<Item>(Ordinal(UInt(h2.index))))
        #expect(decoded == h2)
        #expect(decoded != h)
    }
}

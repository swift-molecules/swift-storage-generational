import Buffer_Primitives_Test_Support
import Buffer_Protocol_Primitives
import Index_Primitives
import Memory_Allocator_Primitive
import Memory_Heap_Primitives
import Storage_Generational_Primitives
import Store_Protocol_Primitives
import Testing

// The ratified generational seam (ASK-H′, 2026-06-10): the thin restricted-domain
// positional accessor + typed counts + removeAll + the generation-preserving clone.

private typealias Slots<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<E>

// MARK: - [DS-024]: the generational column is lawful (fresh-pool order is dense)

@Suite
struct `Generational Seam Law Tests` {

    @Test
    func `the generational column obeys the seam ledger laws`() {
        let violations = Seam.Ledger.violations(
            makeEmpty: { Slots<Int>.create(slotCapacity: 4) },
            element: { $0 }
        )
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test
    func `a fresh pool hands out slots densely (the initialize domain)`() {
        var s = Slots<Int>.create(slotCapacity: 4)
        let h0 = s.insert(10)
        let h1 = s.insert(20)
        let h2 = s.insert(30)
        #expect(h0.index == 0)
        #expect(h1.index == 1)
        #expect(h2.index == 2)
    }
}

// MARK: - The positional seam against the handle surface

@Suite
struct `Generational Seam Tests` {

    @Test
    func `positional move vacates the slot and stales outstanding handles`() {
        var s = Slots<Int>.create(slotCapacity: 4)
        let h0 = s.insert(7)
        let h1 = s.insert(8)
        let moved = s.move(at: Index<Int>(Ordinal(UInt(0))))
        #expect(moved == 7)
        let staleGone = s.contains(h0)
        #expect(!staleGone)  // generation bumped by the positional move
        let live = s.contains(h1)
        #expect(live)
        let n = s.count
        #expect(n == Index<Int>.Count(UInt(1)))
        let read = s[Index<Int>(Ordinal(UInt(1)))]
        #expect(read == 8)  // stable physical positions (no re-anchoring)
    }

    @Test
    func `removeAll drains every occupied slot and stales all handles`() {
        var s = Slots<Int>.create(slotCapacity: 4)
        let h0 = s.insert(1)
        _ = s.insert(2)
        s.removeAll()
        let isEmpty = s.isEmpty
        #expect(isEmpty)
        let gone = s.contains(h0)
        #expect(!gone)
        let h = s.insert(9)  // the pool serves freed slots again
        let live = s.contains(h)
        #expect(live)
    }
}

// MARK: - The generation-preserving clone (sibling handles survive a CoW detach)

@Suite
struct `Generational Clone Tests` {

    @Test
    func `clone preserves indices, occupancy, AND generations — live and stale alike`() {
        var s = Slots<Int>.create(slotCapacity: 4)
        let h0 = s.insert(10)
        let h1 = s.insert(20)
        _ = s.remove(h0)  // slot 0 freed: generation bumped
        let h2 = s.insert(30)  // pool reuses slot 0 → new generation
        let copy = s.clone()
        let liveSurvives = copy.contains(h1) && copy.contains(h2)
        #expect(liveSurvives)
        let staleStaysStale = copy.contains(h0)
        #expect(!staleStaysStale)
        let v1 = copy[h1]
        let v2 = copy[h2]
        #expect(v1 == 20)
        #expect(v2 == 30)
        let n = copy.count
        #expect(n == s.count)
    }

    @Test
    func `the clone's pool state matches occupancy (inserts go to genuinely-free slots)`() {
        var s = Slots<Int>.create(slotCapacity: 3)
        let h0 = s.insert(1)
        _ = s.insert(2)
        _ = s.remove(h0)  // free set = {0, 2}
        var copy = s.clone()
        let hA = copy.insert(7)
        let hB = copy.insert(8)
        let freshLive = copy.contains(hA) && copy.contains(hB)
        #expect(freshLive)
        let n = copy.count
        #expect(n == Index<Int>.Count(UInt(3)))  // exactly the free set was insertable
        let survivor = copy[Index<Int>(Ordinal(UInt(1)))]
        #expect(survivor == 2)  // the original occupant untouched
    }
}

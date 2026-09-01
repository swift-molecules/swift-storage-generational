import Cardinal
import Index
import Memory
import Memory_Allocator
import Storage_Generational
import Storage
import Tagged
import Testing

private typealias Slots<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<E>

@Suite
struct `Generational Seam Law Tests` {
    @Suite struct Unit {}
    @Suite struct `Edge Case` {}
    @Suite struct Integration {}

    @Test
    func `the generational column obeys the seam ledger laws`() {
        var storage = Slots<Int>.create(slotCapacity: typedCount(4))
        let capacity = storage.capacity

        #expect(storage.count == typedCount(0))
        storage.initialize(at: typedIndex(0), to: 10)
        #expect(storage.count == typedCount(1))
        storage.initialize(at: typedIndex(1), to: 20)
        #expect(storage.count == typedCount(2))

        storage[typedIndex(0)] = 30
        #expect(storage.count == typedCount(2))
        #expect(storage.move(at: typedIndex(1)) == 20)
        #expect(storage.count == typedCount(1))
        #expect(storage.move(at: typedIndex(0)) == 30)
        #expect(storage.count == typedCount(0))
        #expect(storage.capacity == capacity)
    }

    @Test
    func `a fresh pool hands out slots densely (the initialize domain)`() {
        var s = Slots<Int>.create(slotCapacity: typedCount(4))
        let h0 = s.insert(10)
        let h1 = s.insert(20)
        let h2 = s.insert(30)
        #expect(h0.index == 0)
        #expect(h1.index == 1)
        #expect(h2.index == 2)
    }
}

@Suite
struct `Generational Seam Tests` {
    @Suite struct Unit {}
    @Suite struct `Edge Case` {}
    @Suite struct Integration {}

    @Test
    func `positional move vacates the slot and stales outstanding handles`() {
        var s = Slots<Int>.create(slotCapacity: typedCount(4))
        let h0 = s.insert(7)
        let h1 = s.insert(8)
        let moved = s.move(at: typedIndex(0))
        #expect(moved == 7)
        let staleGone = s.contains(h0)
        #expect(!staleGone)
        let live = s.contains(h1)
        #expect(live)
        let n = s.count
        #expect(n == typedCount(1))
        let read = s[typedIndex(1)]
        #expect(read == 8)
    }

    @Test
    func `removeAll drains every occupied slot and stales all handles`() {
        var s = Slots<Int>.create(slotCapacity: typedCount(4))
        let h0 = s.insert(1)
        _ = s.insert(2)
        s.removeAll()
        let isEmpty = s.isEmpty
        #expect(isEmpty)
        let gone = s.contains(h0)
        #expect(!gone)
        let h = s.insert(9)
        let live = s.contains(h)
        #expect(live)
    }
}

@Suite
struct `Generational Clone Tests` {
    @Suite struct Unit {}
    @Suite struct `Edge Case` {}
    @Suite struct Integration {}

    @Test
    func `clone preserves indices, occupancy, AND generations — live and stale alike`() {
        var s = Slots<Int>.create(slotCapacity: typedCount(4))
        let h0 = s.insert(10)
        let h1 = s.insert(20)
        _ = s.remove(h0)
        let h2 = s.insert(30)
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
        var s = Slots<Int>.create(slotCapacity: typedCount(3))
        let h0 = s.insert(1)
        _ = s.insert(2)
        _ = s.remove(h0)
        var copy = s.clone()
        let hA = copy.insert(7)
        let hB = copy.insert(8)
        let freshLive = copy.contains(hA) && copy.contains(hB)
        #expect(freshLive)
        let n = copy.count
        #expect(n == typedCount(3))
        let survivor = copy[typedIndex(1)]
        #expect(survivor == 2)
    }
}

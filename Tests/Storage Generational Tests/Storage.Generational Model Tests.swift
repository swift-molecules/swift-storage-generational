import Cardinal
import Index
import Memory
import Memory_Allocator_Primitive
import Storage_Generational
import Tagged
import Testing

private typealias Slots<Element: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>

private typealias Handle = Store.Generational.Handle

private struct Reference {
    var slots: [Slot]
    var live: [(handle: Handle, id: Int)] = []

    var stale: [(handle: Handle, id: Int)] = []

    init(capacity: Int) {
        self.slots = Swift.Array(repeating: Slot(), count: capacity)
    }
}

extension Reference {
    struct Slot {
        var occupied = false
        var generation = 0
        var id: Int? = nil
    }

    var capacity: Int { slots.count }
    var liveCount: Int { live.count }

    mutating func admit(_ handle: Handle, id: Int) -> [String] {
        var findings: [String] = []
        guard handle.index >= 0, handle.index < slots.count else {
            return ["minted handle index \(handle.index) outside capacity \(slots.count)"]
        }
        if slots[handle.index].occupied {
            findings.append(
                "minted handle for slot \(handle.index), which the ledger holds OCCUPIED"
            )
        }
        if slots[handle.index].generation != handle.generation {
            findings.append(
                "generation continuity broken at slot \(handle.index): minted \(handle.generation), ledger \(slots[handle.index].generation)"
            )
        }
        slots[handle.index].occupied = true
        slots[handle.index].id = id
        live.append((handle, id))
        return findings
    }

    mutating func retire(liveAt position: Int) {
        let entry = live.remove(at: position)
        slots[entry.handle.index].occupied = false
        slots[entry.handle.index].generation += 1
        slots[entry.handle.index].id = nil
        addStale(entry)
    }

    mutating func retireAll() {
        for entry in live {
            slots[entry.handle.index].occupied = false
            slots[entry.handle.index].generation += 1
            slots[entry.handle.index].id = nil
            addStale(entry)
        }
        live.removeAll()
    }

    mutating func grow(to capacity: Int) {
        slots.append(contentsOf: Swift.Array(repeating: Slot(), count: capacity - slots.count))
    }

    private mutating func addStale(_ entry: (handle: Handle, id: Int)) {
        stale.append(entry)
        if stale.count > 16 {
            stale.removeFirst(stale.count - 16)
        }
    }
}

private final class Item {
    let id: Int
    let serial: Int
    private let census: Model.Census

    init(id: Int, census: Model.Census) {
        self.id = id
        self.census = census
        self.serial = census.mint()
    }

    deinit {
        census.record(death: serial)
    }
}

private struct TrivialStream: ~Copyable {
    var store: Slots<Int>
    var model: Reference
    var rng: Model.Random
    var verdict: Model.Verdict
    var nextID = 0

    init(seed: UInt64) {
        var rng = Model.Random(seed: seed)
        let capacity = 2 + rng.below(15)
        self.store = Slots<Int>.create(slotCapacity: typedCount(capacity))
        self.model = Reference(capacity: capacity)
        self.rng = rng
        self.verdict = Model.Verdict(seed: seed)
    }
}

extension TrivialStream {
    mutating func insertNew() {
        let id = nextID
        nextID += 1
        let handle = store.insert(id)
        verdict.record("insert id=\(id) → @\(handle.index)g\(handle.generation)")
        verdict.diverged(model.admit(handle, id: id))
    }

    mutating func removeLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("remove id=\(entry.id) @\(entry.handle.index)g\(entry.handle.generation)")
        if let element = store.remove(entry.handle) {
            if element != entry.id {
                verdict.diverged(["remove returned id \(element), model \(entry.id)"])
            }
            model.retire(liveAt: position)
        } else {
            verdict.diverged([
                "remove rejected a LIVE handle (α): @\(entry.handle.index)g\(entry.handle.generation)"
            ])
        }
    }

    mutating func removeStale() {
        let entry = model.stale[rng.below(model.stale.count)]
        verdict.record("stale-remove @\(entry.handle.index)g\(entry.handle.generation)")
        if let element = store.remove(entry.handle) {
            verdict.diverged(["STALE handle re-validated through remove (β): yielded id \(element)"]
            )
        }
    }

    mutating func readLive() {
        let entry = model.live[rng.below(model.live.count)]
        verdict.record("read id=\(entry.id)")
        let element = store[entry.handle]
        if element != entry.id {
            verdict.diverged(["read at live handle: \(element), model \(entry.id)"])
        }
    }

    mutating func mutateLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        let id = nextID
        nextID += 1
        verdict.record("mutate @\(entry.handle.index) \(entry.id)→\(id)")
        store[entry.handle] = id
        model.live[position].id = id
        model.slots[entry.handle.index].id = id
        if !store.contains(entry.handle) {
            verdict.diverged([
                "mutation through a handle staled it (mutation must not bump generations)"
            ])
        }
    }

    mutating func seamMove() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("seam-move @\(entry.handle.index)")
        let element = store.move(at: Index<Int>(Ordinal(UInt(entry.handle.index))))
        if element != entry.id {
            verdict.diverged(["seam move(at:) returned id \(element), model \(entry.id)"])
        }
        model.retire(liveAt: position)
    }

    mutating func growStore() {
        let target = model.capacity + 1 + rng.below(8)
        verdict.record("grow \(model.capacity)→\(target)")
        store.grow(to: typedCount(target))
        model.grow(to: target)
    }

    mutating func wipe() {
        verdict.record("wipe \(model.liveCount) live")
        store.removeAll()
        model.retireAll()
    }

    mutating func cloneCheck() {
        verdict.record("clone")
        var copy = store.clone()
        for entry in model.live {
            if !copy.contains(entry.handle) {
                verdict.diverged([
                    "clone dropped live handle @\(entry.handle.index)g\(entry.handle.generation)"
                ])
            } else if copy[entry.handle] != entry.id {
                verdict.diverged([
                    "clone resolves id \(copy[entry.handle]) at @\(entry.handle.index), model \(entry.id)"
                ])
            }
        }
        for entry in model.stale where copy.contains(entry.handle) {
            verdict.diverged([
                "clone re-validated a stale handle @\(entry.handle.index)g\(entry.handle.generation)"
            ])
        }
        if model.liveCount < model.capacity {
            _ = copy.insert(-1)
            let original = store.count
            if original != typedCount(model.liveCount) {
                verdict.diverged(["mutating the clone changed the original's count"])
            }
        }
    }

    func audit() -> [String] {
        var findings: [String] = []
        if store.count != typedCount(model.liveCount) {
            findings.append("count: store \(store.count), model \(model.liveCount)")
        }
        if store.capacity != typedCount(model.capacity) {
            findings.append("capacity: store \(store.capacity), model \(model.capacity)")
        }
        for entry in model.live {
            if !store.contains(entry.handle) {
                findings.append(
                    "α: live handle @\(entry.handle.index)g\(entry.handle.generation) rejected"
                )
            } else if store[entry.handle] != entry.id {
                findings.append(
                    "live handle @\(entry.handle.index) resolves \(store[entry.handle]), model \(entry.id)"
                )
            }
        }
        for entry in model.stale where store.contains(entry.handle) {
            findings.append(
                "β: stale handle @\(entry.handle.index)g\(entry.handle.generation) re-validated"
            )
        }
        return findings
    }

    mutating func step() {
        var branch = rng.below(100)

        if model.stale.isEmpty, branch >= 52, branch < 58 { branch = 58 }
        if model.live.isEmpty, branch >= 30, branch < 86 { branch = 0 }
        if model.liveCount == model.capacity, branch < 30 { branch = 34 }

        switch branch {
        case 0..<30: insertNew()
        case 30..<52: removeLive()
        case 52..<58: removeStale()
        case 58..<64: readLive()
        case 64..<72: readLive()
        case 72..<80: mutateLive()
        case 80..<86: seamMove()
        case 86..<90: growStore()
        case 90..<94: cloneCheck()
        default: wipe()
        }
    }

    mutating func run() {
        let operations = Model.operations(default: 1_000)
        var op = 0
        while op < operations, verdict.isClean {
            step()
            if Model.shouldAudit(op: op, of: operations) {
                verdict.diverged(audit())
            }
            op += 1
        }
    }

    consuming func finish() -> Model.Verdict {
        verdict
    }
}

private struct RefcountedStream: ~Copyable {
    var store: Slots<Item>
    var model: Reference
    var rng: Model.Random
    var verdict: Model.Verdict
    var nextID = 0
    var expectedDeaths = 0
    let census: Model.Census

    init(seed: UInt64, census: Model.Census) {
        var rng = Model.Random(seed: seed)
        let capacity = 2 + rng.below(11)
        self.store = Slots<Item>.create(slotCapacity: typedCount(capacity))
        self.model = Reference(capacity: capacity)
        self.rng = rng
        self.verdict = Model.Verdict(seed: seed)
        self.census = census
    }
}

extension RefcountedStream {
    mutating func insertNew() {
        let id = nextID
        nextID += 1
        let handle = store.insert(Item(id: id, census: census))
        verdict.record("insert id=\(id) → @\(handle.index)g\(handle.generation)")
        verdict.diverged(model.admit(handle, id: id))
    }

    mutating func removeLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("remove id=\(entry.id)")
        if let element = store.remove(entry.handle) {
            if element.id != entry.id {
                verdict.diverged(["remove returned id \(element.id), model \(entry.id)"])
            }
            model.retire(liveAt: position)
            expectedDeaths += 1
        } else {
            verdict.diverged(["remove rejected a LIVE handle (α)"])
        }
    }

    mutating func removeStale() {
        let entry = model.stale[rng.below(model.stale.count)]
        verdict.record("stale-remove @\(entry.handle.index)g\(entry.handle.generation)")
        if let element = store.remove(entry.handle) {
            verdict.diverged(["STALE handle re-validated through remove (β): id \(element.id)"])
        }
    }

    mutating func readLive() {
        let entry = model.live[rng.below(model.live.count)]
        verdict.record("read id=\(entry.id)")
        let id = store[entry.handle].id
        if id != entry.id {
            verdict.diverged(["read at live handle: \(id), model \(entry.id)"])
        }
    }

    mutating func mutateLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        let id = nextID
        nextID += 1
        verdict.record("mutate @\(entry.handle.index) \(entry.id)→\(id)")
        store[entry.handle] = Item(id: id, census: census)
        expectedDeaths += 1
        model.live[position].id = id
        model.slots[entry.handle.index].id = id
    }

    mutating func seamMove() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("seam-move @\(entry.handle.index)")
        let element = store.move(at: Index<Item>(Ordinal(UInt(entry.handle.index))))
        if element.id != entry.id {
            verdict.diverged(["seam move(at:) returned id \(element.id), model \(entry.id)"])
        }
        model.retire(liveAt: position)
        expectedDeaths += 1
    }

    mutating func growStore() {
        let target = model.capacity + 1 + rng.below(6)
        verdict.record("grow \(model.capacity)→\(target)")
        store.grow(to: typedCount(target))
        model.grow(to: target)
    }

    mutating func wipe() {
        verdict.record("wipe \(model.liveCount) live")
        expectedDeaths += model.liveCount
        store.removeAll()
        model.retireAll()
    }

    func audit() -> [String] {
        var findings: [String] = []
        if store.count != typedCount(model.liveCount) {
            findings.append("count: store \(store.count), model \(model.liveCount)")
        }
        if store.capacity != typedCount(model.capacity) {
            findings.append("capacity: store \(store.capacity), model \(model.capacity)")
        }
        for entry in model.live {
            if !store.contains(entry.handle) {
                findings.append(
                    "α: live handle @\(entry.handle.index)g\(entry.handle.generation) rejected"
                )
            } else if store[entry.handle].id != entry.id {
                findings.append("live handle resolves \(store[entry.handle].id), model \(entry.id)")
            }
        }
        for entry in model.stale where store.contains(entry.handle) {
            findings.append(
                "β: stale handle @\(entry.handle.index)g\(entry.handle.generation) re-validated"
            )
        }
        if census.died.count != expectedDeaths {
            findings.append(
                "teardown drift: \(census.died.count) deaths, expected \(expectedDeaths) (relocation/double-deinit class)"
            )
        }
        return findings
    }

    mutating func step() {
        var branch = rng.below(100)

        if model.stale.isEmpty, branch >= 52, branch < 60 { branch = 60 }
        if model.live.isEmpty, branch >= 30, branch < 86 { branch = 0 }
        if model.liveCount == model.capacity, branch < 30 { branch = 34 }

        switch branch {
        case 0..<30: insertNew()
        case 30..<52: removeLive()
        case 52..<60: removeStale()
        case 60..<72: readLive()
        case 72..<80: mutateLive()
        case 80..<86: seamMove()
        case 86..<90: growStore()
        default: wipe()
        }
    }

    mutating func run() {
        let operations = Model.operations(default: 800)
        var op = 0
        while op < operations, verdict.isClean {
            step()
            if Model.shouldAudit(op: op, of: operations) {
                verdict.diverged(audit())
            }
            op += 1
        }
    }

    consuming func finish() -> (verdict: Model.Verdict, expectedDeaths: Int, liveAtEnd: Int) {
        (verdict, expectedDeaths, model.liveCount)
    }
}

private struct MoveOnlyStream: ~Copyable {
    var store: Slots<Model.Element.Tracked>
    var model: Reference
    var rng: Model.Random
    var verdict: Model.Verdict
    var nextID = 0
    var expectedDeaths = 0
    let census: Model.Census

    init(seed: UInt64, census: Model.Census) {
        var rng = Model.Random(seed: seed)
        let capacity = 2 + rng.below(11)
        self.store = Slots<Model.Element.Tracked>.create(
            slotCapacity: typedCount(capacity)
        )
        self.model = Reference(capacity: capacity)
        self.rng = rng
        self.verdict = Model.Verdict(seed: seed)
        self.census = census
    }
}

extension MoveOnlyStream {
    mutating func insertNew() {
        let id = nextID
        nextID += 1
        let handle = store.insert(Model.Element.Tracked(id: id, census: census))
        verdict.record("insert id=\(id) → @\(handle.index)g\(handle.generation)")
        verdict.diverged(model.admit(handle, id: id))
    }

    mutating func removeLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("remove id=\(entry.id)")
        if let element = store.remove(entry.handle) {
            if element.id != entry.id {
                verdict.diverged(["remove returned id \(element.id), model \(entry.id)"])
            }
            model.retire(liveAt: position)
            expectedDeaths += 1
        } else {
            verdict.diverged(["remove rejected a LIVE handle (α)"])
        }
    }

    mutating func removeStale() {
        let entry = model.stale[rng.below(model.stale.count)]
        verdict.record("stale-remove @\(entry.handle.index)g\(entry.handle.generation)")
        if let element = store.remove(entry.handle) {
            verdict.diverged(["STALE handle re-validated through remove (β): id \(element.id)"])
        }
    }

    mutating func readLive() {
        let entry = model.live[rng.below(model.live.count)]
        verdict.record("read id=\(entry.id)")
        let id = store[entry.handle].id
        if id != entry.id {
            verdict.diverged(["read at live handle: \(id), model \(entry.id)"])
        }
    }

    mutating func mutateLive() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        let id = nextID
        nextID += 1
        verdict.record("mutate @\(entry.handle.index) \(entry.id)→\(id)")
        store[entry.handle] = Model.Element.Tracked(id: id, census: census)
        expectedDeaths += 1
        model.live[position].id = id
        model.slots[entry.handle.index].id = id
    }

    mutating func seamMove() {
        let position = rng.below(model.live.count)
        let entry = model.live[position]
        verdict.record("seam-move @\(entry.handle.index)")
        let element = store.move(
            at: Index<Model.Element.Tracked>(Ordinal(UInt(entry.handle.index)))
        )
        if element.id != entry.id {
            verdict.diverged(["seam move(at:) returned id \(element.id), model \(entry.id)"])
        }
        model.retire(liveAt: position)
        expectedDeaths += 1
    }

    mutating func growStore() {
        let target = model.capacity + 1 + rng.below(6)
        verdict.record("grow \(model.capacity)→\(target)")
        store.grow(to: typedCount(target))
        model.grow(to: target)
    }

    mutating func wipe() {
        verdict.record("wipe \(model.liveCount) live")
        expectedDeaths += model.liveCount
        store.removeAll()
        model.retireAll()
    }

    func audit() -> [String] {
        var findings: [String] = []
        if store.count != typedCount(model.liveCount) {
            findings.append("count: store \(store.count), model \(model.liveCount)")
        }
        if store.capacity != typedCount(model.capacity) {
            findings.append("capacity: store \(store.capacity), model \(model.capacity)")
        }
        for entry in model.live {
            if !store.contains(entry.handle) {
                findings.append(
                    "α: live handle @\(entry.handle.index)g\(entry.handle.generation) rejected"
                )
            } else if store[entry.handle].id != entry.id {
                findings.append("live handle resolves \(store[entry.handle].id), model \(entry.id)")
            }
        }
        for entry in model.stale where store.contains(entry.handle) {
            findings.append(
                "β: stale handle @\(entry.handle.index)g\(entry.handle.generation) re-validated"
            )
        }
        if census.died.count != expectedDeaths {
            findings.append(
                "teardown drift: \(census.died.count) deaths, expected \(expectedDeaths) (relocation/double-deinit class)"
            )
        }
        return findings
    }

    mutating func step() {
        var branch = rng.below(100)

        if model.stale.isEmpty, branch >= 52, branch < 60 { branch = 60 }
        if model.live.isEmpty, branch >= 30, branch < 86 { branch = 0 }
        if model.liveCount == model.capacity, branch < 30 { branch = 34 }

        switch branch {
        case 0..<30: insertNew()
        case 30..<52: removeLive()
        case 52..<60: removeStale()
        case 60..<72: readLive()
        case 72..<80: mutateLive()
        case 80..<86: seamMove()
        case 86..<90: growStore()
        default: wipe()
        }
    }

    mutating func run() {
        let operations = Model.operations(default: 800)
        var op = 0
        while op < operations, verdict.isClean {
            step()
            if Model.shouldAudit(op: op, of: operations) {
                verdict.diverged(audit())
            }
            op += 1
        }
    }

    consuming func finish() -> (verdict: Model.Verdict, expectedDeaths: Int, liveAtEnd: Int) {
        (verdict, expectedDeaths, model.liveCount)
    }
}

private func runTrivialStream(seed: UInt64) -> Model.Verdict {
    var stream = TrivialStream(seed: seed)
    stream.run()
    return stream.finish()
}

private func runRefcountedStream(seed: UInt64) -> Model.Verdict {
    let census = Model.Census()
    var stream = RefcountedStream(seed: seed, census: census)
    stream.run()
    let (finished, expectedDeaths, liveAtEnd) = stream.finish()
    var verdict = finished

    if census.died.count != expectedDeaths + liveAtEnd {
        verdict.findings.append(
            "teardown inexact at end: \(census.died.count) deaths, expected \(expectedDeaths) + \(liveAtEnd) live"
        )
    }
    if census.born.sorted() != census.died.sorted() {
        verdict.findings.append(
            "teardown multiset broken: \(census.born.count) born vs \(census.died.count) died"
        )
    }
    return verdict
}

private func runMoveOnlyStream(seed: UInt64) -> Model.Verdict {
    let census = Model.Census()
    var stream = MoveOnlyStream(seed: seed, census: census)
    stream.run()
    let (finished, expectedDeaths, liveAtEnd) = stream.finish()
    var verdict = finished

    if census.died.count != expectedDeaths + liveAtEnd {
        verdict.findings.append(
            "teardown inexact at end: \(census.died.count) deaths, expected \(expectedDeaths) + \(liveAtEnd) live"
        )
    }
    if census.born.sorted() != census.died.sorted() {
        verdict.findings.append(
            "teardown multiset broken: \(census.born.count) born vs \(census.died.count) died"
        )
    }
    return verdict
}

@Suite
struct `Storage.Generational Model` {
    @Suite struct Unit {}
    @Suite struct `Edge Case` {}
    @Suite struct Integration {}
}

extension `Storage.Generational Model`.Integration {
    @Test(arguments: Model.seeds(default: [0x6E4E_2A71, 0x0A2E_4A01, 0x5107_3A92]))
    func `trivial ledger stream matches the (occupied, generation) reference`(seed: UInt64) {
        let verdict = runTrivialStream(seed: seed)
        #expect(verdict.isClean, Comment(rawValue: verdict.report))
    }

    @Test(arguments: Model.seeds(default: [0x2EFC_0017, 0xCAFE_D00D]))
    func `refcounted ledger stream stays exact through grow and mutate`(seed: UInt64) {
        let verdict = runRefcountedStream(seed: seed)
        #expect(verdict.isClean, Comment(rawValue: verdict.report))
    }

    @Test(arguments: Model.seeds(default: [0x303E_0517, 0xDEAD_B017]))
    func `move-only ledger stream tears down exactly through relocation`(seed: UInt64) {
        let verdict = runMoveOnlyStream(seed: seed)
        #expect(verdict.isClean, Comment(rawValue: verdict.report))
    }
}

extension `Storage.Generational Model`.Unit {
    @Test
    func `grow preserves live handles, stale handles, and the incarnation history`() {
        var store = Slots<Int>.create(slotCapacity: typedCount(3))
        let a = store.insert(10)
        let b = store.insert(20)
        let c = store.insert(30)
        _ = store.remove(b)

        store.grow(to: typedCount(8))

        let capacity = store.capacity
        #expect(capacity == typedCount(8))
        let count = store.count
        #expect(count == typedCount(2))
        let aLives = store.contains(a)
        let cLives = store.contains(c)
        #expect(aLives)
        #expect(cLives)
        let aValue = store[a]
        let cValue = store[c]
        #expect(aValue == 10)
        #expect(cValue == 30)
        let bStale = store.contains(b)
        #expect(!bStale)
        let bRemoved = store.remove(b)
        #expect(bRemoved == nil)

        var freshHandles: [Handle] = []
        (0..<6).forEach { id in
            freshHandles.append(store.insert(100 + id))
        }
        for fresh in freshHandles where fresh.index == b.index {
            #expect(fresh.generation == b.generation + 1)
        }
        let stillStale = store.contains(b)
        #expect(!stillStale)
    }

    @Test
    func `generation continuity across reuse: the capacity-1 forced cycle`() {
        var store = Slots<Int>.create(slotCapacity: typedCount(1))
        let first = store.insert(1)
        #expect(first.generation == 0)
        let one = store.remove(first)
        #expect(one == 1)
        let second = store.insert(2)
        #expect(second.index == first.index)
        #expect(second.generation == 1)
        let firstStale = store.contains(first)
        let secondLive = store.contains(second)
        #expect(!firstStale)
        #expect(secondLive)
        let value = store[second]
        #expect(value == 2)
    }
}

extension `Storage.Generational Model`.`Edge Case` {
    @Test
    func `a stale handle over a REUSED slot never aliases the new occupant`() {
        let census = Model.Census()
        do {
            var store = Slots<Model.Element.Tracked>.create(slotCapacity: typedCount(1))
            let first = store.insert(Model.Element.Tracked(id: 1, census: census))
            if let removed = store.remove(first) {
                let id = removed.id
                #expect(id == 1)
            } else {
                Issue.record("expected the live handle to remove")
            }
            _ = store.insert(Model.Element.Tracked(id: 2, census: census))
            let aliased = store.contains(first)
            #expect(!aliased)
            if let ghost = store.remove(first) {
                Issue.record("stale handle yielded id \(ghost.id) over the reused slot")
            }
        }
        let born = census.born.sorted()
        let died = census.died.sorted()
        #expect(born == died)
    }

    @Test
    func `removeAll stales everything; reuse mints at bumped generations`() {
        var store = Slots<Int>.create(slotCapacity: typedCount(4))
        let handles = [store.insert(0), store.insert(1), store.insert(2)]
        store.removeAll()
        let empty = store.isEmpty
        #expect(empty)
        for handle in handles {
            let stale = store.contains(handle)
            #expect(!stale)
        }
        let fresh = store.insert(9)
        #expect(fresh.generation >= 1)
        let value = store[fresh]
        #expect(value == 9)
    }

    @Test
    func `the capacity boundary: remove-then-insert cycles at full`() {
        var store = Slots<Int>.create(slotCapacity: typedCount(2))
        let a = store.insert(1)
        _ = store.insert(2)
        let count = store.count
        #expect(count == typedCount(2))
        let freed = store.remove(a)
        #expect(freed == 1)
        let replacement = store.insert(3)
        #expect(replacement.index == a.index)
        #expect(replacement.generation == a.generation + 1)
        let full = store.count
        #expect(full == typedCount(2))
    }
}

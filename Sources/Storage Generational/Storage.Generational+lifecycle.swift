public import Index
public import Memory_Allocator_Pool
public import Memory_Allocator_Primitive
public import Memory_Heap
import Ordinal_Standard_Library_Integration

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @inlinable
    public mutating func removeAll() {
        var i = 0
        while i < _slotCount {
            if _isOccupied(i) {
                unsafe _ptr(at: i).deinitialize(count: 1)
                _release(i)
                let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(i)))

                try! allocation.deallocate(at: slot)
            }
            i &+= 1
        }
        _count = 0
    }
}

extension Storage.Generational
where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: Copyable {

    @inlinable
    public borrowing func clone() -> Self {
        var fresh = Self.create(slotCapacity: capacity)
        var claimed = 0
        while claimed < _slotCount {

            _ = try! fresh.allocation.allocateSlot()
            claimed &+= 1
        }

        var i = 0
        while i < _slotCount {
            let occupied = _isOccupied(i)
            if occupied {
                unsafe fresh._ptr(at: i).initialize(to: unsafe _ptr(at: i).pointee)
            }
            fresh._seedLedger(i, occupied: occupied, generation: _generation(i))
            i &+= 1
        }

        var j = _slotCount
        while j > 0 {
            j &-= 1
            if fresh._isOccupied(j) { continue }
            let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(j)))

            try! fresh.allocation.deallocate(at: slot)
        }
        fresh._count = _count
        return fresh
    }
}

extension Storage.Generational
where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: ~Copyable {

    @inlinable
    public mutating func grow(to slotCapacity: Index<Element>.Count) {
        precondition(
            slotCapacity >= capacity,
            "Storage.Generational.grow(to:): the slot universe never shrinks"
        )
        let targetCount = Int(bitPattern: slotCapacity)
        var fresh = Self.create(slotCapacity: slotCapacity)

        var claimed = 0
        while claimed < targetCount {

            _ = try! fresh.allocation.allocateSlot()
            claimed &+= 1
        }

        var i = 0
        while i < _slotCount {
            let occupied = _isOccupied(i)
            if occupied {
                unsafe fresh._ptr(at: i).initialize(to: unsafe _ptr(at: i).move())
                _clearForRetire(i)
            }
            fresh._seedLedger(i, occupied: occupied, generation: _generation(i))
            i &+= 1
        }

        var j = targetCount
        while j > 0 {
            j &-= 1
            if j < _slotCount && fresh._isOccupied(j) { continue }
            let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(j)))

            try! fresh.allocation.deallocate(at: slot)
        }
        fresh._count = _count
        _count = 0

        self = fresh
    }
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @inlinable
    public func forEach(_ body: (borrowing Element) -> Void) {
        var i = 0
        while i < _slotCount {
            if _isOccupied(i) {
                let pointer = unsafe _ptr(at: i)
                body(unsafe pointer.pointee)
            }
            i &+= 1
        }
    }
}

public import Index
public import Memory_Allocator_Pool
public import Memory_Pool
public import Ordinal
public import Ordinal_Standard_Library_Integration
public import Storage
public import Store
public import Store_Protocol

extension Storage.Generational: Store.`Protocol`
where Allocation: ~Copyable, Element: ~Copyable {

    @inlinable
    public subscript(slot: Index<Element>) -> Element {
        _read {
            let i = Int(bitPattern: slot)
            precondition(
                i < _slotCount && _isOccupied(i),
                "generational seam: subscript on an unoccupied slot"
            )
            let pointer = unsafe _ptr(at: i)
            yield unsafe pointer.pointee
        }
        _modify {
            let i = Int(bitPattern: slot)
            precondition(
                i < _slotCount && _isOccupied(i),
                "generational seam: subscript on an unoccupied slot"
            )
            let pointer = unsafe _ptr(at: i)
            yield &(unsafe pointer.pointee)
        }
    }

    @inlinable
    public mutating func initialize(at slot: Index<Element>, to element: consuming Element) {
        let handle = insert(element)
        precondition(
            handle.index == Int(bitPattern: slot),
            "generational seam: initialize is lawful only at the store's next-free slot"
        )
    }

    @inlinable
    public mutating func move(at slot: Index<Element>) -> Element {
        let i = Int(bitPattern: slot)
        precondition(
            i < _slotCount && _isOccupied(i),
            "generational seam: move on an unoccupied slot"
        )
        let element = unsafe _ptr(at: i).move()
        _release(i)
        let poolSlot = Index<Memory.Pool.Slot>(Ordinal(UInt(i)))

        try! allocation.deallocate(at: poolSlot)
        _count &-= 1
        return element
    }
}

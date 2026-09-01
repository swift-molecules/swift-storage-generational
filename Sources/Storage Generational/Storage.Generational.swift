public import Cardinal
public import Cardinal_Carrier
public import Cardinal_Standard_Library_Integration
public import Index
public import Memory
public import Memory_Allocator_Pool
public import Memory_Pool
public import Memory_Allocator
public import Ordinal
public import Ordinal_Standard_Library_Integration
public import Storage
public import Store
public import Store_Protocol
public import Tagged

extension Storage where Allocation: Memory.Pooling, Allocation: ~Copyable {

    @safe
    @frozen
    public struct Generational<Element: ~Copyable>: ~Copyable {

        @usableFromInline
        internal var allocation: Allocation

        @usableFromInline
        internal let _slotCount: Int

        @usableFromInline
        internal var _tokens: Memory.Heap

        @usableFromInline
        internal var _count: Int

        @usableFromInline
        internal init(
            allocation: consuming Allocation,
            slotCount: Int
        ) {
            self.allocation = allocation
            self._slotCount = slotCount
            let tokenBytes = Memory.Address.Count(
                _unchecked: Cardinal(UInt(slotCount * MemoryLayout<Int>.stride))
            )

            let alignment = try! Memory.Alignment(MemoryLayout<Int>.alignment)
            let tokens = Memory.Heap(byteCount: tokenBytes, alignment: alignment)

            unsafe tokens.base.mutablePointer.initializeMemory(
                as: Int.self,
                repeating: 0,
                count: slotCount
            )
            self._tokens = tokens
            self._count = 0
        }

        deinit {
            var i = 0
            while i < _slotCount {
                if _isOccupied(i) { unsafe _ptr(at: i).deinitialize(count: 1) }
                i &+= 1
            }
        }
    }
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @usableFromInline
    internal func _ptr(at i: Int) -> UnsafeMutablePointer<Element> {
        unsafe allocation.pointer(at: Index<Memory.Pool.Slot>(Ordinal(UInt(i))))
            .assumingMemoryBound(to: Element.self)
    }
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @usableFromInline
    internal func _tokenPtr() -> UnsafeMutablePointer<Int> {
        unsafe _tokens.base.mutablePointer.assumingMemoryBound(to: Int.self)
    }

    @inlinable
    package var _tokenSpan: Swift.Span<Int> {
        @_lifetime(borrow self)
        get {
            let span = unsafe Swift.Span(_unsafeStart: _tokenPtr(), count: _slotCount)
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    @inlinable
    package var _tokenMutableSpan: Swift.MutableSpan<Int> {
        @_lifetime(&self)
        mutating get {
            let span = unsafe Swift.MutableSpan(_unsafeStart: _tokenPtr(), count: _slotCount)
            return unsafe _overrideLifetime(span, mutating: &self)
        }
    }

    @inlinable
    package func _isOccupied(_ i: Int) -> Bool {
        _tokenSpan[i] & 1 == 1
    }

    @inlinable
    package func _generation(_ i: Int) -> Int {
        _tokenSpan[i] >> 1
    }

    @inlinable
    package mutating func _claim(_ i: Int) {
        unsafe _tokenPtr()[i] &+= 1
    }

    @inlinable
    package mutating func _release(_ i: Int) {
        unsafe _tokenPtr()[i] &+= 1
    }

    @inlinable
    package mutating func _clearForRetire(_ i: Int) {
        unsafe _tokenPtr()[i] &-= 1
    }

    @inlinable
    package mutating func _seedLedger(_ i: Int, occupied: Bool, generation: Int) {
        unsafe _tokenPtr()[i] = (generation << 1) | (occupied ? 1 : 0)
    }
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    public typealias Handle = Store.Generational.Handle
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @inlinable
    public var count: Tagged<Element, Cardinal> {
        Tagged<Element, Cardinal>(_unchecked: Cardinal(UInt(_count)))
    }

    @inlinable
    public var isEmpty: Bool { _count == 0 }

    @inlinable
    public var capacity: Tagged<Element, Cardinal> {
        Tagged<Element, Cardinal>(_unchecked: Cardinal(UInt(_slotCount)))
    }

    @inlinable
    public func contains(_ handle: Handle) -> Bool {
        handle.index >= 0
            && handle.index < _slotCount
            && _isOccupied(handle.index)
            && _generation(handle.index) == handle.generation
    }

    @inlinable
    public func handle(at index: Index<Element>) -> Handle? {
        let i = Int(bitPattern: index)
        guard i >= 0, i < _slotCount, _isOccupied(i) else { return nil }
        return Handle(index: i, generation: _generation(i))
    }

    @inlinable
    public subscript(_ handle: Handle) -> Element {
        _read {
            precondition(contains(handle), "Storage.Generational: stale or invalid handle")
            let pointer = unsafe _ptr(at: handle.index)
            yield unsafe pointer.pointee
        }
        _modify {
            precondition(contains(handle), "Storage.Generational: stale or invalid handle")
            let pointer = unsafe _ptr(at: handle.index)
            yield &(unsafe pointer.pointee)
        }
    }
}

extension Storage.Generational
where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: ~Copyable {

    @inlinable
    public static func create(slotCapacity: Tagged<Element, Cardinal>) -> Self {
        precondition(slotCapacity > .zero, "Storage.Generational: capacity must be positive")
        let slotCount = Int(bitPattern: slotCapacity)
        let elementStride = MemoryLayout<Element>.stride
        let minSlot = MemoryLayout<Index<Memory.Pool.Slot>>.size
        let slotSizeBytes = Swift.max(elementStride, minSlot)
        let slotSize = Memory.Address.Count(_unchecked: Cardinal(UInt(slotSizeBytes)))

        let alignment = try! Memory.Alignment(MemoryLayout<Element>.alignment)
        let backingByteCount = Memory.Address.Count(
            _unchecked: Cardinal(UInt(slotSizeBytes * slotCount))
        )
        let backing = Memory.Heap(byteCount: backingByteCount, alignment: alignment)
        let pool = try! Memory.Allocator<Memory.Heap>.Pool(
            carving: backing,
            slotSize: slotSize,
            slotAlignment: alignment
        )
        return Self(allocation: pool, slotCount: slotCount)
    }
}

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {

    @inlinable
    public mutating func insert(_ element: consuming Element) -> Handle {
        let slot: Index<Memory.Pool.Slot>
        do throws(Memory.Pool.Error) {
            slot = try allocation.allocateSlot()
        } catch {
            fatalError("Storage.Generational: pool exhausted")
        }
        let n = Int(bitPattern: slot)
        unsafe _ptr(at: n).initialize(to: element)
        _claim(n)
        _count &+= 1
        return Handle(index: n, generation: _generation(n))
    }

    @inlinable
    public mutating func remove(_ handle: Handle) -> Element? {
        guard contains(handle) else { return nil }
        let element = unsafe _ptr(at: handle.index).move()
        _release(handle.index)
        let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(handle.index)))

        try! allocation.deallocate(at: slot)
        _count &-= 1
        return element
    }
}

extension Storage.Generational: @unchecked Sendable
where Allocation: ~Copyable & Sendable, Element: Sendable {}

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

public import Index_Primitives
public import Memory_Address_Primitives
public import Memory_Alignment_Primitives
public import Memory_Allocator_Pool_Primitives
public import Memory_Allocator_Primitive
public import Memory_Heap_Primitives
public import Memory_Primitive
import Ordinal_Primitive
import Ordinal_Primitives_Standard_Library_Integration
public import Storage_Primitive
public import Store_Primitive

// MARK: - Storage.Generational (the sparse column) — the un-fused Storage.Arena.
//
// Re-homes the shipping `Storage.Arena` generation-token discipline onto the ratified shape
// (rich-template recipe): `Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>`. The
// byte-recycling free list lives in the `Allocation` (a `Memory.Pooling` conformer); the generation
// tokens + occupancy + the deinit oracle live HERE (typed object-state). A `(index, generation)`
// `Handle` rejects stale access after a slot is freed and reused — the slotmap value-add over a
// bare pool.
//
// ## The §A15 re-bound (W5-1, ratified 2026-06-10)
//
// The declaration binds `Allocation: Memory.Pooling` — the law-bearing capability seam — and every
// slot address is derived PER ACCESS through the pool's own `pointer(at:)` (law L3: generic code
// never caches addresses; the old `_baseRaw`/`_slotStride` caches are GONE, and with them the
// measured-stride hack — the pool owns its layout). The seam conformance's conditions become
// inverse-only (`where Allocation: ~Copyable`), retiring the ecosystem's only same-type `~Copyable`
// conditional conformance (catalog §A15 — a shape the runtime cannot verify). The bound lives on
// the DECLARATION because the deinit oracle itself derives pointers, and a deinit cannot be
// constrained after the fact. Canonical spellings stay concrete
// (`Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>` — unchanged everywhere).

extension Storage where Allocation: Memory.Pooling, Allocation: ~Copyable {
    /// ## Safety Invariant
    ///
    /// Pointer-backed value type (`@safe` absorber per [MEM-SAFE-020]; disclosure per
    /// [MEM-SAFE-025c]). Slot addresses are derived PER ACCESS from the owned pool's
    /// `pointer(at:)` (in-range by construction — `Memory.Pooling` law L3); no address is
    /// cached across moves. The struct is `~Copyable`, the allocation is a stored field, and
    /// the deinit oracle destroys exactly the occupied slots before the pool frees the bytes.
    /// Every typed access goes through the validated handle subscript (occupancy + generation
    /// checked) or the occupancy-guarded oracle walk.
    @safe
    @frozen
    public struct Generational<Element: ~Copyable>: ~Copyable {
        /// The stable-slot allocation (a `Memory.Pooling` conformer).
        ///
        /// Owns the bytes; frees them on `deinit`.
        @usableFromInline
        internal var allocation: Allocation

        /// Total slot count.
        @usableFromInline
        internal let _slotCount: Int

        /// The fused per-slot ledger plane — ONE raw memory-tier region of
        /// parity-packed tokens: `token = (generation << 1) | occupied`.
        ///
        /// Both
        /// lifecycle transitions are `token &+= 1` (claim: even→odd, generation
        /// unchanged; release: odd→even, generation bumped) — the observable
        /// generation sequence is EXACTLY the prior two-plane ledger's, and
        /// validation reads ONE plane location. The plane is `Memory.Heap`-backed
        /// (always fully initialized, trivial element — no initialization ledger to
        /// pay on the hot path); the typed base derives PER ACCESS from the owned
        /// region per the [MEM-SAFE-029] concrete heap-pinned carve.
        @usableFromInline
        internal var _tokens: Memory.Heap

        /// Live occupancy.
        @usableFromInline
        internal var _count: Int

        @usableFromInline
        internal init(
            allocation: consuming Allocation,
            slotCount: Int
        ) {
            self.allocation = allocation
            self._slotCount = slotCount
            let tokenBytes = Memory.Address.Count(UInt(slotCount * MemoryLayout<Int>.stride))
            // WHY: alignof(Int) is a positive power of two → the validating init never throws.
            // swift-format-ignore: NeverUseForceTry
            // swiftlint:disable:next force_try
            let alignment = try! Memory.Alignment(MemoryLayout<Int>.alignment)
            let tokens = Memory.Heap(byteCount: tokenBytes, alignment: alignment)
            // SAFETY: the region was just allocated with exactly `slotCount` Int strides;
            // SAFETY: zero-fill makes every slot's token (generation 0, free) before any read.
            unsafe tokens.base.mutablePointer.initializeMemory(as: Int.self, repeating: 0, count: slotCount)
            self._tokens = tokens
            self._count = 0
        }

        /// The typed pointer to slot `i` — derived PER ACCESS through the pool's own
        /// `pointer(at:)` (L3; the pool owns its layout, including any stride padding).
        @usableFromInline
        internal func _ptr(at i: Int) -> UnsafeMutablePointer<Element> {
            unsafe allocation.pointer(at: Index<Memory.Pool.Slot>(Ordinal(UInt(i))))
                .assumingMemoryBound(to: Element.self)
        }

        // MARK: - Ledger plane accessors
        //
        // The token plane's typed base derives PER ACCESS from the owned heap region
        // (the same discipline as `_ptr(at:)`; [MEM-SAFE-029]'s concrete heap-pinned
        // carve — the region is out-of-line with a stable base). Every index is
        // in-range by construction: `i < _slotCount` == the plane's slot count.

        /// The token plane's typed base.
        @usableFromInline
        internal func _tokenPtr() -> UnsafeMutablePointer<Int> {
            unsafe _tokens.base.mutablePointer.assumingMemoryBound(to: Int.self)
        }

        /// A bounds-checked read span over the whole token plane (span-typed access;
        /// the unsafe construction is localized HERE — the count is the plane's
        /// allocated slot count by construction).
        @inlinable
        internal var _tokenSpan: Swift.Span<Int> {
            @_lifetime(borrow self)
            get {
                let span = unsafe Swift.Span(_unsafeStart: _tokenPtr(), count: _slotCount)
                return unsafe _overrideLifetime(span, borrowing: self)
            }
        }

        /// A bounds-checked mutable span over the whole token plane.
        @inlinable
        internal var _tokenMutableSpan: Swift.MutableSpan<Int> {
            @_lifetime(&self)
            mutating get {
                let span = unsafe Swift.MutableSpan(_unsafeStart: _tokenPtr(), count: _slotCount)
                return unsafe _overrideLifetime(span, mutating: &self)
            }
        }

        /// Whether the ledger token for slot `i` is occupied (odd parity).
        @inlinable
        internal func _isOccupied(_ i: Int) -> Bool {
            _tokenSpan[i] & 1 == 1
        }

        /// The current generation of slot `i` (the token's high bits).
        @inlinable
        internal func _generation(_ i: Int) -> Int {
            _tokenSpan[i] >> 1
        }

        /// Ledger transition: free slot `i` becomes occupied (insert claims it) —
        /// even→odd, generation unchanged (it names the incarnation being created).
        ///
        /// SAFETY: `i` is in `[0, _slotCount)` at every call site (the plane's
        /// SAFETY: allocated extent); the write goes through the owned region's
        /// SAFETY: stable base ([MEM-SAFE-029] concrete heap-pinned carve).
        @inlinable
        internal mutating func _claim(_ i: Int) {
            unsafe _tokenPtr()[i] &+= 1
        }

        /// Ledger transition: occupied slot `i` is freed — odd→even with the
        /// generation bumped, so every outstanding handle to the slot goes stale.
        ///
        /// SAFETY: see `_claim` — in-range by construction, stable owned base.
        @inlinable
        internal mutating func _release(_ i: Int) {
            unsafe _tokenPtr()[i] &+= 1
        }

        /// Clears the occupancy of slot `i` WITHOUT a generation bump — the retiring-store
        /// inerting step inside `grow(to:)` (the moved-out source must not re-destroy).
        ///
        /// SAFETY: see `_claim` — in-range by construction, stable owned base.
        @inlinable
        internal mutating func _clearForRetire(_ i: Int) {
            unsafe _tokenPtr()[i] &-= 1
        }

        /// Seeds the whole ledger entry of slot `i` — the clone/grow continuation path.
        ///
        /// SAFETY: see `_claim` — in-range by construction, stable owned base.
        @inlinable
        internal mutating func _seedLedger(_ i: Int, occupied: Bool, generation: Int) {
            unsafe _tokenPtr()[i] = (generation << 1) | (occupied ? 1 : 0)
        }

        /// **The deinit oracle.**
        ///
        /// Destroys every still-occupied slot, THEN the `allocation` (pool) is
        /// destroyed → frees the raw bytes. Occupancy is content-independent, so this never
        /// double-destroys a freed slot.
        deinit {
            var i = 0
            while i < _slotCount {
                if _isOccupied(i) { unsafe _ptr(at: i).deinitialize(count: 1) }
                i &+= 1
            }
        }

        /// The generational slot handle — the canonical spelling of the non-generic carrier
        /// `Store.Generational.Handle` (hoisted so generic composers can STORE handles without
        /// naming this type's full instantiation; see `Store.Generational.swift`).
        public typealias Handle = Store.Generational.Handle
    }
}

// MARK: - Properties

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {
    /// Live occupancy (typed — the ADT-families H′ retype, 2026-06-10; the prior `Int`
    /// spelling is gone, full-breakage per R1).
    @inlinable
    public var count: Index<Element>.Count { Index<Element>.Count(UInt(_count)) }

    /// Whether no slots are occupied.
    @inlinable
    public var isEmpty: Bool { _count == 0 }

    /// Total slot capacity (typed — see `count`).
    @inlinable
    public var capacity: Index<Element>.Count { Index<Element>.Count(UInt(_slotCount)) }

    /// Validates a handle: in range, slot occupied, and generation matches (not stale).
    @inlinable
    public func contains(_ handle: Handle) -> Bool {
        handle.index >= 0
            && handle.index < _slotCount
            && _isOccupied(handle.index)
            && _generation(handle.index) == handle.generation
    }

    /// The CURRENT live handle for the slot at `index`, or `nil` if the slot is
    /// unoccupied — the Position-decode door (Round M B2): a live handle is always
    /// `(index, the slot's current generation)`, so a composer that holds positions
    /// need not side-table handles; it reconstructs them from the ledger.
    @inlinable
    public func handle(at index: Index<Element>) -> Handle? {
        let i = Int(bitPattern: index)
        guard i >= 0, i < _slotCount, _isOccupied(i) else { return nil }
        return Handle(index: i, generation: _generation(i))
    }

    /// Validated access.
    ///
    /// Precondition: the handle is live (use `contains` for a soft check).
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

// MARK: - Heap-pool-backed construction (construction pins, operations generic)

extension Storage.Generational where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: ~Copyable {
    /// Creates generational storage over a fresh heap `Pool` carving `slotCapacity` element slots.
    ///
    /// Typed count per the conversions discipline (Round M A3 — matches `grow(to:)`).
    @inlinable
    public static func create(slotCapacity: Index<Element>.Count) -> Self {
        precondition(slotCapacity > .zero, "Storage.Generational: capacity must be positive")
        let slotCount = Int(bitPattern: slotCapacity)
        let elementStride = MemoryLayout<Element>.stride
        let minSlot = MemoryLayout<Index<Memory.Pool.Slot>>.size
        let slotSizeBytes = Swift.max(elementStride, minSlot)
        let slotSize = Memory.Address.Count(UInt(slotSizeBytes))
        // WHY: alignof(Element) is always a positive power of two → the validating init never throws.
        // swift-format-ignore: NeverUseForceTry
        // swiftlint:disable:next force_try
        let alignment = try! Memory.Alignment(MemoryLayout<Element>.alignment)
        let capacity = Index<Memory.Pool.Slot>.Count(UInt(slotCount))
        // WHY: capacity > 0 (precondition) and slotSize >= the in-band link size (max above) → no throw.
        // swift-format-ignore: NeverUseForceTry
        // swiftlint:disable:next force_try
        let pool = try! Memory.Allocator<Memory.Heap>.Pool(
            slotSize: slotSize,
            slotAlignment: alignment,
            capacity: capacity
        )
        return Self(allocation: pool, slotCount: slotCount)
    }
}

// MARK: - Slot lifecycle (insert / remove — generic over the pooling seam)

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {
    /// Inserts an element; returns a fresh handle to its slot.
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

    /// Removes by handle.
    ///
    /// Returns the element (moved out) if the handle is valid; nil if stale/invalid.
    /// Bumps the slot generation so all outstanding handles to that slot become stale.
    @inlinable
    public mutating func remove(_ handle: Handle) -> Element? {
        guard contains(handle) else { return nil }
        let element = unsafe _ptr(at: handle.index).move()
        _release(handle.index)
        let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(handle.index)))
        // WHY: `contains` proved the slot live (in range, occupied) — the pool's
        // deallocate cannot fail (Memory.Pooling law L4); trap loudly on divergence.
        // swift-format-ignore: NeverUseForceTry
        // swiftlint:disable:next force_try
        try! allocation.deallocate(at: slot)
        _count &-= 1
        return element
    }
}

// MARK: - Sendable

extension Storage.Generational: @unchecked Sendable
where Allocation: ~Copyable & Sendable, Element: Sendable {}

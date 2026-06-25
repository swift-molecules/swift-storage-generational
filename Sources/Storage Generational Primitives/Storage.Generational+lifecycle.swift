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
public import Memory_Allocator_Pool_Primitives
public import Memory_Allocator_Primitive
public import Memory_Heap_Primitives
import Ordinal_Primitives_Standard_Library_Integration

// MARK: - removeAll + the generation-preserving clone (ASK-H′ build items 3–4)

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {
    /// Destroys every occupied slot and returns it to the pool, bumping each slot's
    /// generation (outstanding handles go stale).
    ///
    /// The `Shared` box's drain strategy
    /// ([MEM-SAFE-028]) — handle enumeration is internal-only, so the drain must live here.
    /// Generic over the pooling seam (the §A15 W5-1 re-bound).
    @inlinable
    public mutating func removeAll() {
        var i = 0
        while i < _slotCount {
            if _isOccupied(i) {
                unsafe _ptr(at: i).deinitialize(count: 1)
                _release(i)
                let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(i)))
                // WHY: the slot was verified occupied above — the pool's deallocate
                // cannot fail (Memory.Pooling law L4); trap loudly on divergence.
                // swift-format-ignore: NeverUseForceTry
                // swiftlint:disable:next force_try
                try! allocation.deallocate(at: slot)
            }
            i &+= 1
        }
        _count = 0
    }
}

extension Storage.Generational
where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: Copyable {
    /// GENERATION-PRESERVING deep copy — the `Shared` clone strategy.
    ///
    /// Outstanding handles MUST survive a CoW detach: a sibling that cloned the box
    /// still resolves the handles it minted before the split, so the copy preserves
    /// slot indices, occupancy, AND generations exactly. Only in-package state copy
    /// can do this — the public handle API can neither enumerate occupancy nor mint
    /// at chosen slots.
    ///
    /// Pool-state fidelity: every slot of the fresh pool is claimed, then exactly the
    /// UN-occupied ones are returned — the fresh free list equals the free set,
    /// independent of the pool's hand-out order. The complement is released in
    /// DESCENDING index order so the LIFO free list hands out ASCENDING from the
    /// lowest free index — fresh-pool (virgin-cursor) parity after a clone.
    ///
    /// - Complexity: O(`capacity`)
    @inlinable
    public borrowing func clone() -> Self {
        var fresh = Self.create(slotCapacity: capacity)
        var claimed = 0
        while claimed < _slotCount {
            // WHY: the fresh pool has exactly `_slotCount` free slots — claiming them
            // all cannot fail; trap loudly on divergence.
            // swift-format-ignore: NeverUseForceTry
            // swiftlint:disable:next force_try
            _ = try! fresh.allocation.allocateSlot()
            claimed &+= 1
        }
        // Pass 1 (ascending): copy the occupied elements index-aligned; the ledger
        // continues the incarnation history verbatim.
        var i = 0
        while i < _slotCount {
            let occupied = _isOccupied(i)
            if occupied {
                unsafe fresh._ptr(at: i).initialize(to: unsafe _ptr(at: i).pointee)
            }
            fresh._seedLedger(i, occupied: occupied, generation: _generation(i))
            i &+= 1
        }
        // Pass 2 (descending): return the un-occupied complement, highest index
        // first, so subsequent allocations hand out ascending.
        var j = _slotCount
        while j > 0 {
            j &-= 1
            if fresh._isOccupied(j) { continue }
            let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(j)))
            // WHY: every slot was just claimed from the fresh pool — deallocating
            // the unoccupied complement cannot fail; trap loudly on divergence.
            // swift-format-ignore: NeverUseForceTry
            // swiftlint:disable:next force_try
            try! fresh.allocation.deallocate(at: slot)
        }
        fresh._count = _count
        return fresh
    }
}

// MARK: - grow (the generation-preserving relocating door — ASK-W2-1, seat-ruled 2026-06-11)

extension Storage.Generational
where Allocation == Memory.Allocator<Memory.Heap>.Pool, Element: ~Copyable {
    /// Grows to a fresh slot universe of `slotCapacity`, retiring the old pool
    /// wholesale and MOVING the occupied elements index-aligned.
    ///
    /// ## L1 purity (the `Memory.Pool` algebra stays untouched)
    ///
    /// NO POOL RELOCATES: the old pool retires wholesale, and the new pool is a
    /// FRESH slot universe whose LEDGER is seeded to continue the incarnation
    /// history — occupancy and generations copy INDEX-ALIGNED, so outstanding
    /// handles keep resolving exactly as before (live ones validate against the
    /// same generation; stale ones stay stale). Growth lives at the LEDGER tier;
    /// the pool algebra's relocation-out-of-scope clause is not weakened.
    ///
    /// Heap-pinned per [PATTERN-059] (it constructs a new pool — construction
    /// pins, operations generic). The move-based sibling of the borrowing
    /// `clone()`: the same claim-all / fill-occupied / release-complement /
    /// copy-generations dance, generalized to `~Copyable` elements via
    /// `_ptr.move()`.
    ///
    /// - Precondition: `slotCapacity >= capacity` (growth never shrinks).
    /// - Complexity: O(`slotCapacity`)
    @inlinable
    public mutating func grow(to slotCapacity: Index<Element>.Count) {
        precondition(
            slotCapacity >= capacity,
            "Storage.Generational.grow(to:): the slot universe never shrinks"
        )
        let targetCount = Int(bitPattern: slotCapacity)
        var fresh = Self.create(slotCapacity: slotCapacity)
        // Claim every fresh slot, then return exactly the un-occupied complement —
        // the fresh free list equals the free set, independent of hand-out order
        // (the clone() dance).
        var claimed = 0
        while claimed < targetCount {
            // WHY: the fresh pool has exactly `slotCapacity` free slots — claiming
            // them all cannot fail; trap loudly on divergence.
            // swift-format-ignore: NeverUseForceTry
            // swiftlint:disable:next force_try
            _ = try! fresh.allocation.allocateSlot()
            claimed &+= 1
        }
        // Pass 1 (ascending): MOVE each occupied element to the SAME index
        // (index-aligned), clearing the old occupancy so the retiring store's
        // deinit oracle stays inert for the moved-out slot. The ledger continues
        // the incarnation history verbatim; the NEW tail slots ([old capacity,
        // slotCapacity)) stay at generation 0 — no handle was ever minted for them.
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
        // Pass 2 (descending): return the free set — the new tail and the
        // un-occupied complement — highest index first, so the LIFO free list
        // hands out ASCENDING from the lowest free index (fresh-pool parity;
        // the post-growth descending hand-out is gone).
        var j = targetCount
        while j > 0 {
            j &-= 1
            if j < _slotCount && fresh._isOccupied(j) { continue }
            let slot = Index<Memory.Pool.Slot>(Ordinal(UInt(j)))
            // WHY: every slot was just claimed and only the occupied ones were
            // filled — deallocating the free complement cannot fail; trap loudly
            // on divergence.
            // swift-format-ignore: NeverUseForceTry
            // swiftlint:disable:next force_try
            try! fresh.allocation.deallocate(at: slot)
        }
        fresh._count = _count
        _count = 0
        // The old store retires wholesale here: its occupancy is fully cleared, so
        // its deinit oracle is inert and the old pool simply frees its bytes.
        self = fresh
    }
}

// MARK: - Occupied-slot iteration (the SlotMap family's forEach)

extension Storage.Generational where Allocation: ~Copyable, Element: ~Copyable {
    /// Calls the given closure for each OCCUPIED slot's element, in slot order.
    ///
    /// Occupancy is internal (the oracle's truth), so iteration lives here; the
    /// SlotMap ADT forwards.
    ///
    /// - Complexity: O(`capacity`)
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

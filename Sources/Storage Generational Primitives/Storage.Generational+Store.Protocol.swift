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
import Ordinal_Primitives_Standard_Library_Integration
public import Store_Protocol_Primitives

// MARK: - The seam, under the GENERATIONAL DISCIPLINE (pool-placed, restricted domain)
//
// Ratified 2026-06-10 (ASK-H′, spike-proven F-5) — the thin raw-slot accessor the W2c
// deferral anticipated, landed at its real composer (the SlotMap ADT tier): admission to
// `Shared` and the family template bound. The HANDLE API remains the slot-map's identity
// surface; these positional witnesses exist for the generic machinery (the gate, the
// laws, the box) and are honest over the per-slot occupancy.
//
// ## THE LAWFUL DOMAIN (occupancy is per-slot; the POOL owns placement)
//
//   • `subscript(slot:)` — any occupied slot (positions are PHYSICAL and stable; no
//     re-anchoring — unlike the ring discipline).
//   • `initialize(at:to:)` — lawful ONLY at the pool's own next-free slot (a fresh
//     pool hands slots densely: 0, 1, 2, …). Out-of-domain traps AFTER allocating
//     (the program is dying; no state obligation survives a precondition failure).
//   • `move(at:)` — vacates any occupied slot: the positional spelling of
//     `remove(_:)`, generation bump included (outstanding handles to it go stale).
//
// The [DS-024] seam-ledger count-laws hold on this domain (proven from this package's
// own suite; fresh-pool order is dense, so the laws' slot sequence is in-domain).
//
// ## The §A15 re-bound (W5-1)
//
// These conditions are INVERSE-ONLY: the `Memory.Pooling` capability bound lives on the
// type declaration. The prior same-type clause
// (`where Allocation == Memory.Allocator<Memory.Heap>.Pool`) was the ecosystem's only
// conditional conformance with a `~Copyable` same-type RHS — the shape the runtime
// cannot verify (catalog §A15). Spike-verified clean debug+release
// (.handoffs/probes-2026-06-10/a15-pooling-seam-spike/).
extension Storage.Generational: Store.`Protocol`
where Allocation: ~Copyable, Element: ~Copyable {
    // `capacity` is witnessed by the typed property (`Storage.Generational.swift`).

    /// Occupied-slot access by position (stable physical slots).
    @inlinable
    public subscript(slot: Index<Element>) -> Element {
        _read {
            let i = Int(bitPattern: slot)
            precondition(i < _slotCount && _isOccupied(i), "generational seam: subscript on an unoccupied slot")
            let pointer = unsafe _ptr(at: i)
            yield unsafe pointer.pointee
        }
        _modify {
            let i = Int(bitPattern: slot)
            precondition(i < _slotCount && _isOccupied(i), "generational seam: subscript on an unoccupied slot")
            let pointer = unsafe _ptr(at: i)
            yield &(unsafe pointer.pointee)
        }
    }

    /// Initializes the pool's NEXT-FREE slot — the pool owns placement; `slot` must
    /// name it (fresh pools hand slots densely from 0).
    @inlinable
    public mutating func initialize(at slot: Index<Element>, to element: consuming Element) {
        let handle = insert(element)
        precondition(
            handle.index == Int(bitPattern: slot),
            "generational seam: initialize is lawful only at the store's next-free slot"
        )
    }

    /// Vacates the occupied slot at the position — the positional `remove(_:)`,
    /// generation bump included.
    @inlinable
    public mutating func move(at slot: Index<Element>) -> Element {
        let i = Int(bitPattern: slot)
        precondition(i < _slotCount && _isOccupied(i), "generational seam: move on an unoccupied slot")
        let element = unsafe _ptr(at: i).move()
        _release(i)
        let poolSlot = Index<Memory.Pool.Slot>(Ordinal(UInt(i)))
        // WHY: the slot was verified occupied (and in range) above, so the pool's
        // deallocate cannot fail (Memory.Pooling law L4); a failure here would mean
        // ledger/pool divergence — trap loudly rather than swallow it.
        // swift-format-ignore: NeverUseForceTry
        // swiftlint:disable:next force_try
        try! allocation.deallocate(at: poolSlot)
        _count &-= 1
        return element
    }
}

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

import Storage_Generational_Primitives
import Storage_Primitive
import Store_Primitive
import Buffer_Primitive
import Memory_Heap_Primitives
import Memory_Allocator_Primitive
import Index_Primitives
import Tagged_Primitives_Standard_Library_Integration
import Ordinal_Primitives
import Ordinal_Primitives_Standard_Library_Integration
import Cardinal_Primitives

// The substrate itself (the slot-map bench triangulates the wrapper above it;
// this bench prices the `_generations`/`_occupied` ledger directly — the
// arc-5 SoA gate input, `Storage.Generational.swift:36–48`).

typealias Arena<E: ~Copyable> =
    Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<E>

extension Bench {
    /// `growRelocate.curve` vs `build.control`: each rep builds occupancy n
    /// (the control) and the curve row additionally calls `grow(to: 2n)` —
    /// the doc derives the grow door's relocation cost as the delta, per n
    /// (the W5-landed door: source occupancy cleared before the retiring
    /// store deinits). One op = one build(+grow) at the row's n.
    /// `contains.valid` / `insertRemove.cycle` / `iterate.full|holes`:
    /// substrate-level mirrors of the slot-map wrapper rows.
    static let curveSizes: [Int] = [256, 4_096, 65_536]

    static func count<E>(_ n: Int) -> Index_Primitives.Index<E>.Count {
        Index_Primitives.Index<E>.Count(Cardinal(UInt(n)))
    }

    static func arenaCases() -> [Result] {
        var results: [Result] = []

        for n in curveSizes {
            let reps = Swift.max(8, copiedSlotsTarget / (4 * n))
            let seed = opaque(1)

            results.append(Result(
                name: "build.control", subject: "tower.direct", n: n, opsPerBatch: reps,
                perOpNs: sample(opsPerBatch: reps) {
                    var acc = 0
                    // cap alternates n / n+1 so the per-rep create is provably
                    // loop-variant: straight-line exact-fill passes, but the
                    // invariant per-rep create in a counted loop trapped
                    // (pool exhausted at rep ≥ 2) — see the W4 report note.
                    for r in 0..<reps {
                        var a = Arena<Int>.create(slotCapacity: Index<Int>.Count(UInt(n &+ (r & 1))))
                        var last = a.insert(seed)
                        for i in 1..<n { last = a.insert(i &+ seed) }
                        acc &+= a.contains(last) ? 1 : 0
                    }
                    sink(acc)
                }
            ))

            results.append(Result(
                name: "growRelocate.curve", subject: "tower.direct", n: n, opsPerBatch: reps,
                perOpNs: sample(opsPerBatch: reps) {
                    var acc = 0
                    for r in 0..<reps {
                        var a = Arena<Int>.create(slotCapacity: Index<Int>.Count(UInt(n &+ (r & 1))))
                        var last = a.insert(seed)
                        for i in 1..<n { last = a.insert(i &+ seed) }
                        a.grow(to: count(2 * n))
                        acc &+= a.contains(last) ? 1 : 0
                    }
                    sink(acc)
                }
            ))
        }

        for n in sizes {
            let passes = Swift.max(1, (elementOpsTarget / 4) / n)
            let ops = passes * n
            let seed = opaque(1)

            var a = Arena<Int>.create(slotCapacity: Index<Int>.Count(UInt(n)))
            var handles: [Store.Generational.Handle] = []
            handles.reserveCapacity(n)
            for i in 0..<n { handles.append(a.insert(i &+ seed)) }

            results.append(Result(
                name: "contains.valid", subject: "tower.direct", n: n, opsPerBatch: ops,
                perOpNs: sample(opsPerBatch: ops) {
                    var alive = 0
                    for _ in 0..<passes {
                        for h in handles where a.contains(h) { alive &+= 1 }
                    }
                    sink(alive)
                }
            ))

            let pairs = Swift.max(1, elementOpsTarget / 8)
            let pairOps = pairs * 2

            // remove-then-insert through a handle ring: occupancy stays at
            // n (never exceeds capacity — the substrate fatals on exhaustion
            // by design), every remove targets a live handle.
            var ring = handles
            var cursor = 0

            results.append(Result(
                name: "removeInsert.cycle", subject: "tower.direct", n: n, opsPerBatch: pairOps,
                perOpNs: sample(opsPerBatch: pairOps) {
                    var acc = 0
                    for i in 0..<pairs {
                        acc &+= a.remove(ring[cursor]) ?? 0
                        ring[cursor] = a.insert(i &+ seed)
                        cursor = (cursor + 1) % ring.count
                    }
                    sink(acc)
                }
            ))

            results.append(Result(
                name: "iterate.full", subject: "tower.direct", n: n, opsPerBatch: ops,
                perOpNs: sample(opsPerBatch: ops) {
                    var sum = 0
                    for _ in 0..<passes {
                        a.forEach { sum &+= $0 }
                    }
                    sink(sum)
                }
            ))

            var holey = Arena<Int>.create(slotCapacity: Index<Int>.Count(UInt(2 * n)))
            var holeyHandles: [Store.Generational.Handle] = []
            holeyHandles.reserveCapacity(2 * n)
            for i in 0..<(2 * n) { holeyHandles.append(holey.insert(i &+ seed)) }
            for (i, h) in holeyHandles.enumerated() where i % 2 == 1 { _ = holey.remove(h) }

            results.append(Result(
                name: "iterate.holes", subject: "tower.direct", n: n, opsPerBatch: ops,
                perOpNs: sample(opsPerBatch: ops) {
                    var sum = 0
                    for _ in 0..<passes {
                        holey.forEach { sum &+= $0 }
                    }
                    sink(sum)
                }
            ))
        }

        return results
    }
}

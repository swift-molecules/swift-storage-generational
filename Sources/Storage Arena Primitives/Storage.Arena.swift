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

public import Storage_Primitive

public import Memory_Arena_Primitives
public import Index_Primitives
public import Memory_Address_Primitives
public import Memory_Alignment_Primitives

extension Storage where Element: ~Copyable {
    /// Slot-based typed storage with generation tokens and SoA layout.
    ///
    /// `Storage<Element>.Arena` is a reference-semantic storage class for arena-style
    /// data structures. It provides:
    /// - SoA layout: per-slot metadata (generation tokens) + element array
    /// - Automatic element cleanup in `deinit` (via generation-token iteration)
    /// - Reference semantics for conditional Copyability in buffer compositions
    ///
    /// ## Design Pattern
    ///
    /// Composes `Memory.Arena` for raw byte management. Storage.Arena lays out
    /// a meta array and an element array contiguously within Memory.Arena's raw
    /// allocation. Memory.Arena manages allocation lifecycle (RAII); Storage.Arena
    /// adds typed layout, element lifecycle, and reference semantics.
    ///
    /// ## Layout
    ///
    /// ```
    /// baseAddress
    /// │
    /// ▼
    /// ┌─────────────────────────────────────────────────────────────────────┐
    /// │ Meta₀ │ Meta₁ │ ... │ Meta_{n-1} │ [align pad] │ E₀ │ ... │ E_{n-1} │
    /// └─────────────────────────────────────────────────────────────────────┘
    /// ```
    ///
    /// ## Ownership
    ///
    /// Intended to be stored by a `Buffer.Arena` (or `Buffer.Arena.Bounded`) struct.
    /// The struct manages the header (occupied count, free-list head); Storage.Arena
    /// manages the backing storage and element deinit.
    public final class Arena {

        // MARK: - Stored Properties

        /// Composed memory arena — owns the raw allocation lifecycle.
        @usableFromInline
        package var _arena: Memory.Arena

        /// Total number of element slots.
        @usableFromInline
        package let _slotCapacity: Index<Element>.Count

        /// Highest slot index ever allocated. Used by deinit to bound iteration.
        /// Must be synced (write-through) from the owning Buffer.Arena's header.
        @usableFromInline
        package var _highWater: Index<Element>.Count

        // MARK: - Package Init

        /// Creates a storage arena from pre-allocated parts.
        @inlinable
        package init(
            _arena: consuming Memory.Arena,
            slotCapacity: Index<Element>.Count,
            highWater: Index<Element>.Count
        ) {
            self._arena = _arena
            self._slotCapacity = slotCapacity
            self._highWater = highWater
        }

        // MARK: - Meta

        /// Per-slot metadata: generation token + free-list link.
        ///
        /// Token parity is the sole occupancy oracle:
        /// - Even token (including 0) → free or virgin
        /// - Odd token → occupied
        ///
        /// `link` chains freed slots into a LIFO free-list.
        /// `UInt32.max` = end of list (no next).
        ///
        /// 8 bytes per slot.
        @frozen
        public struct Meta: BitwiseCopyable {
            /// Parity-tagged generation counter. Even = free, odd = occupied.
            public var token: UInt32

            /// Free-list link: index of the next free slot, or `UInt32.max` if none.
            public var link: UInt32

            /// Creates metadata with the given token and free-list link.
            @inlinable
            public init(token: UInt32, link: UInt32) {
                self.token = token
                self.link = link
            }

            /// Whether this slot is currently occupied (odd token = occupied).
            @inlinable
            public var isOccupied: Bool { token & 1 == 1 }

            /// Virgin slot metadata: token 0 (free, never allocated), no next.
            @inlinable
            public static var virgin: Meta { Meta(token: 0, link: .max) }
        }

        // MARK: - Layout

        /// Byte offset from `baseAddress` to the element region.
        @inlinable
        public static func _elementRegionOffset(
            capacity: Index<Element>.Count
        ) -> Memory.Address.Count {
            let metaBytes: Memory.Address.Count = capacity.retag(Meta.self) * .stride
            let elementAlignment = try! Memory.Alignment(max(MemoryLayout<Element>.alignment, 1))
            return elementAlignment.align.up(metaBytes)
        }

        // MARK: - Internal Pointer Helpers

        /// Internal meta pointer for deinit iteration.
        ///
        /// Mirrors `Storage.Arena.meta` from `Storage_Arena_Primitives`
        /// but is available within the core module for deinit use.
        @unsafe
        @inlinable
        package func _meta(at slot: Index<Element>) -> UnsafeMutablePointer<Meta> {
            unsafe _arena.start.assumingMemoryBound(to: Meta.self)
                + Index<Meta>.Offset(fromZero: slot.retag(Meta.self))
        }

        /// Returns a mutable pointer to the element at the given slot index.
        ///
        /// Used by buffer-layer consumers for initialization, move, and deinitialization.
        /// Also used internally by deinit.
        @unsafe
        @inlinable
        public func pointer(at slot: Index<Element>) -> UnsafeMutablePointer<Element> {
            unsafe _arena.start
                .advanced(by: Int(bitPattern: Self._elementRegionOffset(capacity: _slotCapacity)))
                .assumingMemoryBound(to: Element.self)
                + Index<Element>.Offset(fromZero: slot)
        }

        // MARK: - Deinit

        deinit {
            let end = _highWater.map(Ordinal.init)
            var slot: Index<Element> = .zero
            while slot < end {
                if unsafe _meta(at: slot).pointee.isOccupied {
                    unsafe pointer(at: slot).deinitialize(count: .one)
                }
                slot = slot.successor.saturating()
            }
            // Memory.Arena deinit fires automatically → frees raw storage
        }
    }
}

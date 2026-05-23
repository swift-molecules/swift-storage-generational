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
public import Index_Primitives
public import Memory_Primitives_Standard_Library_Integration
public import Memory_Address_Primitives

// MARK: - Layout

extension Storage.Arena where Element: ~Copyable {
    /// Total bytes required for the SoA layout.
    @inlinable
    public static func _totalBytes(
        capacity: Index<Element>.Count
    ) -> Memory.Address.Count {
        _elementRegionOffset(capacity: capacity) + capacity * .stride
    }
}

// MARK: - Pointer Access

extension Storage.Arena where Element: ~Copyable {
    /// Pointer to the meta array base.
    @unsafe
    @inlinable
    public var meta: UnsafeMutablePointer<Meta> {
        unsafe _arena.start.assumingMemoryBound(to: Meta.self)
    }
}

// MARK: - Factory

extension Storage.Arena where Element: ~Copyable {
    /// Creates an arena with at least the specified element capacity.
    ///
    /// Allocates a contiguous raw buffer via `Memory.Arena` sized for
    /// the SoA layout (meta array + element array). Initializes all
    /// meta slots to virgin state.
    ///
    /// - Parameter minimumCapacity: Number of element slots. Must be > 0.
    /// - Precondition: `minimumCapacity > .zero`
    @inlinable
    public convenience init(minimumCapacity: Index<Element>.Count) {
        precondition(minimumCapacity > .zero, "Arena capacity must be > 0")
        let arena = Memory.Arena(capacity: Self._totalBytes(capacity: minimumCapacity))
        // Initialize meta region to virgin state
        unsafe arena.start.initializeMemory(
            as: Meta.self,
            repeating: .virgin,
            count: Int(bitPattern: minimumCapacity)
        )
        self.init(
            _arena: arena,
            slotCapacity: minimumCapacity,
            highWater: .zero
        )
    }
}

// MARK: - Properties

extension Storage.Arena where Element: ~Copyable {
    /// Total number of element slots.
    @inlinable
    public var slotCapacity: Index<Element>.Count { _slotCapacity }

    /// Highest slot index ever allocated.
    ///
    /// Write-through synced from the owning Buffer.Arena's header.
    @inlinable
    public var highWater: Index<Element>.Count {
        get { _highWater }
        set { _highWater = newValue }
    }
}

// MARK: - Element Operations

extension Storage.Arena where Element: ~Copyable {
    /// Initializes the element at the given slot.
    ///
    /// - Parameter slot: A slot index. Must be < `slotCapacity`.
    /// - Precondition: The slot is not already initialized.
    @inlinable
    public func initialize(to element: consuming Element, at slot: Index<Element>) {
        unsafe pointer(at: slot).initialize(to: element)
    }

    /// Moves the element out of the given slot, leaving the slot deinitialized.
    ///
    /// - Parameter slot: A slot index. Must be < `slotCapacity`.
    /// - Precondition: The slot is initialized.
    /// - Returns: The moved-out element.
    @inlinable
    public func move(at slot: Index<Element>) -> Element {
        unsafe pointer(at: slot).move()
    }

    /// Deinitializes the element at the given slot.
    ///
    /// - Parameter slot: A slot index. Must be < `slotCapacity`.
    /// - Precondition: The slot is initialized.
    @inlinable
    public func deinitialize(at slot: Index<Element>) {
        unsafe pointer(at: slot).deinitialize(count: .one)
    }
}

// MARK: - Sendable

/// `Storage.Arena` is `Sendable` when its elements are `Sendable`.
///
/// ## Safety Invariant
///
/// The class holds `Memory.Arena` + a generation-token meta array without
/// internal synchronization. Soundness depends on the wrapping `~Copyable`
/// container (`Buffer.Arena` / `Buffer.Arena.Bounded`) enforcing single-
/// owner semantics: exactly one struct holds the class reference at any
/// time, and ownership transfer across threads is a move.
///
/// ## Intended Use
///
/// - Moving a `Buffer.Arena`-backed data structure from a producer thread
///   to a consumer thread as a one-shot transfer.
///
/// ## Non-Goals
///
/// Does NOT support concurrent slot allocation/reclamation. All arena
/// operations must be serialized by the owning thread.
extension Storage.Arena: @unsafe @unchecked Sendable where Element: Sendable {}

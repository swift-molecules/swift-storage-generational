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

public import Store_Primitive

extension Store.Generational {
    /// A generational slot handle — `(index, generation)`.
    ///
    /// Stale once its slot is freed (the
    /// slot's generation is bumped), so a reused slot rejects handles minted before the reuse.
    /// Minting is internal to the generational storage; consumers receive handles from
    /// `insert` and validate through `contains`/the validated subscript.
    @frozen
    public struct Handle: Hashable, Sendable {
        /// The slot position this handle names.
        public let index: Int
        /// The slot incarnation this handle was minted for; a later reuse of the slot
        /// bumps the generation, rendering this handle stale.
        public let generation: Int
        @usableFromInline
        internal init(index: Int, generation: Int) {
            self.index = index
            self.generation = generation
        }
    }
}

# swift-storage-generational

![Development Status](https://img.shields.io/badge/status-active--development-blue.svg)

A generation-token slotmap: stable `(index, generation)` handles over a pooled allocation, where freeing a slot bumps its generation so every outstanding handle to it is rejected.

---

## Quick Start

`Storage.Generational` is the un-fused arena: a free-list-backed slot pool carries the bytes, while a per-slot generation ledger lives alongside it. Inserting an element returns a `(index, generation)` `Handle`; removing by handle destroys the element, returns the slot to the pool, and bumps the slot's generation. A handle minted before the slot was freed no longer resolves — so a slot reused for a new element rejects the stale handle that once named it. That is the slotmap's value over a bare pool: use-after-free becomes a checked `false`, not undefined behaviour.

```swift
import Storage_Generational

// A heap-pool-backed generational slotmap holding up to 8 `Int` slots.
var storage = Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Int>
    .create(slotCapacity: Tagged<Int, Cardinal>(_unchecked: Cardinal(8)))

let first = storage.insert(10)              // a (index, generation) handle
let second = storage.insert(20)

print(storage[first], storage[second])      // 10 20

// Remove `first`: the slot is destroyed, returned to the pool, and its
// generation is bumped — so the handle you still hold goes stale.
let taken = storage.remove(first)           // Optional(10)
print(storage.contains(first))              // false

// Insert again: the freed slot is reused, but under a NEW generation.
let third = storage.insert(30)
print(storage.contains(third))              // true  — a live handle
print(storage.contains(first))              // false — use-after-free, caught
```

Beyond `insert` / `remove`, the storage offers `removeAll()` (drain every occupied slot, bumping generations), `clone()` and `grow(to:)` (generation-preserving copy and relocation — handles minted before the copy keep resolving), and `forEach` over the occupied slots. It also witnesses `Store.Protocol`, so generic composers can place it behind a shared box or a family template bound.

---

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/swift-molecules/swift-storage-generational.git", branch: "main")
]
```

```swift
.target(
    name: "App",
    dependencies: [
        .product(name: "Storage Generational", package: "swift-storage-generational"),
    ]
)
```

Requires Swift 6.4 and macOS 27 / iOS 27 / tvOS 27 / watchOS 27 / visionOS 27 (or the matching Linux / Windows toolchain).

---

## Architecture

One library product. Re-exports the storage namespace and the heap-pool allocator tier, so importing this single module spells the full `Storage<Memory.Allocator<Memory.Heap>.Pool>.Generational<Element>` type.

| Product | Target | Purpose |
|---------|--------|---------|
| `Storage Generational` | `Sources/Storage Generational/` | The generational slotmap `Storage<Allocation>.Generational<Element>` over a `Memory.Pooling` allocation, with the per-slot generation ledger, the deinit oracle, and the non-generic `(index, generation)` carrier `Store.Generational.Handle`. |

Foundation-free.

---

## Platform Support

| Platform | Status |
|----------|--------|
| macOS 26 | Full support |
| Linux | Full support |
| Windows | Full support |
| iOS / tvOS / watchOS / visionOS | Supported |

---

## Community

<!-- BEGIN: discussion -->
<!-- Discussion thread created at publication. -->
<!-- END: discussion -->

## License

Apache 2.0. See [LICENSE.md](LICENSE.md).

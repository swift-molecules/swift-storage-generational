// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-storage-generational-primitives",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .tvOS(.v27),
        .watchOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        // MARK: - Generational (the un-fused Storage.Arena: generation tokens over a Pool)
        .library(
            name: "Storage Generational Primitives",
            targets: ["Storage Generational Primitives"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-primitives/swift-storage-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-buffer-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-index-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-ordinal-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-memory-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-memory-heap-primitives.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/swift-primitives/swift-memory-allocation-primitives.git",
            branch: "main"
        ),
    ],
    targets: [

        // MARK: - Generational discipline
        .target(
            name: "Storage Generational Primitives",
            dependencies: [
                .product(name: "Storage Primitive", package: "swift-storage-primitives"),
                .product(name: "Store Primitive", package: "swift-storage-primitives"),
                .product(name: "Store Protocol Primitives", package: "swift-storage-primitives"),
                .product(name: "Buffer Protocol Primitives", package: "swift-buffer-primitives"),
                .product(name: "Index Primitives", package: "swift-index-primitives"),
                .product(name: "Ordinal Primitive", package: "swift-ordinal-primitives"),
                .product(
                    name: "Ordinal Primitives Standard Library Integration",
                    package: "swift-ordinal-primitives"
                ),
                .product(name: "Memory Primitive", package: "swift-memory-primitives"),
                .product(name: "Memory Address Primitives", package: "swift-memory-primitives"),
                .product(name: "Memory Alignment Primitives", package: "swift-memory-primitives"),
                .product(name: "Memory Heap Primitives", package: "swift-memory-heap-primitives"),
                .product(
                    name: "Memory Allocator Primitive",
                    package: "swift-memory-allocation-primitives"
                ),
                .product(
                    name: "Memory Allocator Pool Primitives",
                    package: "swift-memory-allocation-primitives"
                ),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "Storage Generational Primitives Tests",
            dependencies: [
                "Storage Generational Primitives",
                .product(
                    name: "Buffer Primitives Test Support",
                    package: "swift-buffer-primitives"
                ),
                .product(name: "Store Protocol Primitives", package: "swift-storage-primitives"),
                .product(name: "Buffer Protocol Primitives", package: "swift-buffer-primitives"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("LifetimeDependence"),
        .enableExperimentalFeature("Lifetimes"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("LifetimeDependence"),
    ]

    let package: [SwiftSetting] = [
        .enableExperimentalFeature("RawLayout")
    ]

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}

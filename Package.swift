// swift-tools-version: 6.3.1

import PackageDescription

let package = Package(
    name: "swift-storage-arena-primitives",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "Storage Arena Primitives", targets: ["Storage Arena Primitives"]),
        .library(name: "Storage Arena Primitives Test Support", targets: ["Storage Arena Primitives Test Support"]),
    ],
    dependencies: [
        .package(path: "../swift-storage-primitives"),
        .package(path: "../swift-index-primitives"),
        .package(path: "../swift-memory-primitives"),
        .package(path: "../swift-memory-arena-primitives"),
        .package(path: "../swift-property-primitives"),
        .package(path: "../swift-finite-primitives"),
    ],
    targets: [
        .target(
            name: "Storage Arena Primitives",
            dependencies: [
                .product(name: "Storage Primitive", package: "swift-storage-primitives"),
                .product(name: "Storage Error Primitives", package: "swift-storage-primitives"),
                .product(name: "Storage Initialization Primitives", package: "swift-storage-primitives"),
                .product(name: "Storage Accessor Primitives", package: "swift-storage-primitives"),
                .product(name: "Index Primitives", package: "swift-index-primitives"),
                .product(name: "Memory Address Primitives", package: "swift-memory-primitives"),
                .product(name: "Memory Alignment Primitives", package: "swift-memory-primitives"),
                .product(name: "Memory Contiguous Primitives", package: "swift-memory-primitives"),
                .product(name: "Memory Primitives Standard Library Integration", package: "swift-memory-primitives"),
                .product(name: "Memory Arena Primitives", package: "swift-memory-arena-primitives"),
                .product(name: "Property Primitives", package: "swift-property-primitives"),
                .product(name: "Finite Primitives", package: "swift-finite-primitives"),
            ]
        ),
        .target(
            name: "Storage Arena Primitives Test Support",
            dependencies: [
                "Storage Arena Primitives",
                .product(name: "Storage Primitives Test Support", package: "swift-storage-primitives"),
            ],
            path: "Tests/Support"
        ),
        .testTarget(
            name: "Storage Arena Primitives Tests",
            dependencies: [
                "Storage Arena Primitives",
                "Storage Arena Primitives Test Support",
                .product(name: "Storage Primitives Test Support", package: "swift-storage-primitives"),
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
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("LifetimeDependence"),
    ]

    let package: [SwiftSetting] = [
        .enableExperimentalFeature("RawLayout"),
    ]

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}

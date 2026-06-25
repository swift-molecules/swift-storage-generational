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

/// Family-tier benchmark (arc-bench batch-2). MEASUREMENT DISCIPLINE:
/// `rm -rf .build`, build `-c release`, run the binary directly; never
/// `swift test` (the W1-ratified instrument).
@main
enum Main {
    static func main() {
        print("=== swift-storage-generational-primitives — family-tier benchmark (batch-2) ===")
        print("config: sizes=\(Bench.sizes) samples=\(Bench.samples) warmup=\(Bench.warmup)")
        print("")
        Bench.globalWarmup()
        let results = Bench.arenaCases()
        for result in results {
            print(result.record)
        }
        print("")
        Bench.flushSink()
    }
}

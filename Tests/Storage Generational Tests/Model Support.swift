import Memory_Allocator_Pool
import Store
import Store_Protocol
#if canImport(Darwin)
    import Darwin
#elseif os(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(ucrt)
    import ucrt
#endif

import Cardinal
import Index
import Ordinal
import Ordinal_Standard_Library_Integration
import Tagged

func typedCount<Tag: ~Copyable & ~Escapable>(_ value: Int) -> Tagged<Tag, Cardinal> {
    Tagged(_unchecked: Cardinal(UInt(value)))
}

func typedIndex<Tag: ~Copyable & ~Escapable>(_ value: Int) -> Index<Tag> {
    Tagged(_unchecked: Ordinal(UInt(value)))
}

enum Model {}

extension Model {

    struct Random {
        var state: UInt64

        init(seed: UInt64) { self.state = seed }
    }

    struct Verdict {
        let seed: UInt64
        var transcript: [String] = []
        var findings: [String] = []

        init(seed: UInt64) { self.seed = seed }
    }

    final class Census {
        private(set) var born: [Int] = []
        private(set) var died: [Int] = []

        func mint() -> Int {
            let serial = born.count
            born.append(serial)
            return serial
        }

        func record(death serial: Int) {
            died.append(serial)
        }

        var isExact: Bool { born.sorted() == died.sorted() }
    }

    enum Element {}
}

extension Model.Random {

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

extension Model.Verdict {

    var isClean: Bool { findings.isEmpty }

    mutating func record(_ operation: String) {
        transcript.append(operation)
    }

    mutating func diverged(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        let at = transcript.endIndex - 1
        let operation = at >= 0 ? transcript[at] : "(setup)"
        findings.append(contentsOf: messages.map { "after op #\(at) `\(operation)`: \($0)" })
    }

    var report: String {
        if isClean {
            return "clean — seed 0x\(String(seed, radix: 16)), \(transcript.count) ops"
        }
        return """
            MODEL DIVERGENCE — seed 0x\(String(seed, radix: 16)), \(transcript.count) ops run
            findings:
            \(findings.map { "  - \($0)" }.joined(separator: "\n"))
            transcript (replay by passing this seed):
            \(transcript.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n"))
            """
    }
}

extension Model {

    static func operations(default count: Int) -> Int {
        guard
            let raw = environment("MODEL_SOAK_OPERATIONS"),
            let soak = Int(raw),
            soak > 0
        else {
            return count
        }
        return soak
    }

    static func seeds(default fixed: [UInt64]) -> [UInt64] {
        guard let raw = environment("MODEL_SOAK_SEEDS") else { return fixed }
        let extras = raw.split(separator: ",").compactMap { piece -> UInt64? in
            let cleaned = piece.filter { !$0.isWhitespace }
            if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
                return UInt64(cleaned.dropFirst(2), radix: 16)
            }
            return UInt64(cleaned)
        }
        return fixed + extras
    }

    static func shouldAudit(op index: Int, of operations: Int) -> Bool {
        if operations <= 4_096 { return true }
        return index % 64 == 0 || index == operations - 1
    }

    private static func environment(_ name: String) -> String? {
        #if hasFeature(Embedded)
            return nil
        #else
            guard let pointer = unsafe getenv(name) else { return nil }
            return unsafe String(validatingCString: pointer)
        #endif
    }
}

extension Model.Element {

    struct Tracked: ~Copyable {
        let id: Int
        let group: Int
        let serial: Int
        private let census: Model.Census

        init(id: Int, group: Int = 0, census: Model.Census) {
            self.id = id
            self.group = group
            self.census = census
            self.serial = census.mint()
        }

        deinit {
            census.record(death: serial)
        }
    }
}

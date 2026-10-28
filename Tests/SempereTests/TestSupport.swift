import Foundation
@testable import Sempere

/// Deterministic RNG so property tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension UUID {
    static func random<G: RandomNumberGenerator>(using g: inout G) -> UUID {
        let a = UInt64.random(in: .min ... .max, using: &g), b = UInt64.random(in: .min ... .max, using: &g)
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: v >> (8 * i)) }
        return UUID(uuid: (byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
                           byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)))
    }
}

let devA = DeviceID("aaaaaaaa")!
let devB = DeviceID("bbbbbbbb")!
let devC = DeviceID("cccccccc")!
let testNote = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
let baseMillis: Int64 = 1_759_632_000_000

func wallAt(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

func stroke(_ id: UUID = UUID(), parent: UUID? = nil) -> Stroke {
    Stroke(id: id, ink: Ink(tool: .pen, color: .black, width: 2), points: [StrokePoint(x: 1, y: 2, w: 2, h: 2)],
           parent: parent)
}

/// Hand-cranked log: explicit HLC millis per revision, auto `seq` per device.
struct LogBuilder {
    var seqs: [DeviceID: Int] = [:]

    mutating func nextSeq(_ d: DeviceID) -> Int {
        seqs[d, default: 0] += 1
        return seqs[d, default: 0]
    }

    /// A delta stamped at `baseMillis + t` (counter 0).
    mutating func delta(_ d: DeviceID, _ t: Int64, _ ops: [Op]) -> Revision {
        let ms = baseMillis + t
        return Revision(noteId: testNote, device: d, seq: nextSeq(d), hlc: HLC(millis: ms, counter: 0)!,
                        wall: wallAt(ms), app: "test/0", body: .delta(ops: ops))
    }

    /// A snapshot by `d` at `baseMillis + t` from `revisions`.
    mutating func snapshot(_ d: DeviceID, _ t: Int64, from revisions: [Revision]) throws -> Revision {
        var clock = HybridClock()
        return try SnapshotBuilder.makeSnapshot(from: revisions, device: d, seq: nextSeq(d), clock: &clock,
                                                wall: wallAt(baseMillis + t), app: "test/0")
    }
}

extension NoteState {
    var strokeIds: [[UUID]] { pages.map { $0.strokes.map(\.id) } }
    var allStrokeIds: Set<UUID> { Set(pages.flatMap { $0.strokes.map(\.id) }) }
}

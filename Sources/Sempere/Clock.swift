import Foundation

// MARK: - Hybrid logical clock (docs/format.md §5)

/// A hybrid logical clock value: 13-digit Unix milliseconds followed by a
/// 4-digit counter, both zero-padded, 17 ASCII digits in all.
///
/// Lexicographic order of the string form equals numeric order, so `HLC`
/// compares by `(millis, counter)`.
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Largest representable millisecond value (13 digits).
    public static let maxMillis: Int64 = 9_999_999_999_999
    /// Largest representable counter value (4 digits).
    public static let maxCounter = 9_999
    /// `00000000000000000`, below every real clock reading.
    public static let zero = HLC(validMillis: 0, counter: 0)

    /// Unix milliseconds, 0 through `maxMillis`.
    public let millis: Int64
    /// Tie-breaker within one millisecond, 0 through `maxCounter`.
    public let counter: Int

    /// Returns nil when either part is out of range.
    public init?(millis: Int64, counter: Int) {
        guard (0...HLC.maxMillis).contains(millis), (0...HLC.maxCounter).contains(counter) else { return nil }
        self.millis = millis
        self.counter = counter
    }

    private init(validMillis: Int64, counter: Int) {
        self.millis = validMillis
        self.counter = counter
    }

    /// Parses exactly 17 ASCII digits.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 17, bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        var m: Int64 = 0
        for b in bytes[0..<13] { m = m * 10 + Int64(b - 0x30) }
        var c = 0
        for b in bytes[13..<17] { c = c * 10 + Int(b - 0x30) }
        self.init(validMillis: m, counter: c)
    }

    public var description: String { pad(String(millis), 13) + pad(String(counter), 4) }

    public static func < (l: HLC, r: HLC) -> Bool { (l.millis, l.counter) < (r.millis, r.counter) }
}

extension HLC: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = HLC(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad hlc \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// The local clock state of one device. Never goes backwards: readings are
/// strictly increasing even if the wall clock jumps back.
public struct HybridClock: Hashable, Sendable {
    /// Milliseconds of the last issued or observed reading.
    public private(set) var millis: Int64
    /// Counter of the last issued or observed reading.
    public private(set) var counter: Int

    public init(millis: Int64 = 0, counter: Int = 0) {
        self.millis = min(max(millis, 0), HLC.maxMillis)
        self.counter = min(max(counter, 0), HLC.maxCounter)
    }

    /// Resumes from a previously issued reading.
    public init(last: HLC) { self.init(millis: last.millis, counter: last.counter) }

    /// The last issued or observed reading.
    public var current: HLC { HLC(millis: millis, counter: counter) ?? .zero }

    /// Issues a reading for a local event (writing a revision).
    public mutating func tick(wall: Date) -> HLC {
        let w = Self.wallMillis(wall)
        if w > millis {
            millis = w
            counter = 0
        } else {
            bump(counter + 1)
        }
        return current
    }

    /// How far ahead of the local wall clock a remote reading may be and
    /// still be adopted by `observe` (format.md §5): 24 hours.
    public static let maxAdoptedDrift: Int64 = 24 * 60 * 60 * 1000

    /// Merges a reading seen on another device's revision, so later local
    /// readings sort after it. A reading more than `maxAdoptedDrift` ahead of
    /// `wall` is not adopted: the clock is left as is and its current reading
    /// returned. (Merging still uses that revision's stamp as written.)
    @discardableResult
    public mutating func observe(_ remote: HLC, wall: Date) -> HLC {
        let w = Self.wallMillis(wall)
        guard remote.millis <= w + Self.maxAdoptedDrift else { return current }
        let m = max(w, millis, remote.millis)
        if m == millis && m == remote.millis {
            bump(max(counter, remote.counter) + 1)
        } else if m == millis {
            bump(counter + 1)
        } else if m == remote.millis {
            millis = m
            bump(remote.counter + 1)
        } else {
            millis = m
            counter = 0
        }
        return current
    }

    /// Counter overflow borrows a millisecond rather than failing; the clock
    /// stays monotonic and runs at most marginally ahead of the wall. At the
    /// very top of the range it saturates (repeats the maximum reading) rather
    /// than wrapping below it.
    private mutating func bump(_ next: Int) {
        if next <= HLC.maxCounter {
            counter = next
        } else if millis < HLC.maxMillis {
            millis += 1
            counter = 0
        } else {
            counter = HLC.maxCounter
        }
    }

    static func wallMillis(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard ms.isFinite, ms > 0 else { return 0 }
        return ms >= Double(HLC.maxMillis) ? HLC.maxMillis : Int64(ms)
    }
}

// MARK: - Device identity

/// 8 lowercase hex characters, random per app installation (format.md §5).
public struct DeviceID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// `00000000`; used only by `Stamp.zero`.
    public static let zero = DeviceID(valid: "00000000")

    /// Validates 8 lowercase hex characters.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 8,
              bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        rawValue = string
    }

    private init(valid: String) { rawValue = valid }

    /// A fresh random id from the system generator.
    public static func random() -> DeviceID {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> DeviceID {
        DeviceID(valid: pad(String(UInt32.random(in: .min ... .max, using: &generator), radix: 16), 8))
    }

    public var description: String { rawValue }

    public static func < (l: DeviceID, r: DeviceID) -> Bool { l.rawValue < r.rawValue }
}

extension DeviceID: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = DeviceID(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad device id \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - LWW stamp

/// The last-writer-wins timestamp of an op: its revision's `(hlc, device)`.
/// String form `"<hlc>-<device>"` (format.md §5.4 `clocks`).
public struct Stamp: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Clock reading of the revision holding the op.
    public var hlc: HLC
    /// Device that wrote that revision; breaks ties between equal readings.
    public var device: DeviceID

    /// Below every real stamp; the stamp of a register nobody has set.
    public static let zero = Stamp(hlc: .zero, device: .zero)

    public init(hlc: HLC, device: DeviceID) {
        self.hlc = hlc
        self.device = device
    }

    /// Parses `"<17 digits>-<8 hex>"`.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = HLC(String(parts[0])), let d = DeviceID(String(parts[1])) else { return nil }
        self.init(hlc: h, device: d)
    }

    public var description: String { "\(hlc)-\(device)" }

    public static func < (l: Stamp, r: Stamp) -> Bool { (l.hlc, l.device) < (r.hlc, r.device) }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}

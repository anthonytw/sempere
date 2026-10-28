import Foundation

/// A strict reader for binary property lists (`bplist00`), the format of
/// every plist inside an importable package.
///
/// The importer does not use `PropertyListSerialization` for untrusted
/// packages: swift-corelibs-foundation's binary plist bridging crashes
/// (SIGSEGV) on some hostile inputs (a set nested in containers). This
/// reader checks every offset, count and reference against the file before
/// using it, rejects reference cycles, limits nesting to `maxDepth`, and
/// parses each object once (shared references reuse the parsed value, so a
/// file that references one object many times costs no more than its size).
package enum BinaryPlist {
    /// Deepest container nesting accepted. NSKeyedArchiver output is flat
    /// (objects refer to each other by UID), so real files stay far below it.
    package static let maxDepth = 64

    package static let magic = Array("bplist00".utf8)

    package static func isBinaryPlist(_ data: Data) -> Bool { data.starts(with: magic) }

    /// Parses `data`, returning the top object.
    ///
    /// - Throws: `ImportError.archive` for anything malformed.
    package static func parse(_ data: Data) throws -> PlistValue {
        var reader = try Reader([UInt8](data))
        return try reader.object(reader.top, depth: 0)
    }

    private struct Reader {
        let bytes: [UInt8]
        let offsetSize: Int
        let refSize: Int
        let count: Int
        let top: Int
        let tableStart: Int
        /// Objects parsed so far (shared references reuse them).
        var done: [Int: PlistValue] = [:]
        /// Objects on the current path (a reference to one is a cycle).
        var open = Set<Int>()

        init(_ bytes: [UInt8]) throws {
            self.bytes = bytes
            guard bytes.count >= magic.count + 32, bytes.starts(with: magic) else { throw Self.bad("not a binary plist") }
            let t = bytes.count - 32
            offsetSize = Int(bytes[t + 6])
            refSize = Int(bytes[t + 7])
            guard (1...8).contains(offsetSize), (1...8).contains(refSize) else { throw Self.bad("bad trailer sizes") }
            let n = Self.be(bytes, t + 8, 8), topRef = Self.be(bytes, t + 16, 8), table = Self.be(bytes, t + 24, 8)
            // Every object takes at least one byte between the header and the offset table.
            guard n >= 1, n <= UInt64(t), topRef < n, table >= UInt64(magic.count), table <= UInt64(t),
                  n <= (UInt64(t) - table) / UInt64(offsetSize) else { throw Self.bad("bad trailer") }
            count = Int(n); top = Int(topRef); tableStart = Int(table)
        }

        static func bad(_ why: String) -> ImportError { ImportError.archive("binary plist: \(why)") }

        /// Big-endian unsigned integer of `width` (1...8) bytes at `at`; the caller checks bounds.
        static func be(_ b: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<width { v = v << 8 | UInt64(b[at + i]) }
            return v
        }

        /// Reads `width` bytes at `at`, which must lie inside the object area.
        func uint(_ at: Int, _ width: Int) throws -> UInt64 {
            guard at >= magic.count, width <= tableStart, at <= tableStart - width else { throw Self.bad("read past the objects") }
            return Self.be(bytes, at, width)
        }

        /// The object reference stored at `at` (-1 when it cannot be an index).
        func reference(at: Int) throws -> Int { Int(exactly: try uint(at, refSize)) ?? -1 }

        func offset(of ref: Int) throws -> Int {
            guard ref >= 0, ref < count else { throw Self.bad("reference \(ref) out of range") }
            let o = Self.be(bytes, tableStart + ref * offsetSize, offsetSize)
            guard o >= UInt64(magic.count), o < UInt64(tableStart) else { throw Self.bad("object offset out of range") }
            return Int(o)
        }

        /// The element count after a marker byte at `at` (inline, or an int
        /// object that follows), and where the payload starts.
        func length(_ marker: UInt8, at: Int) throws -> (count: Int, start: Int) {
            let low = Int(marker & 0x0F)
            guard low == 0x0F else { return (low, at + 1) }
            let intMarker = try uint(at + 1, 1)
            guard intMarker & 0xF0 == 0x10, intMarker & 0x0F <= 3 else { throw Self.bad("bad length") }
            let width = 1 << Int(intMarker & 0x0F)
            let n = try uint(at + 2, width)
            guard n <= UInt64(tableStart) else { throw Self.bad("length beyond the file") }
            return (Int(n), at + 2 + width)
        }

        /// `n` items of `size` bytes from `start` lie inside the object area.
        func check(_ start: Int, _ n: Int, _ size: Int) throws {
            guard n >= 0, start <= tableStart, n <= (tableStart - start) / size else {
                throw Self.bad("container or string runs past the objects")
            }
        }

        mutating func object(_ ref: Int, depth: Int) throws -> PlistValue {
            if let v = done[ref] { return v }
            guard depth < BinaryPlist.maxDepth else { throw Self.bad("nested more than \(BinaryPlist.maxDepth) deep") }
            guard open.insert(ref).inserted else { throw Self.bad("reference cycle") }
            defer { open.remove(ref) }
            let at = try offset(of: ref)
            let marker = bytes[at]
            let v: PlistValue
            switch marker >> 4 {
            case 0x0:
                switch marker {
                case 0x08: v = .bool(false)
                case 0x09: v = .bool(true)
                default: throw Self.bad("unsupported marker \(marker)")
                }
            case 0x1:
                let w = Int(marker & 0x0F)
                guard w <= 4 else { throw Self.bad("bad integer width") }
                let width = 1 << w
                if width == 16 {
                    // 128-bit: accept only values that fit in 64 bits.
                    let high = try uint(at + 1, 8), low = try uint(at + 9, 8)
                    let value = Int64(bitPattern: low)
                    guard high == (value < 0 ? UInt64.max : 0) else { throw Self.bad("integer beyond 64 bits") }
                    v = .int(value)
                } else {
                    let raw = try uint(at + 1, width)
                    // 1, 2 and 4-byte integers are unsigned; 8-byte ones signed.
                    v = .int(width == 8 ? Int64(bitPattern: raw) : Int64(raw))
                }
            case 0x2:
                switch marker & 0x0F {
                case 2: v = .real(Double(Float(bitPattern: UInt32(try uint(at + 1, 4)))))
                case 3: v = .real(Double(bitPattern: try uint(at + 1, 8)))
                default: throw Self.bad("bad real width")
                }
            case 0x3:
                guard marker == 0x33 else { throw Self.bad("bad date") }
                v = .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: try uint(at + 1, 8))))
            case 0x4:
                let (n, start) = try length(marker, at: at)
                try check(start, n, 1)
                v = .data(Data(bytes[start..<(start + n)]))
            case 0x5, 0x7:
                // ASCII (0x5) and UTF-8 (0x7) strings; invalid bytes are replaced.
                let (n, start) = try length(marker, at: at)
                try check(start, n, 1)
                v = .string(String(decoding: bytes[start..<(start + n)], as: UTF8.self))
            case 0x6:
                let (n, start) = try length(marker, at: at)
                try check(start, n, 2)
                var units = [UInt16]()
                units.reserveCapacity(n)
                for i in 0..<n { units.append(UInt16(bytes[start + 2 * i]) << 8 | UInt16(bytes[start + 2 * i + 1])) }
                v = .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                let raw = try uint(at + 1, Int(marker & 0x0F) + 1)
                guard let uid = Int(exactly: raw) else { throw Self.bad("UID out of range") }
                v = .uid(uid)
            case 0xA, 0xB, 0xC:
                // Arrays, ordered sets and sets all become arrays.
                let (n, start) = try length(marker, at: at)
                try check(start, n, refSize)
                var items: [PlistValue] = []
                items.reserveCapacity(n)
                for i in 0..<n {
                    items.append(try object(reference(at: start + i * refSize), depth: depth + 1))
                }
                v = .array(items)
            case 0xD:
                let (n, start) = try length(marker, at: at)
                try check(start, n, 2 * refSize)
                var dict: [String: PlistValue] = [:]
                for i in 0..<n {
                    let key = try object(reference(at: start + i * refSize), depth: depth + 1)
                    guard case .string(let k) = key else { throw Self.bad("dictionary key is not a string") }
                    dict[k] = try object(reference(at: start + (n + i) * refSize), depth: depth + 1)
                }
                v = .dict(dict)
            default:
                throw Self.bad("unsupported marker \(marker)")
            }
            done[ref] = v
            return v
        }
    }
}

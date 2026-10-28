// Test helpers shared by SempereImportTests and SempereNotabilityTests: a binary plist writer with UIDs, an
// NSKeyedArchiver builder and a zip writer (stored or deflated, zip64). Nothing here knows an app's format.
import CZlib
import Foundation
import XCTest

// MARK: - Binary property list writer (with UIDs)

/// A property-list value for `BPlist.encode`, including NSKeyedArchiver UIDs
/// (which `PropertyListSerialization` cannot write).
public indirect enum BValue {
    case string(String)
    case int(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([BValue])
    case dict([(String, BValue)])
    case uid(Int)
}

/// Minimal `bplist00` writer: no object sharing, 4-byte offsets, 2- or 4-byte refs.
public enum BPlist {
    public static func encode(_ root: BValue) -> Data {
        var objects: [Data] = []
        let refSize = 4
        func ref(_ i: Int) -> Data { var b = UInt32(i).bigEndian; return Data(bytes: &b, count: 4) }
        func header(_ marker: UInt8, _ count: Int) -> Data {
            if count < 15 { return Data([marker | UInt8(count)]) }
            var d = Data([marker | 0x0F, 0x13])
            var n = UInt64(count).bigEndian
            d.append(Data(bytes: &n, count: 8))
            return d
        }
        @discardableResult
        func add(_ v: BValue) -> Int {
            let index = objects.count
            objects.append(Data())
            var d = Data()
            switch v {
            case .bool(let b): d = Data([b ? 0x09 : 0x08])
            case .int(let i):
                d = Data([0x13]); var n = UInt64(bitPattern: i).bigEndian; d.append(Data(bytes: &n, count: 8))
            case .real(let x):
                d = Data([0x23]); var n = x.bitPattern.bigEndian; d.append(Data(bytes: &n, count: 8))
            case .date(let t):
                d = Data([0x33]); var n = t.timeIntervalSinceReferenceDate.bitPattern.bigEndian
                d.append(Data(bytes: &n, count: 8))
            case .data(let bytes): d = header(0x40, bytes.count); d.append(bytes)
            case .string(let s):
                if s.utf8.allSatisfy({ $0 < 0x80 }) {
                    d = header(0x50, s.utf8.count); d.append(contentsOf: Array(s.utf8))
                } else {
                    let units = Array(s.utf16)
                    d = header(0x60, units.count)
                    for u in units { d.append(contentsOf: [UInt8(u >> 8), UInt8(u & 0xFF)]) }
                }
            case .uid(let u):
                d = Data([0x83]); var n = UInt32(u).bigEndian; d.append(Data(bytes: &n, count: 4))
            case .array(let items):
                let refs = items.map { add($0) }
                d = header(0xA0, items.count)
                for r in refs { d.append(ref(r)) }
            case .dict(let pairs):
                let keys = pairs.map { add(.string($0.0)) }
                let vals = pairs.map { add($0.1) }
                d = header(0xD0, pairs.count)
                for r in keys + vals { d.append(ref(r)) }
            }
            objects[index] = d
            return index
        }
        add(root)
        var out = Data("bplist00".utf8)
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out.append(o) }
        let tableOffset = out.count
        for o in offsets { var n = UInt32(o).bigEndian; out.append(Data(bytes: &n, count: 4)) }
        out.append(Data(repeating: 0, count: 6))
        out.append(contentsOf: [4, UInt8(refSize)])
        for v in [UInt64(objects.count), 0, UInt64(tableOffset)] { var n = v.bigEndian; out.append(Data(bytes: &n, count: 8)) }
        return out
    }
}

/// Builds an NSKeyedArchiver archive by hand.
public struct KeyedArchiveBuilder {
    public var objects: [BValue] = [.string("$null")]
    public var classes: [String: Int] = [:]

    public init() {}

    public mutating func add(_ v: BValue) -> BValue {
        objects.append(v)
        return .uid(objects.count - 1)
    }

    public mutating func cls(_ name: String) -> BValue {
        if let i = classes[name] { return .uid(i) }
        objects.append(.dict([("$classname", .string(name)), ("$classes", .array([.string(name), .string("NSObject")]))]))
        classes[name] = objects.count - 1
        return .uid(objects.count - 1)
    }

    public mutating func object(_ className: String, _ fields: [(String, BValue)]) -> BValue {
        let c = cls(className)
        return add(.dict(fields + [("$class", c)]))
    }

    public mutating func string(_ s: String) -> BValue { add(.string(s)) }
    public mutating func data(_ d: Data) -> BValue { add(.data(d)) }
    public mutating func date(_ d: Date) -> BValue { object("NSDate", [("NS.time", .real(d.timeIntervalSinceReferenceDate))]) }
    public mutating func array(_ items: [BValue]) -> BValue { object("NSArray", [("NS.objects", .array(items))]) }
    public mutating func dict(_ pairs: [(String, BValue)]) -> BValue {
        let keys = pairs.map { string($0.0) }
        return object("NSMutableDictionary", [("NS.keys", .array(keys)), ("NS.objects", .array(pairs.map(\.1)))])
    }

    public func archive(top: [(String, BValue)]) -> Data {
        BPlist.encode(.dict([("$version", .int(100000)), ("$archiver", .string("NSKeyedArchiver")),
                             ("$top", .dict(top)), ("$objects", .array(objects))]))
    }
}

// MARK: - Zip writer (named TestZip: SempereRender has a ZipWriter)

/// Minimal zip writer for tests: stored or raw-deflate entries, optional
/// zip64 records (extra fields saturated plus a zip64 end record).
public enum TestZip {
    public struct File {
        public var path: String; public var data: Data; public var deflate = true
        /// MS-DOS modification time and date fields (0 = unset).
        public var dosTime: UInt16 = 0, dosDate: UInt16 = 0

        public init(path: String, data: Data, deflate: Bool = true, dosTime: UInt16 = 0, dosDate: UInt16 = 0) {
            self.path = path; self.data = data; self.deflate = deflate; self.dosTime = dosTime; self.dosDate = dosDate
        }
    }

    /// MS-DOS date and time fields for a UTC calendar time.
    public static func dos(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> (UInt16, UInt16) {
        (UInt16(h << 11 | mi << 5 | s / 2), UInt16((y - 1980) << 9 | mo << 5 | d))
    }

    public static func write(_ files: [File], zip64: Bool = false) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
        func le64(_ v: UInt64) -> Data { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }
        for f in files {
            let crc = TestZip.crcOf(f.data)
            let body = f.deflate ? rawDeflate(f.data) : f.data
            let name = Data(f.path.utf8)
            let offset = out.count
            let method = f.deflate ? 8 : 0
            var extra = Data()
            if zip64 { extra = le16(1) + le16(24) + le64(UInt64(f.data.count)) + le64(UInt64(body.count)) + le64(UInt64(offset)) }
            out += le32(0x0403_4B50) + le16(zip64 ? 45 : 20) + le16(0x0800) + le16(method)
            out += le16(Int(f.dosTime)) + le16(Int(f.dosDate))
            out += le32(crc) + le32(zip64 ? 0xFFFF_FFFF : UInt32(body.count)) + le32(zip64 ? 0xFFFF_FFFF : UInt32(f.data.count))
            out += le16(name.count) + le16(zip64 ? 20 : 0) + name
            if zip64 { out += le16(1) + le16(16) + le64(UInt64(f.data.count)) + le64(UInt64(body.count)) }
            out += body
            central += le32(0x0201_4B50) + le16(zip64 ? 45 : 20) + le16(zip64 ? 45 : 20) + le16(0x0800) + le16(method)
            central += le16(Int(f.dosTime)) + le16(Int(f.dosDate)) + le32(crc)
            central += le32(zip64 ? 0xFFFF_FFFF : UInt32(body.count)) + le32(zip64 ? 0xFFFF_FFFF : UInt32(f.data.count))
            central += le16(name.count) + le16(extra.count) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(zip64 ? 0xFFFF_FFFF : UInt32(offset)) + name + extra
        }
        let cdOffset = out.count
        out += central
        if zip64 {
            let recOffset = out.count
            out += le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            out += le64(UInt64(files.count)) + le64(UInt64(files.count)) + le64(UInt64(central.count)) + le64(UInt64(cdOffset))
            out += le32(0x0706_4B50) + le32(0) + le64(UInt64(recOffset)) + le32(1)
            out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF)
            out += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0)
        } else {
            out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
            out += le32(UInt32(central.count)) + le32(UInt32(cdOffset)) + le16(0)
        }
        return out
    }

    static func crcOf(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    public static func rawDeflate(_ data: Data) -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        let produced: Int = input.withUnsafeMutableBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { outp in
                stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
                stream.next_out = outp.baseAddress; stream.avail_out = uInt(outp.count)
                _ = deflate(&stream, Z_FINISH)
                return outp.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<produced])
    }
}


import CZlib
import Foundation
import Sempere

/// A read-only zip archive (PKWARE APPNOTE): central directory, stored and
/// deflated entries, and the zip64 extensions, so archives above 4 GiB or
/// with more than 65535 entries open too. No writing, no encryption, no
/// multi-disk archives.
///
/// An archive opened from a file reads entries on demand by seeking, so a
/// multi-gigabyte backup is never loaded whole.
public final class ZipArchive {
    /// One central-directory record.
    public struct Entry: Hashable, Sendable {
        /// Path inside the archive, `/`-separated. Directories end in `/`.
        public var path: String
        /// 0 stored, 8 deflate.
        public var method: UInt16
        /// CRC-32 of the uncompressed bytes.
        public var crc32: UInt32
        /// Size of the stored (possibly compressed) bytes.
        public var compressedSize: UInt64
        /// Size after decompression.
        public var uncompressedSize: UInt64
        /// Offset of the entry's local header from the start of the archive.
        public var localHeaderOffset: UInt64
        /// General-purpose flags (bit 0: encrypted).
        var flags: UInt16
        /// Last modification time: the extended-timestamp extra field (0x5455,
        /// UTC) when present, else the MS-DOS date and time, which carry no
        /// time zone and are read as UTC. Nil when the DOS fields are invalid.
        /// Only good for ordering entries of one archive.
        public var modified: Date?

        /// True for directory entries (path ends in `/`).
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    private enum Source {
        case data(Data)
        case file(FileHandle)
    }

    private let source: Source
    private let size: UInt64
    /// Every entry, in central-directory order. Paths are unique and the
    /// entries' stored bytes do not overlap (`readDirectory`).
    public let entries: [Entry]

    /// Default ceiling on one entry's uncompressed size (1 GiB).
    public static let defaultMaxEntrySize: UInt64 = 1 << 30

    /// Most uncompressed bytes all `read` calls on one archive may produce
    /// together, repeated and failed reads included: a few MiB of archive
    /// must not cost terabytes of inflation however often its entries are
    /// asked for (security review S7, S18). `readBudget(forArchiveOf:)`.
    public let readBudget: UInt64
    private var spent: UInt64 = 0
    private let lock = NSLock()

    /// The default `readBudget`: 32 bytes per byte of the archive, and at
    /// least 2 GiB (two of the largest entries).
    public static func readBudget(forArchiveOf size: UInt64) -> UInt64 {
        let (scaled, overflow) = size.multipliedReportingOverflow(by: 32)
        return max(2 << 30, overflow ? .max : scaled)
    }

    /// Opens an archive held in memory.
    ///
    /// - Throws: `ImportError.zip` when no valid central directory is found.
    public init(data: Data, readBudget: UInt64? = nil) throws {
        source = .data(data)
        size = UInt64(data.count)
        self.readBudget = readBudget ?? Self.readBudget(forArchiveOf: UInt64(data.count))
        entries = try Self.readDirectory(size: size) { off, count in try Self.slice(data, off, count) }
    }

    /// Opens an archive file for reading; entries are read lazily.
    ///
    /// - Throws: `ImportError.io` if the file cannot be opened,
    ///   `ImportError.zip` when no valid central directory is found.
    public init(url: URL, readBudget: UInt64? = nil) throws {
        let handle: FileHandle
        // Not FileHandle(forReadingFrom:): opening a FIFO named `*.note` would block forever.
        do { handle = try BoundedRead.openRegularFile(url) } catch {
            throw ImportError.io("cannot open \(url.path): \(error.localizedDescription)")
        }
        let end: UInt64
        do { end = try handle.seekToEnd() } catch {
            throw ImportError.io("cannot size \(url.path): \(error.localizedDescription)")
        }
        source = .file(handle)
        size = end
        self.readBudget = readBudget ?? Self.readBudget(forArchiveOf: end)
        entries = try Self.readDirectory(size: end) { off, count in try Self.read(handle, off, count) }
    }

    deinit {
        if case .file(let h) = source { try? h.close() }
    }

    /// The entry at `path`, if any.
    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    /// The uncompressed bytes of `entry`, CRC-checked.
    ///
    /// - Throws: `ImportError.zip` for an encrypted entry, an unsupported
    ///   method, corrupt deflate data, a size or CRC mismatch, an entry
    ///   larger than `maxSize`, stored bytes that cannot be what the entry
    ///   claims (a stored entry whose two sizes differ, a deflated one larger
    ///   than deflate can make it), or once `readBudget` is spent.
    public func read(_ entry: Entry, maxSize: UInt64 = ZipArchive.defaultMaxEntrySize) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ImportError.zip("\(entry.path): encrypted entries are not supported") }
        guard entry.uncompressedSize <= maxSize else {
            throw ImportError.zip("\(entry.path): \(entry.uncompressedSize) bytes exceeds the \(maxSize)-byte limit")
        }
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ImportError.zip("\(entry.path): stored entry of \(entry.compressedSize) bytes claims \(entry.uncompressedSize)")
            }
        case 8:
            // Deflate's worst case is stored blocks: 5 bytes per 64 KiB.
            let u = entry.uncompressedSize
            guard entry.compressedSize <= u + u / 1000 + 64 else {
                throw ImportError.zip("\(entry.path): \(entry.compressedSize) deflated bytes for \(u)")
            }
        default: break
        }
        // Charged before anything is read or inflated, failures included.
        try charge(entry)
        let header = try bytes(entry.localHeaderOffset, 30)
        guard header.u32(0) == 0x0403_4B50 else { throw ImportError.zip("\(entry.path): bad local header signature") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        let stored = try bytes(dataStart, entry.compressedSize)
        let out: Data
        switch entry.method {
        case 0: out = stored
        case 8:
            do { out = try Gzip.inflateRaw(stored, maxOutput: Int(entry.uncompressedSize)) } catch {
                throw ImportError.zip("\(entry.path): corrupt deflate data (\(error))")
            }
        default: throw ImportError.zip("\(entry.path): compression method \(entry.method) is not supported")
        }
        guard UInt64(out.count) == entry.uncompressedSize else {
            throw ImportError.zip("\(entry.path): size \(out.count), directory says \(entry.uncompressedSize)")
        }
        guard Self.crc32(out) == entry.crc32 else { throw ImportError.zip("\(entry.path): CRC mismatch") }
        return out
    }

    /// Takes `entry`'s uncompressed size from `readBudget`.
    private func charge(_ entry: Entry) throws {
        lock.lock()
        defer { lock.unlock() }
        let (total, overflow) = spent.addingReportingOverflow(entry.uncompressedSize)
        guard !overflow, total <= readBudget else {
            throw ImportError.zip("\(entry.path): over the \(readBudget >> 20) MiB read from this archive in all")
        }
        spent = total
    }

    // MARK: - Directory

    private func bytes(_ offset: UInt64, _ count: UInt64) throws -> Data {
        switch source {
        case .data(let d): return try Self.slice(d, offset, count)
        case .file(let h): return try Self.read(h, offset, count)
        }
    }

    private static func slice(_ d: Data, _ offset: UInt64, _ count: UInt64) throws -> Data {
        guard offset <= UInt64(d.count), count <= UInt64(d.count) - offset else {
            throw ImportError.zip("read past end of archive")
        }
        let start = d.startIndex + Int(offset)
        return Data(d[start..<(start + Int(count))])
    }

    private static func read(_ h: FileHandle, _ offset: UInt64, _ count: UInt64) throws -> Data {
        guard count <= UInt64(Int.max) else { throw ImportError.zip("entry too large") }
        do {
            try h.seek(toOffset: offset)
            let d = try h.read(upToCount: Int(count)) ?? Data()
            guard d.count == Int(count) else { throw ImportError.zip("read past end of archive") }
            return d
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.io("read failed: \(error.localizedDescription)")
        }
    }

    private static func readDirectory(size: UInt64, read: (UInt64, UInt64) throws -> Data) throws -> [Entry] {
        // End of central directory: 22 bytes plus a comment of up to 65535.
        guard size >= 22 else { throw ImportError.zip("too short to be a zip archive") }
        let tailLength = min(size, 22 + 65535)
        let tailStart = size - tailLength
        let tail = try read(tailStart, tailLength)
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x0605_4B50, i + 22 + Int(tail.u16(i + 20)) <= tail.count { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw ImportError.zip("no end-of-central-directory record") }
        guard tail.u16(e + 4) == 0, tail.u16(e + 6) == 0 else { throw ImportError.zip("multi-disk archives are not supported") }
        var count = UInt64(tail.u16(e + 10))
        var cdSize = UInt64(tail.u32(e + 12))
        var cdOffset = UInt64(tail.u32(e + 16))

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // zip64 end-of-central-directory locator sits just before the EOCD.
            let locatorPos = tailStart + UInt64(e)
            guard locatorPos >= 20 else { throw ImportError.zip("missing zip64 locator") }
            let loc = try read(locatorPos - 20, 20)
            guard loc.u32(0) == 0x0706_4B50 else { throw ImportError.zip("missing zip64 locator") }
            let recOffset = loc.u64(8)
            let rec = try read(recOffset, 56)
            guard rec.u32(0) == 0x0606_4B50 else { throw ImportError.zip("bad zip64 end-of-central-directory record") }
            count = rec.u64(32)
            cdSize = rec.u64(40)
            cdOffset = rec.u64(48)
        }
        guard cdOffset <= size, cdSize <= size - cdOffset else { throw ImportError.zip("central directory out of range") }
        // Each record is at least 46 bytes, so `count` is bounded by the directory size.
        guard count <= cdSize / 46 + 1 else { throw ImportError.zip("entry count exceeds directory size") }
        let cd = try read(cdOffset, cdSize)

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var seen = Set<String>()
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else {
                throw ImportError.zip("bad central directory record at \(p)")
            }
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var modified = dosDate(time: cd.u16(p + 12), date: cd.u16(p + 14))
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            var offset = UInt64(cd.u32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else {
                throw ImportError.zip("central directory record overruns the directory")
            }
            let nameBytes = cd.subdata(in: (cd.startIndex + nameStart)..<(cd.startIndex + nameStart + nameLen))
            let path = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)

            // zip64 extended information (0x0001): only the fields saturated above, in order.
            var x = nameStart + nameLen
            let extraEnd = x + extraLen
            while x + 4 <= extraEnd {
                let id = cd.u16(x), len = Int(cd.u16(x + 2))
                var f = x + 4
                let fieldEnd = min(f + len, extraEnd)
                if id == 0x0001 {
                    if usize == 0xFFFF_FFFF, f + 8 <= fieldEnd { usize = cd.u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= fieldEnd { csize = cd.u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= fieldEnd { offset = cd.u64(f); f += 8 }
                } else if id == 0x5455, f + 5 <= fieldEnd, cd[cd.startIndex + f] & 1 != 0 {
                    // Extended timestamp: flags byte, then the modification time (Unix seconds).
                    modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: cd.u32(f + 1))))
                }
                x += 4 + len
            }
            // Two entries of one name: which one a reader gets is ambiguous,
            // and the copies multiply the work of reading "every" entry.
            guard seen.insert(path).inserted else { throw ImportError.zip("duplicate entry \(path)") }
            entries.append(Entry(path: path, method: method, crc32: crc, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: offset, flags: flags,
                                 modified: modified))
            p = extraEnd + commentLen
        }
        try checkDisjoint(entries)
        return entries
    }

    /// Refuses entries whose local header and stored bytes overlap another's
    /// (at least 30 header bytes plus `compressedSize` each, in offset order):
    /// many records pointing at one deflate bomb would each inflate it.
    static func checkDisjoint(_ entries: [Entry]) throws {
        let sorted = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let (withHeader, o1) = a.localHeaderOffset.addingReportingOverflow(30)
            let (end, o2) = withHeader.addingReportingOverflow(a.compressedSize)
            guard !o1, !o2, end <= b.localHeaderOffset else {
                throw ImportError.zip("entries \(a.path) and \(b.path) overlap")
            }
        }
    }

    /// An MS-DOS date and time (2-second resolution, no time zone) as UTC.
    static func dosDate(time: UInt16, date: UInt16) -> Date? {
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9)
        c.month = Int(date >> 5 & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int(time >> 5 & 0x3F)
        c.second = Int(time & 0x1F) * 2
        guard let m = c.month, (1...12).contains(m), let d = c.day, (1...31).contains(d),
              let h = c.hour, h < 24, let mi = c.minute, mi < 60, let s = c.second, s < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.date(from: c)
    }

    // MARK: - zlib

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            var crc: uLong = CZlib.crc32(0, nil, 0)
            var base = raw.bindMemory(to: Bytef.self).baseAddress
            var left = raw.count
            while left > 0, let b = base {
                let n = min(left, Int(UInt32.max >> 1))
                crc = CZlib.crc32(crc, b, uInt(n))
                base = b + n
                left -= n
            }
            return UInt32(truncatingIfNeeded: crc)
        }
    }

}

// MARK: - Little-endian reads

extension Data {
    package func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    package func u32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    package func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}

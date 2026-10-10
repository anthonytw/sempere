import CZlib
import Foundation

/// Why a zip archive could not be written.
public enum ZipWriterError: Error, Equatable, CustomStringConvertible, Sendable {
    /// An entry name that is empty, absolute, has `.`/`..` segments or is too long.
    case badName(String)
    /// The same name twice in one archive.
    case duplicateName(String)
    /// The archive or a source file could not be read or written.
    case io(path: String, reason: String)
    /// `finish` was called already.
    case finished

    public var description: String {
        switch self {
        case .badName(let n): return "cannot store \(n) in a zip archive"
        case .duplicateName(let n): return "\(n) is already in the zip archive"
        case .io(let path, let reason): return "cannot write \(path): \(reason)"
        case .finished: return "the zip archive is already finished"
        }
    }
}

/// Writes a zip archive to a file, one entry at a time, streamed from files
/// on disk: no entry is ever held in memory whole, so an archive of a 1.4 GB
/// vault takes no more memory than one of a single note.
///
/// Entries are stored (method 0): exports are PDFs and PNGs, which are
/// compressed already. Names are UTF-8 (general purpose flag bit 11). Sizes
/// and offsets beyond 4 GiB, and more than 65 535 entries, use the zip64
/// extensions (APPNOTE 6.3.x §4.5.3), which every current unzipper reads
/// (Finder's Archive Utility, Files on iPadOS, Info-ZIP `unzip`, 7-Zip).
///
/// Not thread-safe: use it from one task at a time.
public final class ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt64
        var offset: UInt64
        var zip64: Bool
    }

    /// Where the archive is written.
    public let url: URL
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var names = Set<String>()
    private var offset: UInt64 = 0
    private var done = false
    /// Sizes and offsets at or above this use zip64 fields (tests lower it).
    let zip64Threshold: UInt64
    /// Entry counts above this use the zip64 end records (tests lower it).
    let zip64EntryThreshold: Int
    /// The DOS date and time stamped on every entry.
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// Bytes read from a source file at a time.
    static let chunk = 1 << 20

    /// Creates (or truncates) the archive at `url`.
    ///
    /// - Parameter date: the modification time stamped on the entries.
    /// - Throws: `ZipWriterError.io` when the file cannot be created.
    public convenience init(url: URL, date: Date = Date()) throws {
        try self.init(url: url, date: date, zip64Threshold: 0xFFFF_FFFF, zip64EntryThreshold: 0xFFFF)
    }

    init(url: URL, date: Date, zip64Threshold: UInt64, zip64EntryThreshold: Int) throws {
        self.url = url
        self.zip64Threshold = zip64Threshold
        self.zip64EntryThreshold = zip64EntryThreshold
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil),
              let h = FileHandle(forWritingAtPath: url.path) else {
            throw ZipWriterError.io(path: url.path, reason: "cannot create the file")
        }
        handle = h
        (dosTime, dosDate) = Self.dos(date)
    }

    deinit { try? handle.close() }

    /// Number of entries added so far.
    public var count: Int { entries.count }

    /// True when `name` is a relative path a zip entry may carry: `/`
    /// separated, no empty, `.` or `..` segment, no backslash or control
    /// character, at most 65 535 bytes.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 0xFFFF, !name.hasPrefix("/") else { return false }
        if name.unicodeScalars.contains(where: { $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    /// Appends the file at `source` as entry `name`, reading it twice in
    /// chunks (CRC first, then the bytes), never whole.
    ///
    /// - Throws: `ZipWriterError`; after an `.io` error the archive is unusable.
    public func add(name: String, contentsOf source: URL) throws {
        guard !done else { throw ZipWriterError.finished }
        guard Self.isValidName(name) else { throw ZipWriterError.badName(name) }
        // Case-insensitive file systems would merge two such entries on extraction.
        let key = name.precomposedStringWithCanonicalMapping.lowercased()
        guard !names.contains(key) else { throw ZipWriterError.duplicateName(name) }
        guard let input = FileHandle(forReadingAtPath: source.path) else {
            throw ZipWriterError.io(path: source.path, reason: "cannot open the file")
        }
        defer { try? input.close() }
        // Pass 1: size and CRC-32.
        var crc: UInt32 = 0
        var size: UInt64 = 0
        try readChunks(input, path: source.path) { chunk in
            crc = Zlib.crc32(crc, chunk)
            size += UInt64(chunk.count)
        }
        let start = offset
        let zip64 = size >= zip64Threshold || start >= zip64Threshold
        let nameBytes = Array(name.utf8)
        var header = ByteWriter()
        header.u32(0x0403_4B50)
        header.u16(zip64 ? 45 : 20)       // version needed: 4.5 for zip64, else 2.0
        header.u16(0x0800)                // UTF-8 names
        header.u16(0)                     // stored
        header.u16(dosTime); header.u16(dosDate)
        header.u32(crc)
        header.u32(zip64 ? 0xFFFF_FFFF : UInt32(size))
        header.u32(zip64 ? 0xFFFF_FFFF : UInt32(size))
        header.u16(UInt16(nameBytes.count))
        header.u16(zip64 ? 20 : 0)
        header.bytes(nameBytes)
        if zip64 {
            header.u16(0x0001); header.u16(16)
            header.u64(size); header.u64(size)
        }
        try write(header.data)
        // Pass 2: the bytes. A file that changed size since pass 1 would leave a corrupt entry.
        try input.seek(toOffset: 0)
        var copied: UInt64 = 0
        var check: UInt32 = 0
        try readChunks(input, path: source.path) { chunk in
            check = Zlib.crc32(check, chunk)
            copied += UInt64(chunk.count)
            try write(chunk)
        }
        guard copied == size, check == crc else {
            throw ZipWriterError.io(path: source.path, reason: "the file changed while it was being archived")
        }
        entries.append(Entry(name: nameBytes, crc: crc, size: size, offset: start, zip64: zip64))
        names.insert(key)
    }

    /// Writes the central directory and closes the file. The archive is
    /// complete only after this returns.
    public func finish() throws {
        guard !done else { throw ZipWriterError.finished }
        done = true
        let cdStart = offset
        for e in entries {
            var c = ByteWriter()
            c.u32(0x0201_4B50)
            c.u16(0x0300 | 45)            // made by: Unix, 4.5
            c.u16(e.zip64 ? 45 : 20)
            c.u16(0x0800)
            c.u16(0)
            c.u16(dosTime); c.u16(dosDate)
            c.u32(e.crc)
            c.u32(e.zip64 ? 0xFFFF_FFFF : UInt32(e.size))
            c.u32(e.zip64 ? 0xFFFF_FFFF : UInt32(e.size))
            c.u16(UInt16(e.name.count))
            c.u16(e.zip64 ? 28 : 0)
            c.u16(0)                      // comment
            c.u16(0)                      // disk
            c.u16(0)                      // internal attributes
            c.u32(0o100644 << 16)         // regular file, rw-r--r--
            c.u32(e.zip64 ? 0xFFFF_FFFF : UInt32(e.offset))
            c.bytes(e.name)
            if e.zip64 {
                // Every saturated field above, in the order of APPNOTE §4.5.3.
                c.u16(0x0001); c.u16(24)
                c.u64(e.size); c.u64(e.size); c.u64(e.offset)
            }
            try write(c.data)
        }
        let cdSize = offset - cdStart
        let big = entries.count > zip64EntryThreshold || cdStart >= zip64Threshold || cdSize >= zip64Threshold
        var end = ByteWriter()
        if big {
            let recordOffset = offset
            end.u32(0x0606_4B50)
            end.u64(44)                   // size of the rest of the record
            end.u16(0x0300 | 45); end.u16(45)
            end.u32(0); end.u32(0)        // this disk, the central directory's disk
            end.u64(UInt64(entries.count)); end.u64(UInt64(entries.count))
            end.u64(cdSize); end.u64(cdStart)
            end.u32(0x0706_4B50)          // locator
            end.u32(0); end.u64(recordOffset); end.u32(1)
        }
        end.u32(0x0605_4B50)
        end.u16(0); end.u16(0)
        let count16 = big ? 0xFFFF : UInt16(entries.count)
        end.u16(count16); end.u16(count16)
        end.u32(big ? 0xFFFF_FFFF : UInt32(cdSize))
        end.u32(big ? 0xFFFF_FFFF : UInt32(cdStart))
        end.u16(0)
        try write(end.data)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw ZipWriterError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    private func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch {
            throw ZipWriterError.io(path: url.path, reason: error.localizedDescription)
        }
        offset += UInt64(data.count)
    }

    private func readChunks(_ input: FileHandle, path: String, _ body: (Data) throws -> Void) throws {
        while true {
            let chunk: Data
            do { chunk = try input.read(upToCount: Self.chunk) ?? Data() } catch {
                throw ZipWriterError.io(path: path, reason: error.localizedDescription)
            }
            if chunk.isEmpty { return }
            try body(chunk)
        }
    }

    /// MS-DOS time and date fields (local time, 2-second resolution, 1980 ... 2107).
    static func dos(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Little-endian field writer for zip records.
private struct ByteWriter {
    var data = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

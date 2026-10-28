import Foundation

/// Writes a large synthetic MP4 at `url` for streaming tests: the boxes of
/// `fastStart` (a small real clip with `moov` before `mdat`) up to its
/// `mdat`, then one `mdat` with a 64-bit size whose body is `total` minus
/// the header bytes of zeros, left sparse (the file system stores none of
/// them). The result probes as the small clip did, at any size.
public func writeSparseMP4(fastStart: Data, to url: URL, total: Int) throws {
    let bytes = [UInt8](fastStart)
    var pos = 0
    var head = Data()
    while pos + 8 <= bytes.count {
        let size = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
        let type = String(decoding: bytes[pos + 4..<pos + 8], as: UTF8.self)
        if type == "mdat" { break }
        guard size >= 8, pos + size <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        head += fastStart[pos..<pos + size]
        pos += size
    }
    let mdat = UInt64(total - head.count)
    head += Data([0, 0, 0, 1]) + Data("mdat".utf8) + Data((0..<8).map { UInt8(truncatingIfNeeded: mdat >> (56 - 8 * $0)) })
    guard FileManager.default.createFile(atPath: url.path, contents: head) else { throw CocoaError(.fileWriteUnknown) }
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.truncate(atOffset: UInt64(total))
}

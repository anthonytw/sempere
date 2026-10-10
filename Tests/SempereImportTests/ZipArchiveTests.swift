import Foundation
import FuzzSupport
import ImportTestSupport
import TempDirSupport
import XCTest
@testable import SempereImport

final class ZipArchiveTests: TempDirTestCase {
    let files: [(String, Data)] = [
        ("a.txt", Data("hello, zip".utf8)),
        ("dir/b.bin", Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
        ("dir/sub/empty", Data()),
        ("dir/ünïcode name.txt", Data(String(repeating: "compressible ", count: 500).utf8)),
    ]

    private func check(_ zip: ZipArchive, file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, data) in files {
            let e = try XCTUnwrap(zip.entry(path), "missing \(path)", file: file, line: line)
            XCTAssertEqual(try zip.read(e), data, path, file: file, line: line)
        }
    }

    func testSystemZipTool() throws {
        let zipTool = ExternalTool.find("zip")?.path
        if zipTool == nil, RequiredTools.isRequired("zip") { XCTFail("no zip tool installed and SEMPERE_REQUIRE_TOOLS names zip") }
        guard let zipTool else { throw XCTSkip("no zip tool installed") }
        for (path, data) in files {
            let url = tmp.appendingPathComponent("src").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let out = tmp.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zipTool)
        p.currentDirectoryURL = tmp.appendingPathComponent("src")
        p.arguments = ["-q", "-r", out.path, "."]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let zip = try ZipArchive(url: out)
        try check(zip)
        XCTAssertTrue(zip.entries.contains { $0.path == "dir/" && $0.isDirectory })
        XCTAssertTrue(zip.entries.contains { $0.method == 8 }, "expected at least one deflated entry")
        // The same bytes open from memory.
        try check(ZipArchive(data: Data(contentsOf: out)))
    }

    func testWriterStoredDeflatedAndZip64() throws {
        for zip64 in [false, true] {
            let data = TestZip.write(files.enumerated().map { i, f in .init(path: f.0, data: f.1, deflate: i % 2 == 0) },
                                       zip64: zip64)
            let zip = try ZipArchive(data: data)
            XCTAssertEqual(zip.entries.map(\.path), files.map(\.0))
            try check(zip)
            let url = tmp.appendingPathComponent("w\(zip64).zip")
            try data.write(to: url)
            try check(ZipArchive(url: url))
        }
    }

    func testCorruptionIsReported() throws {
        var data = TestZip.write([.init(path: "x", data: Data("payload payload payload".utf8), deflate: false)])
        let zip = try ZipArchive(data: data)
        let e = try XCTUnwrap(zip.entry("x"))
        // Flip a payload byte: CRC mismatch.
        data[30 + 1 + 3] ^= 0xFF
        XCTAssertThrowsError(try ZipArchive(data: data).read(e)) { error in
            guard case ImportError.zip(let msg) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(msg.contains("CRC"), msg)
        }
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, definitely not".utf8)))
        XCTAssertThrowsError(try ZipArchive(data: Data()))
        XCTAssertThrowsError(try zip.read(e, maxSize: 3))
    }

    // MARK: - Hostile archives (security review S7, S18)

    /// A zip holding `body` (deflated `data` unless `stored`) once, named by
    /// every one of `names`: each central record points at the same local
    /// header. `crc` and `sizes` override what the records claim.
    static func sharedEntry(_ data: Data, names: [String], stored: Bool = false, crc: UInt32? = nil,
                            sizes: (compressed: UInt32, uncompressed: UInt32)? = nil) -> Data {
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
        let body = stored ? data : TestZip.rawDeflate(data)
        let crc = crc ?? ZipArchive.crc32(data)
        let c = sizes?.compressed ?? UInt32(body.count), u = sizes?.uncompressed ?? UInt32(data.count)
        let method = stored ? 0 : 8
        var out = le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
        out += le32(crc) + le32(c) + le32(u) + le16(1) + le16(0) + Data("x".utf8) + body
        let cdOffset = out.count
        var central = Data()
        for n in names {
            let name = Data(n.utf8)
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(crc)
            central += le32(c) + le32(u) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(0) + name
        }
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(names.count) + le16(names.count)
        out += le32(UInt32(central.count)) + le32(UInt32(cdOffset)) + le16(0)
        return out
    }

    /// 2 000 records over one 64 MiB deflate bomb (64 KiB of archive): reading
    /// every entry used to inflate 128 GiB. The archive is now refused.
    func testOverlappingEntriesAreRefused() throws {
        let names = (0..<2000).map { "thumb\($0).png" }
        let bomb = Self.sharedEntry(Data(count: 64 << 20), names: names)
        XCTAssertLessThan(bomb.count, 1 << 20)
        let t0 = Date()
        do {
            let pkg = try NotePackage(data: bomb)
            for p in pkg.paths { _ = try? pkg.read(p) }
            XCTFail("an archive whose entries overlap was opened")
        } catch {
            guard case ImportError.zip(let msg) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(msg.contains("overlap"), msg)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testDuplicateNamesAreRefused() throws {
        var files = [TestZip.File(path: "Session.plist", data: Data("one".utf8)),
                     TestZip.File(path: "Session.plist", data: Data("two".utf8))]
        XCTAssertThrowsError(try ZipArchive(data: TestZip.write(files))) {
            guard case ImportError.zip(let msg) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(msg.contains("duplicate"), msg)
        }
        files[1].path = "Session2.plist"
        XCTAssertEqual(try ZipArchive(data: TestZip.write(files)).entries.count, 2)
    }

    /// One 64 MiB entry with a wrong CRC, named by 1 000 media objects: each
    /// read inflated all of it again before failing (64 GiB in all). A failed
    /// read is now remembered by the package.
    func testFailedReadsAreNotRepeated() throws {
        let zip = Self.sharedEntry(Data(count: 64 << 20), names: ["Images/a.png"], crc: 1)
        let pkg = try NotePackage(data: zip)
        let t0 = Date()
        for _ in 0..<1000 { XCTAssertThrowsError(try pkg.read("Images/a.png")) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    /// Successful reads of one entry, over and over, stop at the archive's budget.
    func testReadsAreChargedToTheArchiveBudget() throws {
        let zip = try ZipArchive(data: Self.sharedEntry(Data(count: 64 << 20), names: ["big"]), readBudget: 256 << 20)
        let e = try XCTUnwrap(zip.entry("big"))
        for _ in 0..<4 { XCTAssertEqual(try zip.read(e).count, 64 << 20) }
        XCTAssertThrowsError(try zip.read(e)) {
            guard case ImportError.zip(let msg) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(msg.contains("in all"), msg)
        }
        XCTAssertEqual(ZipArchive.readBudget(forArchiveOf: 1 << 20), 2 << 30)
        XCTAssertEqual(ZipArchive.readBudget(forArchiveOf: 1 << 30), 32 << 30)
    }

    /// Sizes that the stored bytes cannot match are refused before they are read.
    func testImpossibleSizesAreRefusedBeforeReading() throws {
        let payload = Data(repeating: 7, count: 4096)
        let storedLie = try ZipArchive(data: Self.sharedEntry(payload, names: ["s"], stored: true,
                                                               sizes: (compressed: 4096, uncompressed: 0)))
        XCTAssertThrowsError(try storedLie.read(XCTUnwrap(storedLie.entry("s")))) {
            guard case ImportError.zip(let msg) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(msg.contains("stored entry"), msg)
        }
        let deflated = TestZip.rawDeflate(payload)
        let deflateLie = try ZipArchive(data: Self.sharedEntry(payload, names: ["d"],
                                                                sizes: (compressed: UInt32(deflated.count), uncompressed: 1)))
        XCTAssertThrowsError(try deflateLie.read(XCTUnwrap(deflateLie.entry("d"))))
        // Honest stored and deflated entries still read.
        let ok = try ZipArchive(data: TestZip.write([.init(path: "a", data: payload, deflate: false),
                                                     .init(path: "b", data: payload)]))
        for p in ["a", "b"] { XCTAssertEqual(try ok.read(XCTUnwrap(ok.entry(p))), payload) }
    }
}

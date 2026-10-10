import Foundation
import FuzzSupport
import ImportTestSupport
import XCTest
@testable import SempereImport

final class ZipArchiveTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkimport-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

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
        let zipTool = ["/usr/bin/zip", "/bin/zip"].first { FileManager.default.isExecutableFile(atPath: $0) }
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
}

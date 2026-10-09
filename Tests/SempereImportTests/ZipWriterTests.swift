import TempDirSupport
import XCTest
import Foundation
import ImportTestSupport
@testable import SempereRender
import SempereImport
import Sempere

/// The export archive writer (this target has a test helper named `ZipWriter` too).
private typealias StreamZip = SempereRender.ZipWriter

/// `SempereRender.ZipWriter` (bulk export archives), read back with the importer's
/// `ZipArchive` and, when installed, Info-ZIP `unzip -t`.
final class ZipWriterTests: XCTestCase {
    func scratch() throws -> URL { try makeScratchDirectory("zipw") }

    func file(_ dir: URL, _ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// `unzip -t` on the archive, when Info-ZIP is installed (nil otherwise).
    func unzipTest(_ archive: URL) throws -> (Int32, String)? {
        let tool = ["/usr/bin/unzip", "/bin/unzip", "/opt/homebrew/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-t", archive.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    func testRoundTripWithUnicodeNamesAndFolders() throws {
        let dir = try scratch()
        let big = Data((0..<(3 * StreamZip.chunk + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let files: [(String, Data)] = [
            ("Groceries-00000001.pdf", Data("%PDF-1.7 small".utf8)),
            ("School/Math/Café-ünï-00000002.pdf", big),
            ("School/Empty-00000003.pdf", Data()),
        ]
        let archive = dir.appendingPathComponent("out.zip")
        let zip = try StreamZip(url: archive)
        for (i, (name, data)) in files.enumerated() { try zip.add(name: name, contentsOf: try file(dir, "f\(i)", data)) }
        XCTAssertEqual(zip.count, 3)
        try zip.finish()
        let read = try ZipArchive(url: archive)
        XCTAssertEqual(read.entries.map(\.path), files.map(\.0))
        for (name, data) in files {
            let e = try XCTUnwrap(read.entry(name))
            XCTAssertEqual(e.method, 0)
            XCTAssertEqual(try read.read(e), data, name)
        }
        if let (status, out) = try unzipTest(archive) { XCTAssertEqual(status, 0, out) }
    }

    func testZip64FieldsWhenSizesAndCountsOverflow() throws {
        let dir = try scratch()
        let archive = dir.appendingPathComponent("z64.zip")
        // Thresholds lowered so the zip64 paths run without writing 4 GiB.
        let zip = try StreamZip(url: archive, date: Date(), zip64Threshold: 100, zip64EntryThreshold: 2)
        let payloads = [Data(repeating: 1, count: 10), Data(repeating: 2, count: 500), Data(repeating: 3, count: 20)]
        for (i, d) in payloads.enumerated() { try zip.add(name: "n\(i).bin", contentsOf: try file(dir, "s\(i)", d)) }
        try zip.finish()
        let bytes = try Data(contentsOf: archive)
        XCTAssertNotNil(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x06])), "zip64 end of central directory")
        XCTAssertNotNil(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x07])), "zip64 locator")
        let read = try ZipArchive(url: archive)
        XCTAssertEqual(read.entries.count, 3)
        for (i, d) in payloads.enumerated() { XCTAssertEqual(try read.read(try XCTUnwrap(read.entry("n\(i).bin"))), d) }
        if let (status, out) = try unzipTest(archive) { XCTAssertEqual(status, 0, out) }
    }

    func testRefusesBadAndDuplicateNames() throws {
        let dir = try scratch()
        let src = try file(dir, "src", Data("x".utf8))
        let zip = try StreamZip(url: dir.appendingPathComponent("bad.zip"))
        for bad in ["", "/abs", "a/../b", "a//b", "./a", "a\\b", "a\u{1}b", "dir/"] {
            XCTAssertThrowsError(try zip.add(name: bad, contentsOf: src), bad) { XCTAssertEqual($0 as? SempereRender.ZipWriterError, .badName(bad)) }
        }
        try zip.add(name: "Note.pdf", contentsOf: src)
        // Equal ignoring case: one file on extraction to a case-insensitive disk.
        XCTAssertThrowsError(try zip.add(name: "note.PDF", contentsOf: src)) {
            XCTAssertEqual($0 as? SempereRender.ZipWriterError, .duplicateName("note.PDF"))
        }
        XCTAssertThrowsError(try zip.add(name: "x", contentsOf: dir.appendingPathComponent("missing")))
        try zip.finish()
        XCTAssertThrowsError(try zip.finish()) { XCTAssertEqual($0 as? SempereRender.ZipWriterError, .finished) }
        XCTAssertEqual(try ZipArchive(url: dir.appendingPathComponent("bad.zip")).entries.map(\.path), ["Note.pdf"])
    }

    /// A bulk export into a zip: the archive holds the same tree a folder export writes.
    func testBulkExportZipMirrorsTheFolderTree() throws {
        let dir = try scratch()
        let notes = [
            NoteSummary(id: UUID(uuidString: "00000001-0000-4000-8000-000000000000")!, title: "One", tags: [],
                        notebook: "A", deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil),
            NoteSummary(id: UUID(uuidString: "00000002-0000-4000-8000-000000000000")!, title: "Two", tags: [],
                        notebook: "A/B", deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil),
        ]
        let jobs = BulkExportPlan.jobs(for: .vault, from: notes, format: .png, layout: .notebooks)
        let archive = dir.appendingPathComponent("Notes.zip"), staging = dir.appendingPathComponent("staging")
        let session = try BulkExportSession(destination: .zip(archive: archive, staging: staging),
                                            options: BulkExportOptions(format: .png, dpi: 18), jobs: jobs)
        for job in jobs {
            let state = NoteState(meta: NoteMeta(title: job.title, created: Date(timeIntervalSince1970: 0)),
                                  pages: [Page(id: job.noteId, order: "a", strokes: [])])
            try session.export(job, state: state, version: "1", blobs: nil)
        }
        let result = try session.finish(cancelled: false)
        XCTAssertEqual(result.output, archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "staged plaintext is deleted")
        let read = try ZipArchive(url: archive)
        XCTAssertEqual(read.entries.map(\.path), ["A/One-00000001/p001.png", "A/B/Two-00000002/p001.png"])
        XCTAssertEqual(try read.read(read.entries[0]).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

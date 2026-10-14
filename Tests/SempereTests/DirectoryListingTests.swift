import Foundation
import XCTest
@testable import Sempere

/// `FileIO.entries(_:directories:where:)` (readdir types, a stat only for
/// links and unknown types) keeps exactly what the stat-per-entry filters did.
final class DirectoryListingTests: VaultTestCase {
    private func old(_ dir: URL, directories: Bool, _ include: (String) -> Bool) throws -> [String] {
        try FileIO.entries(dir).filter { include($0) && FileIO.isDirectory(dir.appendingPathComponent($0)) == directories }
    }

    func testTypesMatchTheStatFilter() throws {
        let dir = tmp.appendingPathComponent("d")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("file"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-dir"), withDestinationURL: dir.appendingPathComponent("sub"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-file"), withDestinationURL: dir.appendingPathComponent("file"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-broken"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        _ = dir.appendingPathComponent("fifo").withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
        for directories in [true, false] {
            XCTAssertEqual(try FileIO.entries(dir, directories: directories) { _ in true },
                           try old(dir, directories: directories) { _ in true })
        }
        XCTAssertEqual(try FileIO.entries(dir, directories: true) { _ in true }, ["link-dir", "sub"])
        XCTAssertEqual(try FileIO.entries(dir, directories: false) { $0.hasPrefix("link") }, ["link-broken", "link-file"])
        XCTAssertEqual(try FileIO.entries(dir.appendingPathComponent("missing"), directories: false) { _ in true }, [])
        XCTAssertThrowsError(try FileIO.entries(dir.appendingPathComponent("file"), directories: false) { _ in true })
    }

    /// Prints the time to list every note's revisions: one stat per file
    /// before, none now (`SEMPERE_BENCH_LISTING=1`: 2,000 notes x 200 files).
    func testListingTiming() throws {
        let bench = ProcessInfo.processInfo.environment["SEMPERE_BENCH_LISTING"] != nil
        let (notes, files) = bench ? (2_000, 200) : (20, 20)
        let vault = try makeVault(pqIdentity())
        for n in 0..<notes {
            let dir = vault.notesURL.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<files {
                let name = RevisionName(hlc: HLC(millis: 1_780_000_000_000 + Int64(n * files + f), counter: 0)!,
                                        device: devC, seq: f + 1, kind: .delta)
                FileManager.default.createFile(atPath: dir.appendingPathComponent(name.filename).path, contents: nil)
            }
        }
        let ids = try vault.noteIDs()
        XCTAssertEqual(ids.count, notes)
        var t = Date()
        var a = 0
        for id in ids {
            a += try old(vault.noteURL(id), directories: false) { RevisionName($0)?.filename == $0 }.count
        }
        let before = Date().timeIntervalSince(t)
        t = Date()
        var b = 0
        for id in ids { b += try vault.revisionNames(of: id).count }
        let after = Date().timeIntervalSince(t)
        XCTAssertEqual(a, notes * files)
        XCTAssertEqual(b, notes * files)
        print(String(format: "bench: listing %d notes x %d revisions: stat per file %.2f s, readdir types %.2f s",
                     notes, files, before, after))
    }
}

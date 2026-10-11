import FuzzSupport
import Foundation
import XCTest
@testable import Sempere
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The process's peak resident size so far, in bytes.
private func peakRSS() -> Int {
    peakResidentBytes()
}

/// Cost bounds of a backup run that do not show at the small sizes the other
/// backup tests use. The timing parts print numbers; quick mode (every
/// `swift test`) uses small sizes, `SEMPERE_BENCH_BACKUP=1` realistic ones.
final class BackupPerformanceTests: VaultTestCase {
    private var benchmark: Bool { ProcessInfo.processInfo.environment["SEMPERE_BENCH_BACKUP"] != nil }

    /// `backup.json` is saved every max(100, index / 20) files written, so the
    /// number of saves over a first run grows like log F, not F / 100.
    func testIndexSavesGrowLogarithmically() {
        func saves(files: Int, initial: Int = 0) -> Int {
            var indexed = initial, since = 0, n = 0
            for _ in 0..<files {
                indexed += 1; since += 1
                if Backup.isSaveDue(sinceSave: since, indexed: indexed) { n += 1; since = 0 }
            }
            return n
        }
        XCTAssertEqual(saves(files: 99), 0)
        XCTAssertEqual(saves(files: 100), 1)
        XCTAssertEqual(saves(files: 2_000), 20, "small vaults save every 100 files, as before")
        XCTAssertLessThan(saves(files: 500_000), 200, "was 5,000 saves of the whole index")
        // A run that rewrites files already indexed (a recipient change) saves every twentieth of the index.
        XCTAssertEqual(Backup.isSaveDue(sinceSave: 24_999, indexed: 500_000), false)
        XCTAssertEqual(Backup.isSaveDue(sinceSave: 25_000, indexed: 500_000), true)
    }

    /// Prints the time spent writing `backup.json` over a first run of F
    /// files with the old fixed cadence (every 100) and the current one.
    func testIndexSaveCostOverAFirstRun() throws {
        let files = benchmark ? 50_000 : 5_000
        let url = tmp.appendingPathComponent("backup.json")
        func run(_ due: (Int, Int) -> Bool) throws -> (TimeInterval, Int) {
            var m = BackupManifest(format: BackupManifest.formatIdentifier, vaultId: "x", created: Date(),
                                   updated: Date(), files: [:])
            var since = 0, saves = 0
            let t = Date()
            for i in 0..<files {
                m.files["notes/\(i % 5_000)/0000000000000-aaaaaaaaaaaaaaaa-\(i).d.age"] =
                    .init(sha256: String(repeating: "a", count: 64), size: 1_000 + i)
                since += 1
                if due(since, m.files.count) { try m.write(to: url); since = 0; saves += 1 }
            }
            try m.write(to: url)
            return (Date().timeIntervalSince(t), saves + 1)
        }
        let old = try run { since, _ in since >= 100 }
        let new = try run(Backup.isSaveDue)
        print(String(format: "bench: backup.json over %d files: every 100: %d saves %.2f s; geometric: %d saves %.2f s",
                     files, old.1, old.0, new.1, new.0))
        XCTAssertLessThanOrEqual(new.1, old.1)
    }

    /// A large attachment blob goes through backup (copy, then replace with
    /// its previous copy kept), verify, restore and archive in pieces: the
    /// copies are byte-identical and, with `SEMPERE_BENCH_BACKUP=1` (a 1 GiB
    /// blob, `SEMPERE_BENCH_BLOB_MIB` to change it), the peak resident size
    /// grows by far less than the blob. Run that one on its own: the peak is
    /// per process.
    func testLargeBlobStaysOutOfMemory() throws {
        let mib = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_BLOB_MIB"] ?? "") ?? (benchmark ? 1024 : 24)
        let id = pqIdentity()
        let vault = try makeVault(id)
        _ = try populate(vault)
        let att = vault.url.appendingPathComponent("notes/\(testNote.uuidString.lowercased())/att")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        let blobName = String(repeating: "ab", count: 32) + ".pdf.age"
        let blob = att.appendingPathComponent(blobName)
        let blobPath = "notes/\(testNote.uuidString.lowercased())/att/\(blobName)"
        var piece = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        XCTAssertTrue(FileManager.default.createFile(atPath: blob.path, contents: nil))
        let out = try FileHandle(forWritingTo: blob)
        for i in 0..<mib {
            piece[0] = UInt8(truncatingIfNeeded: i)
            try autoreleasing { try out.write(contentsOf: piece) }
        }
        try out.close()
        let blobHash = try FileDigest.sha256(of: blob).hex

        let dest = tmp.appendingPathComponent("backup")
        let base = peakRSS()
        var steps: [(String, Int, TimeInterval)] = []
        func step(_ name: String, _ body: () throws -> Void) rethrows {
            let t = Date()
            try body()
            steps.append((name, peakRSS() - base, Date().timeIntervalSince(t)))
        }
        try step("backup (copy)") {
            let r = try Backup.run(source: vault, to: dest)
            XCTAssertTrue(r.copied.contains(blobPath))
            XCTAssertEqual(r.errors, [])
        }
        XCTAssertEqual(try FileDigest.sha256(of: Backup.url(dest, blobPath)).hex, blobHash)
        // Change its last byte in place: a checksummed run replaces it and keeps the previous copy.
        let h = try FileHandle(forUpdating: blob)
        try h.seek(toOffset: UInt64(mib << 20) - 1)
        try h.write(contentsOf: Data([0x5a]))
        try h.close()
        let newHash = try FileDigest.sha256(of: blob).hex
        try step("backup (replace)") {
            let r = try Backup.run(source: vault, to: dest, options: BackupOptions(checksum: true))
            XCTAssertEqual(r.replaced, [blobPath])
            XCTAssertEqual(r.versioned.count, 1)
            XCTAssertEqual(try FileDigest.sha256(of: Backup.url(dest, r.versioned[0])).hex, blobHash)
        }
        XCTAssertEqual(try FileDigest.sha256(of: Backup.url(dest, blobPath)).hex, newHash)
        try step("verify") {
            let r = Backup.verify(at: dest)
            XCTAssertEqual(r.files.filter { $0.status != .ok }.map(\.path), [])
        }
        let target = tmp.appendingPathComponent("Restored.sempere")
        try step("restore") {
            let r = try Backup.restore(from: dest, to: target)
            XCTAssertEqual(r.errors, [])
            XCTAssertTrue(r.restored.contains(blobPath))
        }
        XCTAssertEqual(try FileDigest.sha256(of: Backup.url(target, blobPath)).hex, newHash)
        let archive = tmp.appendingPathComponent("vault.tar")
        try step("archive") {
            let r = try Backup.writeArchive(source: vault, to: archive)
            XCTAssertEqual(r.sha256, try FileDigest.sha256(of: archive).hex)
            XCTAssertEqual(r.bytes, Int(try FileDigest.sha256(of: archive).size))
        }
        for (name, grown, time) in steps {
            print(String(format: "bench: %d MiB blob, %@: peak RSS +%d MiB, %.2f s", mib, name, grown >> 20, time))
        }
        if benchmark {
            for (name, grown, _) in steps {
                XCTAssertLessThan(grown, 64 << 20, "\(name) held the blob in memory")
            }
        }
    }

    /// The streaming archive reader agrees with the in-memory one.
    func testArchiveDigestsMatchTheMembers() throws {
        let vault = try makeVault(pqIdentity())
        _ = try populate(vault)
        let archive = tmp.appendingPathComponent("v.tar")
        let report = try Backup.writeArchive(source: vault, to: archive)
        let data = try Data(contentsOf: archive)
        let read = try TarReader.digests(of: archive)
        XCTAssertEqual(read.members.map(\.path), try TarReader.files(data).map(\.path))
        XCTAssertEqual(read.members.map(\.sha256), try TarReader.files(data).map { FileDigest.sha256($0.data) })
        XCTAssertEqual(read.sha256, FileDigest.sha256(data))
        XCTAssertEqual(read.bytes, data.count)
        XCTAssertEqual(report.sha256, read.sha256)
        // A cut-off archive is refused, as by the in-memory reader.
        let bytes = [UInt8](data)
        var off = 0
        while let h = try TarReader.header(bytes[off..<(off + 512)], at: off), h.size == 0 { off += 512 }
        let cut = tmp.appendingPathComponent("cut.tar")
        try data.prefix(off + 512 + 1).write(to: cut)
        XCTAssertThrowsError(try TarReader.files(data.prefix(off + 512 + 1)))
        XCTAssertThrowsError(try TarReader.digests(of: cut))
    }

    /// A restore refusing a damaged file leaves no folder of it behind.
    func testRefusedRestoreLeavesNoFolders() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        _ = try populate(vault)
        let dest = tmp.appendingPathComponent("backup")
        _ = try Backup.run(source: vault, to: dest)
        let note = "notes/\(testNote.uuidString.lowercased())"
        for p in try Backup.formatFiles(in: dest) where p.hasPrefix(note + "/") {
            let u = Backup.url(dest, p)
            var d = try Data(contentsOf: u)
            d[d.count - 1] ^= 1
            try d.write(to: u)
        }
        let target = tmp.appendingPathComponent("R.sempere")
        let r = try Backup.restore(from: dest, to: target, identities: [id])
        XCTAssertFalse(r.errors.isEmpty)
        XCTAssertTrue(r.errors.allSatisfy { $0.message.contains("damaged") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(note).path))
    }

    /// Prints the time `--prune` spends finding one note's covering
    /// snapshots: the old way (every revision with stroke geometry) and
    /// `Backup.prunable`'s (the snapshots the backup holds, without points).
    func testPruneCoverageReadsOnlySnapshotsWithoutGeometry() throws {
        let vault = try makeVault(pqIdentity())
        let strokes = benchmark ? 20_000 : 500
        try SyntheticVault.populate(vault, notes: 1, strokes: strokes, points: 60)
        let id = try XCTUnwrap(try vault.noteIDs().first)
        var clock = HybridClock()
        _ = try vault.snapshot(noteId: id, device: devC, clock: &clock, wall: Date(), app: "test/0")
        let note = id.uuidString.lowercased()
        var t = Date()
        let old = try vault.loadNote(id).revisions.filter { $0.name.kind == .snapshot }.compactMap(SnapshotCoverage.init)
        let before = Date().timeIntervalSince(t)
        t = Date()
        let delta = try XCTUnwrap(try vault.revisionNames(of: id).first { $0.kind == .delta })
        let gone = "notes/\(note)/\(delta.filename)"
        let allowed = Backup.prunable(note: note, paths: [gone], source: vault, backup: nil, backupHolds: { _ in true })
        let after = Date().timeIntervalSince(t)
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(allowed, [gone], "the old delta is covered by the snapshot")
        print(String(format: "bench: prune coverage, %d strokes x 60 points: full load %.3f s, snapshots only %.3f s",
                     strokes, before, after))
    }
}

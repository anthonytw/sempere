import Age
import CLITestSupport
import Foundation
import VaultTestSupport
import Sempere
import XCTest

/// Device check c22 ("Backups to a NAS share and a drive"), the drive half automated: backups to a FAT disk image
/// (no extended attributes, no hard links, a size that fills up), to a folder that cannot be written, to a
/// destination that disappears or slows down part way, and the verify/restore round trip after each. The NAS half
/// (a real SMB/NFS share picked in Files) still needs a person with lab access.
final class CLIBackupStressTests: CLITestCase {
    var keyPath = ""
    var vaultPath = ""
    var state: URL { tmp.appendingPathComponent("backup-device.json") }

    /// A vault of `notes` notes, each holding `kb` KiB of picture data (encrypted, so incompressible).
    func bigVault(notes: Int, kb: Int) throws -> Vault {
        let id = try NativeIdentity.generate(.postQuantum)
        keyPath = path("backup-stress.key")
        try TestVaults.deviceKeyFile(id).write(toFile: keyPath, atomically: true, encoding: .utf8)
        vaultPath = path("backup-stress.sempere")
        let vault = try TestVaults.create(at: URL(fileURLWithPath: vaultPath), identities: [id], trust: cliTrustStore)
        let side = Int((Double(kb * 1024) / 3).squareRoot())
        for n in 0..<notes {
            let note = UUID()
            let png = StressVault.png(width: side, height: side, rgb: (UInt8(n * 40 % 256), 10, 200))
            let ref = try vault.writeBlob(note: note, png, type: "image/png")
            var ops = NoteOps.newNote(title: "Big \(n)", paper: .ruled, pageId: UUID())
            guard case .addPage(let page)? = ops.first else { return vault }
            ops.append(.addStroke(page: page.id, stroke: StressVault.stroke(page: n)))
            ops.append(.addItem(page: page.id, item: .image(id: UUID(), blob: ref, pixelSize: Size(w: Double(side), h: Double(side)),
                                                             frame: Rect(x: 50, y: 50, w: 300, h: 300), z: "a0")))
            try vault.apply(ops, to: note, deviceState: state, app: "stress/1")
        }
        return vault
    }

    func verifyAndRestore(_ dir: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let verify = try cli(["backup", "verify", dir, "--identity", keyPath, "--json"])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err, file: file, line: line)
        XCTAssertEqual((verify.json as? [String: Any])?["decrypted"] as? Bool, true, file: file, line: line)
        let target = path("restored-\(UUID().uuidString.prefix(6)).sempere")
        let restore = try cli(["restore", dir, "--to", target, "--identity", keyPath])
        XCTAssertEqual(restore.status, 0, restore.out + restore.err, file: file, line: line)
        let check = try cli(["vault", "verify", "--vault", target, "--identity", keyPath])
        XCTAssertEqual(check.status, 0, check.out + check.err, file: file, line: line)
        let a = try cli(["notes", "list", "--json", "--vault", vaultPath, "--identity", keyPath])
        let b = try cli(["notes", "list", "--json", "--vault", target, "--identity", keyPath])
        XCTAssertEqual(a.out, b.out, "the restored vault lists the same notes", file: file, line: line)
    }

    func testBackupToAFATDriveRoundTrips() throws {
        _ = try bigVault(notes: 6, kb: 200)
        let drive = try mountFATVolume(megabytes: 32)
        let dir = drive + "/Sempere Backup"
        let first = try cli(["backup", vaultPath, "--to", dir, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let again = try cli(["backup", vaultPath, "--to", dir, "--json"])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual((again.json as? [String: Any])?["copied"] as? [String], [], "nothing copied twice on FAT")
        try verifyAndRestore(dir)
    }

    func testAFullDriveFailsCleanlyAndALargerOneFinishes() throws {
        _ = try bigVault(notes: 8, kb: 700)   // about 5.6 MB of pictures
        let small = try mountFATVolume(megabytes: 4)
        let dir = small + "/Backup"
        let full = try cli(["backup", vaultPath, "--to", dir])
        XCTAssertNotEqual(full.status, 0, "a backup that does not fit must not say it finished: \(full.out)")
        XCTAssertLessThan(full.status, 64, "an error exit, not a crash")
        print("STRESS c22 disk full: exit \(full.status): \(full.err.split(separator: "\n").suffix(2).joined(separator: " | "))")
        // What is there is never reported healthy as a complete backup.
        let verify = try cli(["backup", "verify", dir, "--identity", keyPath])
        XCTAssertNotEqual(verify.status, 0, "an incomplete backup does not verify: \(verify.out)")
        let status = try cli(["backup", "status", dir, "--json"])
        XCTAssertNil((status.json as? [String: Any])?["completed"], "a run with errors never counts as completed")

        let large = try mountFATVolume(megabytes: 48)
        let ok = try cli(["backup", vaultPath, "--to", large + "/Backup"])
        XCTAssertEqual(ok.status, 0, ok.err)
        try verifyAndRestore(large + "/Backup")
    }

    func testAFolderThatCannotBeWrittenIsAnErrorNotACrash() throws {
        try XCTSkipIf(getuid() == 0, "root writes into a folder whatever its permissions")
        _ = try bigVault(notes: 2, kb: 20)
        let dir = path("readonly")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
        let r = try cli(["backup", vaultPath, "--to", dir])
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(r.status, 64)
        XCTAssertFalse(r.err.isEmpty, "it says why")
    }

    /// The drive is unplugged part way (the destination folder vanishes between two files): the run stops with an
    /// error, nothing crashes, and a run to a new drive completes and verifies.
    func testADestinationThatVanishesPartWayStopsTheRun() throws {
        let vault = try bigVault(notes: 6, kb: 30)
        let dest = tmp.appendingPathComponent("unplugged")
        let written = Counter()
        XCTAssertThrowsError(try Backup.run(source: vault, to: dest, options: BackupOptions(afterEachFile: { _ in
            if written.next() == 4 { try FileManager.default.removeItem(at: dest) }
        }))) { error in
            XCTAssertEqual(error as? BackupError, .destinationGone(dest.path))
        }
        // Not recreated as a "backup" holding only the files written after the unplug.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(BackupManifest.fileName).path))
        let fresh = tmp.appendingPathComponent("second drive")
        let report = try Backup.run(source: vault, to: fresh)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(Backup.verify(at: fresh).isHealthy)
        // And once the first drive comes back (an empty folder again), it completes too.
        let again = try Backup.run(source: vault, to: dest)
        XCTAssertTrue(again.errors.isEmpty)
        XCTAssertTrue(Backup.verify(at: dest).isHealthy)
    }

    /// A slow destination (a NAS on Wi-Fi): each file takes a while; the run completes and an interrupted slow run
    /// resumes without copying again what it finished.
    func testASlowDestinationCompletesAndAnInterruptedOneResumes() throws {
        let vault = try bigVault(notes: 5, kb: 20)
        let dest = tmp.appendingPathComponent("slow")
        let n = Counter()
        XCTAssertThrowsError(try Backup.run(source: vault, to: dest, options: BackupOptions(afterEachFile: { _ in
            Thread.sleep(forTimeInterval: 0.05)
            if n.next() == 6 { throw VaultError.interrupted }
        })))
        let resumed = try Backup.run(source: vault, to: dest, options: BackupOptions(afterEachFile: { _ in
            Thread.sleep(forTimeInterval: 0.05)
        }))
        XCTAssertTrue(resumed.errors.isEmpty)
        XCTAssertGreaterThanOrEqual(resumed.unchanged, 5, "files of the first run are not copied again")
        XCTAssertTrue(Backup.verify(at: dest).isHealthy)
    }
}

/// A thread-safe counter for hooks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere

/// A fresh post-quantum identity (vaults take no other kind).
func pqIdentity() -> NativeIdentity { try! NativeIdentity.generate(.postQuantum) }

/// A temporary directory removed in tearDown (`TempDirTestCase`), plus helpers for vault tests.
class VaultTestCase: TempDirTestCase {
    func vaultURL(_ name: String = "Test") -> URL { tmp.appendingPathComponent("\(name).sempere") }

    func makeVault(_ identity: NativeIdentity, name: String = "Test") throws -> Vault {
        try Vault.create(at: vaultURL(name), recipients: [identity.recipient], labels: ["test"],
                         identities: [identity])
    }

    /// A legacy X25519 vault (format.md §3.3.2): only key files, recipients
    /// and migration work on it.
    func makeLegacyVault(_ identity: X25519Identity, name: String = "Test") throws -> Vault {
        try Vault.create(at: vaultURL(name), recipients: [identity.recipient], labels: ["test"],
                         identities: [identity])
    }

    func fileURL(_ vault: Vault, _ note: UUID, _ name: RevisionName) -> URL {
        vault.url.appendingPathComponent("notes").appendingPathComponent(note.uuidString.lowercased())
            .appendingPathComponent(name.filename)
    }

    /// Five revisions over one note from two devices (testNote).
    func sampleLog() -> [Revision] {
        var log = LogBuilder()
        let p1 = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a1")!
        let s1 = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000b1")!
        let s2 = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000b2")!
        let s3 = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000b3")!
        return [
            log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .setMeta(.title("Lecture 3"))]),
            log.delta(devA, 10, [.addStroke(page: p1, stroke: wireStroke(s1))]),
            log.delta(devB, 15, [.addStroke(page: p1, stroke: wireStroke(s2)), .setMeta(.tags(["math"]))]),
            log.delta(devB, 20, [.removeStroke(page: p1, strokeId: s1)]),
            log.delta(devA, 30, [.addStroke(page: p1, stroke: wireStroke(s3))]),
        ]
    }

    /// A stroke whose numbers survive the writer's 3-decimal rounding.
    func wireStroke(_ id: UUID) -> Stroke {
        Stroke(id: id, ink: Ink(tool: .pen, color: .black, width: 2),
               points: [StrokePoint(x: 1, y: 2, w: 2, h: 2, al: 1.5), StrokePoint(x: 3.25, y: 4, t: 0.016, w: 2, h: 2, al: 1.5)])
    }

    /// Two notes, six files in all.
    func populate(_ vault: Vault) throws -> [Revision] {
        let log = sampleLog()
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        var extra = log[0]
        extra.noteId = other
        let writer = vault.allowingLegacyContent()   // also builds legacy migration inputs
        for r in log + [extra] { try writer.write(r) }
        return log + [extra]
    }

    func assertReadable(_ revs: [Revision], at url: URL, by id: NativeIdentity, file: StaticString = #filePath,
                        line: UInt = #line) throws {
        let v = try Vault.open(at: url, identities: [id])
        for r in revs {
            XCTAssertEqual(try v.readRevision(noteId: r.noteId, name: r.name), r, file: file, line: line)
        }
        let report = v.verify()
        XCTAssertTrue(report.isHealthy, "\(report)", file: file, line: line)
        XCTAssertFalse(report.rewrapPending, file: file, line: line)
    }

    func stanzaCounts(_ vault: Vault, _ revs: [Revision]) throws -> [Int] {
        try revs.map { try AgeFile.parseHeader(Data(contentsOf: fileURL(vault, $0.noteId, $0.name))).header.stanzas.count }
    }

    /// Flips one bit of a file in place (simulating storage damage).
    func flipByte(_ url: URL, at offsetFromEnd: Int) throws {
        var d = try Data(contentsOf: url)
        d[d.count - offsetFromEnd] ^= 0x01
        try d.write(to: url)
    }
}

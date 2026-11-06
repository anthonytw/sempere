import TempDirSupport
import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

final class FixtureTests: XCTestCase {
    static func bundled(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    func testFixtureOpensAndReconstructs() throws {
        let (device, recovery) = try SampleFixture.bundledKeys()
        let identity = device.nativeIdentity
        let vault = try Vault.open(at: Self.bundled("sample.sempere"), identities: [identity], signing: device.signing)
        XCTAssertEqual(vault.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(vault.devices.map(\.key), [identity.recipient.string])
        XCTAssertEqual(vault.manifest.recoveryEntry?.key, recovery.recipient.string)
        XCTAssertTrue(vault.isHome, "the fixture device created the vault")
        XCTAssertEqual(try vault.noteIDs(), [SampleFixture.lecture, SampleFixture.deleted])
        XCTAssertEqual(try vault.revisionNames(of: SampleFixture.lecture).map(\.kind),
                       [.delta, .delta, .delta, .snapshot, .delta])

        let lecture = try vault.reconstruct(noteId: SampleFixture.lecture)
        XCTAssertEqual(lecture.meta.title, "Fixture lecture")
        XCTAssertEqual(lecture.meta.tags, ["fixture"])
        XCTAssertEqual(lecture.meta.paper.kind, .ruled)
        XCTAssertFalse(lecture.deleted)
        XCTAssertEqual(lecture.pages.map { $0.strokes.count }, [2, 2])
        XCTAssertEqual(lecture.pages.flatMap { $0.strokes.map(\.id) },
                       [102, 103, 104, 105].map(SampleFixture.id))

        let gone = try vault.reconstruct(noteId: SampleFixture.deleted)
        XCTAssertEqual(gone.meta.title, "Fixture deleted")
        XCTAssertTrue(gone.deleted)
        XCTAssertEqual(gone.pages.map { $0.strokes.count }, [1])

        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.counts[.ok], 9)   // 7 revisions, the passphrase copy, the epoch record
        XCTAssertEqual(report.counts[.unreferenced], 1)   // the attachment blob
        XCTAssertEqual(vault.manifest.features, [], "this version writes no features (format.md §2)")
        XCTAssertEqual(vault.listStatus, .verified(.firstUse), "the committed vault.json checks (format.md §15.3)")
        let blob = BlobRef(content: SampleFixture.attachment, type: SampleFixture.attachmentType)
        XCTAssertEqual(try vault.readBlob(note: SampleFixture.lecture, blob), SampleFixture.attachment)
        XCTAssertEqual(try vault.blobInventory(note: SampleFixture.lecture).unreferenced.map(\.fileName),
                       [try vault.blobFileName(for: blob)])

        // Same content as a fresh generation (only ciphertext is random).
        let tmp = TestTemp.root.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("sample.sempere")
        try SampleFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        for note in try vault.noteIDs() {
            XCTAssertEqual(try regenerated.revisionNames(of: note), try vault.revisionNames(of: note))
            for name in try vault.revisionNames(of: note) {
                XCTAssertEqual(try regenerated.readRevision(noteId: note, name: name),
                               try vault.readRevision(noteId: note, name: name), "\(name)")
            }
        }
    }

    /// GA-63: a committed vault whose note has items. It reads back as generated, its blob verifies and
    /// is referenced, and a fresh generation has the same content.
    func testItemsFixtureHoldsTextImageAndEquation() throws {
        let identity = try SampleFixture.bundledKeys().device.nativeIdentity
        let vault = try Vault.open(at: Self.bundled("items.sempere"), identities: [identity])
        XCTAssertEqual(vault.vaultId, ItemsFixture.vaultId)
        XCTAssertEqual(try vault.noteIDs(), [ItemsFixture.note])
        let state = try vault.reconstruct(noteId: ItemsFixture.note)
        XCTAssertEqual(state.meta.title, "Fixture items")
        let items = try XCTUnwrap(state.pages.first).items
        XCTAssertEqual(items.map(\.id), [ItemsFixture.textItem, ItemsFixture.imageItem, ItemsFixture.mathItem])
        XCTAssertEqual(items.map(\.kind), [.text, .image, .math])
        XCTAssertEqual(items[0].text?.runs.map(\.t), ["Fixture text box"])
        XCTAssertEqual(items[2].math?.latex, "e^{i\\pi}+1=0")
        let blob = try XCTUnwrap(items[1].blob)
        XCTAssertEqual(try vault.readBlob(note: ItemsFixture.note, blob), ItemsFixture.picture)
        XCTAssertEqual(try XCTUnwrap(state.pages.first).strokes.count, 1, "ink and items share the page")
        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertNil(report.counts[.unreferenced], "the image blob is referenced")
        XCTAssertEqual(try vault.blobInventory(note: ItemsFixture.note).unreferenced.count, 0)

        let tmp = TestTemp.root.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("items.sempere")
        try ItemsFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        XCTAssertEqual(try regenerated.revisionNames(of: ItemsFixture.note), try vault.revisionNames(of: ItemsFixture.note))
        XCTAssertEqual(try regenerated.reconstruct(noteId: ItemsFixture.note).pages, state.pages)
    }

    /// The passphrase copy opens to the fixture recovery key, with the vault's id and root; the recovery
    /// key opens the vault read-only, checked against that root.
    func testFixturePassphraseCopyOpensToTheRecoveryKey() throws {
        let (_, recovery) = try SampleFixture.bundledKeys()
        let locked = try Vault.open(at: Self.bundled("sample.sempere"))
        XCTAssertEqual(locked.passphraseCopyNames().count, 1)
        let copy = try locked.openPassphraseCopy(passphrase: SampleFixture.passphrase)
        XCTAssertEqual(copy.identity.string, recovery.string)
        XCTAssertEqual(copy.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(copy.root, locked.root)
        XCTAssertThrowsError(try locked.openPassphraseCopy(passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        let read = try Vault.open(at: Self.bundled("sample.sempere"), identities: [NativeIdentity.mlkem768x25519(recovery)],
                                  root: copy.root)
        XCTAssertTrue(read.isRecoveryOpen)
        XCTAssertEqual(read.listStatus, .verified(.firstUse))
        XCTAssertEqual(try read.reconstruct(noteId: SampleFixture.lecture).meta.title, "Fixture lecture")
        XCTAssertThrowsError(try read.requireWritable()) { XCTAssertEqual($0 as? VaultError, .recoveryKeyReadOnly) }
    }

}

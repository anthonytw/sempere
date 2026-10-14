import Age
import XCTest

@testable import Sempere

/// Library pieces the `sempere` CLI is built on: recovery, summaries,
/// compaction plan, device state, export names.
final class CLISupportTests: XCTestCase {
    func fixtureVault() throws -> (Vault, NativeIdentity) {
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        return (try Vault.open(at: FixtureTests.bundled("sample.sempere"), identities: [id]), id)
    }

    func firstRevisionFile(_ vault: Vault) throws -> (URL, String, String) {
        let note = SampleFixture.lecture
        let name = try vault.revisionNames(of: note)[0].filename
        let url = vault.url.appendingPathComponent("notes/\(note.uuidString.lowercased())/\(name)")
        return (url, note.uuidString.lowercased(), name)
    }

    func testRecoveryVerifiedAndUnverified() throws {
        let (vault, id) = try fixtureVault()
        let (url, note, name) = try firstRevisionFile(vault)
        let data = try Data(contentsOf: url)
        let ok = try Recovery.decrypt(data, noteId: note, filename: name, identities: [id], vault: vault)
        XCTAssertTrue(ok.verified)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: ok.json) as? [String: Any])
        let bare = try Recovery.decrypt(data, noteId: note, filename: name, identities: [id], vault: nil)
        XCTAssertFalse(bare.verified)
        XCTAssertEqual(bare.json, ok.json)
        // A wrong file name breaks the tag.
        XCTAssertThrowsError(try Recovery.decrypt(data, noteId: note, filename: "x" + name, identities: [id], vault: vault))
        // A wrong key fails in age.
        XCTAssertThrowsError(try Recovery.decrypt(data, noteId: note, filename: name,
                                                  identities: [X25519Identity()], vault: nil)) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
    }

    func testSummariesAndFind() throws {
        let (vault, _) = try fixtureVault()
        let all = try vault.summaries()
        XCTAssertEqual(all.count, 2)
        let lecture = try NoteSummary.find("Fixture lecture", in: all)
        XCTAssertEqual(lecture.id, SampleFixture.lecture)
        XCTAssertEqual(lecture.pages, 2)
        XCTAssertEqual(lecture.strokes, 4)
        XCTAssertEqual(lecture.tags, ["fixture"])
        XCTAssertFalse(lecture.deleted)
        XCTAssertTrue(try NoteSummary.find("2222", in: all).deleted)
        XCTAssertThrowsError(try NoteSummary.find("nope", in: all))
        XCTAssertThrowsError(try NoteSummary.find("fixture", in: all))   // not an exact title
        XCTAssertThrowsError(try NoteSummary.find("1", in: all))   // too short for a prefix
    }

    func testCompactionPlanMatchesCompact() throws {
        let (vault, _) = try fixtureVault()
        // Fixture revisions are 2026-10-04; far in the future everything covered is old.
        let plan = try vault.compactionPlan(noteId: SampleFixture.lecture, retention: 0,
                                            now: Date(timeIntervalSince1970: 4_000_000_000))
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(try vault.revisionNames(of: SampleFixture.lecture).count, 5)   // plan deleted nothing
    }

    func testDeviceStateRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = DeviceState.defaultURL(environment: ["XDG_STATE_HOME": dir.path], home: dir)
        XCTAssertEqual(url.path, dir.appendingPathComponent("sempere/device.json").path)
        var s = try DeviceState.loadOrCreate(at: url)
        XCTAssertEqual(s.device.rawValue.count, 8)
        var clock = s.clock
        _ = clock.tick(wall: Date())
        s.clock = clock
        try s.save(to: url)
        XCTAssertEqual(try DeviceState.loadOrCreate(at: url), s)
        XCTAssertEqual(DeviceState.defaultURL(environment: [:], home: dir).path,
                       dir.appendingPathComponent(".local/state/sempere/device.json").path)
    }

    func testExportName() {
        let id = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
        XCTAssertEqual(ExportName.stem(title: "Physics / Week 3: \"Waves\"", noteId: id), "Physics-Week-3-Waves-0d1c6a1e")
        XCTAssertEqual(ExportName.stem(title: "", noteId: id), "untitled-0d1c6a1e")
        XCTAssertEqual(ExportName.stem(title: "../..", noteId: id), "untitled-0d1c6a1e")
        XCTAssertLessThan(ExportName.stem(title: String(repeating: "a", count: 500), noteId: id).count, 80)
    }

    func testResolveNoteWithoutDecryptingAndDescriptions() throws {
        let (vault, id) = try fixtureVault()
        XCTAssertEqual(try vault.resolveNote("1111"), SampleFixture.lecture)
        XCTAssertEqual(try vault.resolveNote(SampleFixture.lecture.uuidString), SampleFixture.lecture)
        XCTAssertEqual(try vault.resolveNote("Fixture deleted"), SampleFixture.deleted)
        XCTAssertThrowsError(try vault.resolveNote("zzzz"))
        // A locked vault can still resolve ids (nothing is decrypted), but not titles.
        let locked = try Vault.open(at: FixtureTests.bundled("sample.sempere"))
        XCTAssertEqual(try locked.resolveNote("2222"), SampleFixture.deleted)
        XCTAssertThrowsError(try locked.resolveNote("Fixture deleted"))
        _ = id
        XCTAssertTrue("\(VaultError.invalidVaultName("notes"))".contains("must end in .sempere"))
        XCTAssertFalse("\(RevisionReadError.undecryptable("x"))".contains("undecryptable("))
        XCTAssertFalse("\(AgeError.noMatchingIdentity)".contains("noMatchingIdentity"))
    }

    func testRecoveryAllowMismatchPolicy() throws {
        let (vault, id) = try fixtureVault()
        let (url, note, name) = try firstRevisionFile(vault)
        let data = try Data(contentsOf: url)
        let r = try Recovery.decrypt(data, noteId: note, filename: "x" + name, identities: [id], vault: vault,
                                     onMismatch: .allowMismatch)
        XCTAssertTrue(r.tagMismatch)
        XCTAssertFalse(r.verified)
        XCTAssertFalse(r.json.isEmpty)
    }

    func testAssumedSnapshotSubsumesOlderSnapshots() throws {
        let (vault, _) = try fixtureVault()
        let loaded = try vault.loadNote(SampleFixture.lecture)
        let far = Date(timeIntervalSince1970: 4_000_000_000)
        let plain = loaded.compactionPlan(retention: 0, now: far)
        let assumed = loaded.compactionPlan(retention: 0, now: far, assumingSnapshot: true)
        XCTAssertEqual(assumed.count, 5)   // every existing revision is covered by the hypothetical snapshot
        XCTAssertLessThan(plain.count, assumed.count)
        XCTAssertTrue(loaded.needsSnapshotBeforeCompaction(retention: 0, now: far))
        XCTAssertFalse(loaded.needsSnapshotBeforeCompaction(retention: 100_000 * 86400, now: far))
    }
}

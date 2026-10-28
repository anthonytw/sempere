import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// F11 of device-first-sync §6.2 for re-encryption (key-hierarchy design §11.1 "a cut upload of a re-encrypted file"):
/// over wsgidav behind `scripts/dav-fault-proxy.py`, the connection is reset in the middle of every upload of a
/// re-encrypted file (the conditional PUT that replaces the old copy). The target then holds the old copy or the new
/// one, whole, never a mix; the next runs finish the replacement and the re-encryption. Skipped unless
/// `SEMPERE_WEBDAV_PROXY_URL` is set (`scripts/test-webdav.sh`; CI's `webdav` job).
final class ReencryptOverFaultProxyTests: SyncTestCase {
    private var proxy: FaultProxy!
    private var path = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        proxy = try FaultProxy.fromEnvironment()
        path = "rx-\(UUID().uuidString.lowercased())"
        try proxy.configure()
    }

    override func tearDownWithError() throws {
        try? proxy?.configure()
        try super.tearDownWithError()
    }

    func testACutUploadOfAReencryptedFileLeavesTheOldOrTheNewCopyNeverAMix() throws {
        let target = EpochTarget("T1")
        let proxy = self.proxy!, path = self.path
        target.reach = { _ in WebDAVSyncRemote(try! proxy.client(path)) }
        target.inspector = WebDAVSyncRemote(try proxy.client(path))
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], made: [target])
        var titles: [UUID: String] = [:]
        for i in 0..<3 { titles[try w["B"].write("B note \(i)")] = "B note \(i)" }
        // Review of #89, S9: a blob (temp name, then a move), an inbox capture and settings.age (conditional PUTs) too.
        let b = try w["B"].open()
        let blobNote = try XCTUnwrap(titles.keys.first)
        let blob = try b.writeBlob(note: blobNote, Data("attachment bytes for F11".utf8), type: "image/png")
        let device = try XCTUnwrap(b.writerDevice)
        let writer = try CaptureWriter(profile: try b.captureProfile(device: device))
        try CaptureWriter.store(try writer.seal(audio: Data("voice bytes".utf8), started: Date(), id: UUID()), in: b.inboxURL)
        var settings = SharedSettings()
        try settings.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: .mac, now: Date())
        try b.writeSharedSettings(settings)
        try w["B"].sync(target); try w["A"].sync(target)
        let old = try ReencryptSyncTests.keysSoFar(w, w["A"])
        let oldKeys = try ReencryptSyncTests.epochKeysSoFar(w["A"])
        func vaultFiles() -> [String: Data] {
            Dictionary(uniqueKeysWithValues: target.paths.filter { p in
                !(p as NSString).lastPathComponent.hasPrefix(".")
                    && (p.hasPrefix("notes/") || p.hasPrefix("inbox/") || p == SharedSettings.fileName)
            }.compactMap { p in target.file(p).map { (p, $0) } })
        }
        let before = vaultFiles()
        XCTAssertEqual(before.keys.filter { $0.hasPrefix("notes/") && !$0.contains("/att/") }.count, 3)
        XCTAssertTrue(before.keys.contains { $0.contains("/att/") }, "the blob")
        XCTAssertTrue(before.keys.contains { $0.hasPrefix("inbox/") }, "the capture")
        XCTAssertNotNil(before[SharedSettings.fileName], "settings.age")

        let kit = try ReencryptSyncTests.start(w, home: "A", targets: [target])
        _ = try w["A"].open().reencryptPass()
        // Every upload under notes/ (revisions, blob temp names), inbox/ and settings.age is cut in the middle of its body.
        try proxy.configure(rules: [.init(method: "PUT", path: "/\(path)/(notes|inbox)/.*", action: "reset", direction: "request",
                                          afterBytes: 300, times: 100),
                                    .init(method: "PUT", path: "/\(path)/settings\\.age", action: "reset", direction: "request",
                                          afterBytes: 100, times: 100)])
        let cut = try w["A"].sync(target)
        XCTAssertFalse(cut.errors.isEmpty, "the uploads were cut: \(cut)")
        let mine = try w["A"].open()
        let current = mine.identities, keys = old + current
        // Each file at a vault name is whole: the old bytes, or the new copy (a blob: its old name kept until the new
        // name is whole and in place).
        for (p, now) in vaultFiles() {
            XCTAssertNotNil(try? AgeFile.decrypt(now, with: keys), "\(p): a whole copy, old or new")
            if let was = before[p] {
                XCTAssertTrue(now == was || (try? AgeFile.decrypt(now, with: current)) != nil, "\(p): the old bytes, or the new copy")
            }
        }
        for p in before.keys where p.contains("/att/") && target.file(p) == nil {
            XCTAssertTrue(vaultFiles().keys.contains { $0.contains("/att/") && $0 != p }, "\(p) went only once its new name was there")
        }

        // Without faults the next runs finish the replacement and the re-encryption.
        try proxy.configure()
        var finished = false
        for _ in 0..<5 where !finished {
            try w["B"].sync(target)
            finished = try ReencryptSyncTests.advance(w, home: "A", targets: [target]).finished
        }
        XCTAssertTrue(finished)
        try w["B"].sync(target); try w["B"].sync(target)
        w.recovery = kit
        XCTAssertEqual(try w["B"].titles(), titles)
        XCTAssertEqual(try w["B"].open().readBlob(note: blobNote, blob), Data("attachment bytes for F11".utf8))
        XCTAssertEqual(ReencryptSyncTests.openWithOld(files: ReencryptSyncTests.files(target), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 on the target")
    }
}

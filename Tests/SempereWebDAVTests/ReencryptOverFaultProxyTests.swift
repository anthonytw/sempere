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
        try w["B"].sync(target); try w["A"].sync(target)
        let old = try ReencryptSyncTests.keysSoFar(w, w["A"])
        let before = Dictionary(uniqueKeysWithValues: target.paths.filter { $0.hasPrefix("notes/") && !$0.contains("/att/") }
            .compactMap { p in target.file(p).map { (p, $0) } })
        XCTAssertEqual(before.count, 3)

        let kit = try ReencryptSyncTests.start(w, home: "A", targets: [target])
        _ = try w["A"].open().reencryptPass()
        // Every replacing upload of a note file is cut in the middle of its body.
        try proxy.configure(rules: [.init(method: "PUT", path: "/\(path)/notes/.*", action: "reset", direction: "request",
                                          afterBytes: 300, times: 100)])
        let cut = try w["A"].sync(target)
        XCTAssertFalse(cut.errors.isEmpty, "the uploads were cut: \(cut)")
        let mine = try w["A"].open()
        let current = mine.identities, keys = old + current
        for (p, was) in before {
            let now = try XCTUnwrap(target.file(p), p)
            XCTAssertNotNil(try? AgeFile.decrypt(now, with: keys), "\(p): a whole copy, old or new")
            XCTAssertTrue(now == was || (try? AgeFile.decrypt(now, with: current)) != nil, "\(p): the old bytes, or the new copy")
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
        XCTAssertEqual(ReencryptSyncTests.openWithOld(files: ReencryptSyncTests.files(target), old), [], "J7 on the target")
    }
}

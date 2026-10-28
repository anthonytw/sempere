import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What only the folder transport has (docs/io.md "Folder targets"): its
/// version tokens, a hostile folder (format.md §9), the lock file, and a
/// provider's files (stand-ins, dataless files, folders listed before their
/// files, conflict versions, change hints) through `EvictingFolderProvider`.
/// What every transport must do is in `SyncRemoteConformanceTests`.
final class FolderRemoteTests: TempDirTestCase {
    private func plain() throws -> FolderRemote {
        let r = FolderRemote(root: tmp.appendingPathComponent("remote"), provider: PlainFolder())
        try r.createBase()
        return r
    }

    private func provider() throws -> (FolderRemote, EvictingFolderProvider) {
        let base = tmp.appendingPathComponent("icloud")
        let p = EvictingFolderProvider(root: base, cloud: tmp.appendingPathComponent("cloud"))
        let r = FolderRemote(root: base, provider: p)
        try r.createBase()
        return (r, p)
    }

    private func bytes(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }) }

    // MARK: Version tokens

    /// A same-size rewrite in place within one clock tick, of a file whose
    /// inode stays: the base's small files carry a digest, so it still shows.
    func testTokensFollowTheBytes() throws {
        let r = try plain()
        try r.write(["vault.json"], .data(bytes(300, 1)), condition: .create)
        let e1 = try XCTUnwrap(try r.stat(["vault.json"])?.etag)
        XCTAssertEqual(e1.split(separator: "-").count, 6, "a small file at the base carries a digest: \(e1)")
        // Another tool rewrites it in place (same inode, same size).
        let h = try FileHandle(forWritingTo: r.root.appendingPathComponent("vault.json"))
        try h.write(contentsOf: bytes(300, 2))
        try h.close()
        XCTAssertNotEqual(try r.stat(["vault.json"])?.etag, e1)
        XCTAssertEqual(try r.read(["vault.json"], maxBytes: 1000).etag, try r.stat(["vault.json"])?.etag,
                       "read and stat agree, digest included")
        // Deeper files: inode, size and times only; a replace changes the inode.
        _ = try r.makeCollection(["notes"])
        try r.write(["notes", "a.age"], .data(bytes(50, 1)), condition: .create)
        let d1 = try XCTUnwrap(try r.stat(["notes", "a.age"])?.etag)
        XCTAssertEqual(d1.split(separator: "-").count, 5, d1)
        try r.write(["notes", "a.age"], .data(bytes(50, 2)), condition: .replace(etag: d1))
        XCTAssertNotEqual(try r.stat(["notes", "a.age"])?.etag, d1)
        XCTAssertFalse(try r.write(["notes", "a.age"], .data(bytes(50, 3)), condition: .replace(etag: d1)), "a stale token")
    }

    func testFolderTokensFollowTheirChildren() throws {
        let r = try plain()
        _ = try r.makeCollection(["notes"])
        _ = try r.makeCollection(["notes", "n1"])
        let before = try XCTUnwrap(try r.list(["notes"])?.first?.etag)
        Thread.sleep(forTimeInterval: 0.01)
        try r.write(["notes", "n1", "r.age"], .data(bytes(10, 1)), condition: .create)
        XCTAssertNotEqual(try r.list(["notes"])?.first?.etag, before)
    }

    /// The lock file of conditional writes is never listed.
    func testLockFileIsHidden() throws {
        let r = try plain()
        try r.write(["settings.age"], .data(bytes(10, 1)), condition: .create)
        let e = try XCTUnwrap(try r.stat(["settings.age"])?.etag)
        XCTAssertTrue(try r.write(["settings.age"], .data(bytes(10, 2)), condition: .replace(etag: e)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.root.appendingPathComponent(FolderRemote.lockName).path))
        XCTAssertEqual(try r.list([])?.map(\.name), ["settings.age"])
        guard case .listed(let tree)? = try r.listTree([], maxBytes: 1 << 20) else { return XCTFail() }
        XCTAssertEqual(tree[[]]?.map(\.name), ["settings.age"])
    }

    /// Two writers replacing the same version at once: exactly one wins.
    func testConditionalReplaceRace() throws {
        let r = try plain()
        try r.write(["vault.json"], .data(bytes(100, 0)), condition: .create)
        let e = try XCTUnwrap(try r.stat(["vault.json"])?.etag)
        let wins = Locked(0)
        let group = DispatchGroup()
        for i in 0..<8 {
            let body = bytes(100, UInt8(i + 1))
            DispatchQueue.global().async(group: group) {
                if (try? r.write(["vault.json"], .data(body), condition: .replace(etag: e))) == true { wins.value += 1 }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(wins.value, 1)
    }

    // MARK: A hostile folder (format.md §9)

    func testSymbolicLinksAreNeverFollowedOrListed() throws {
        let r = try plain()
        let outside = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("x.age"))
        _ = try r.makeCollection(["notes"])
        let fm = FileManager.default
        try fm.createSymbolicLink(at: r.root.appendingPathComponent("notes/linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: r.root.appendingPathComponent("notes/x.age"), withDestinationURL: outside.appendingPathComponent("x.age"))
        try fm.createSymbolicLink(at: r.root.appendingPathComponent("vault.json"), withDestinationURL: outside.appendingPathComponent("x.age"))
        XCTAssertEqual(try r.list(["notes"]), [], "links are not listed")
        XCTAssertEqual(try r.list([])?.map(\.name), ["notes"])
        XCTAssertNil(try r.stat(["vault.json"]))
        XCTAssertThrowsError(try r.read(["vault.json"], maxBytes: 100)) {
            XCTAssertEqual($0 as? FolderRemoteError, .symbolicLink("/vault.json"), "\($0)")
        }
        XCTAssertThrowsError(try r.read(["notes", "linked", "x.age"], maxBytes: 100)) {
            XCTAssertEqual($0 as? FolderRemoteError, .symbolicLink("/notes/linked"), "\($0)")
        }
        XCTAssertThrowsError(try r.list(["notes", "linked"]))
        XCTAssertThrowsError(try r.write(["notes", "linked", "y.age"], .data(Data([1])), condition: .create))
        XCTAssertThrowsError(try r.write(["notes", "x.age"], .data(Data([1])), condition: .unconditional))
        XCTAssertThrowsError(try r.delete(["notes", "x.age"]))
        XCTAssertThrowsError(try r.makeCollection(["notes", "linked", "att"]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["x.age"], "nothing written outside")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("x.age")), Data("secret".utf8))
    }

    func testSpecialFilesAndBadNamesAreNotListed() throws {
        let r = try plain()
        _ = try r.makeCollection(["notes"])
        let fifo = r.root.appendingPathComponent("notes/pipe.age").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try r.write(["notes", "ok.age"], .data(Data([1])), condition: .create)
        // A name that is not UTF-8 (Linux file systems take any bytes; APFS refuses them).
        let bad: [CChar] = Array((r.root.appendingPathComponent("notes").path + "/bad-").utf8CString.dropLast()) + [CChar(bitPattern: 0xFF), 0]
        let fd = bad.withUnsafeBufferPointer { open($0.baseAddress!, O_CREAT | O_WRONLY, 0o600) }
        if fd >= 0 { close(fd) }
        XCTAssertEqual(try r.list(["notes"])?.map(\.name), ["ok.age"])
        XCTAssertThrowsError(try r.read(["notes", "pipe.age"], maxBytes: 10)) {
            XCTAssertEqual($0 as? FolderRemoteError, .notAFile("/notes/pipe.age"), "\($0)")
        }
        for badPath in [[".."], ["notes", "."], ["notes", ""], ["a/b"], ["nul\u{0}"], [String(repeating: "x", count: 300)]] {
            XCTAssertThrowsError(try r.write(badPath, .data(Data([1])), condition: .unconditional), "\(badPath)")
        }
    }

    /// A huge file is refused before it is read (a sparse 4 GiB file: nothing is allocated).
    func testHugeFilesAreBounded() throws {
        let r = try plain()
        _ = try r.makeCollection(["notes"])
        let huge = r.root.appendingPathComponent("notes/huge.age")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let h = try FileHandle(forWritingTo: huge)
        try h.truncate(atOffset: 4 << 30)
        try h.close()
        XCTAssertEqual(try r.stat(["notes", "huge.age"])?.size, 4 << 30)
        let start = Date()
        XCTAssertThrowsError(try r.read(["notes", "huge.age"], maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? FolderRemoteError, .tooLarge(path: "/notes/huge.age", limit: 1 << 20))
            XCTAssertFalse(($0 as? any TransientRemoteError)?.isTransient ?? true)
        }
        XCTAssertThrowsError(try r.download(["notes", "huge.age"], to: tmp.appendingPathComponent("part"), resumeFrom: 0,
                                            ifETag: nil, maxBytes: 1 << 20, segmentBytes: 1 << 16, progress: nil))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testListingsAreBounded() throws {
        var r = try plain()
        _ = try r.makeCollection(["notes"])
        for i in 0..<20 { try r.write(["notes", "f\(i).age"], .data(Data([1])), condition: .create) }
        r.limits.maxEntries = 10
        XCTAssertThrowsError(try r.list(["notes"])) {
            guard case FolderRemoteError.tooManyEntries = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try r.listTree([], maxBytes: 1 << 20))
    }

    // MARK: A provider's folder

    func testEvictedFilesAreListedNotDownloaded() throws {
        let (r, p) = try provider()
        _ = try r.makeCollection(["notes"])
        try r.write(["notes", "a.age"], .data(bytes(1000, 1)), condition: .create)
        try r.write(["notes", "b.age"], .data(bytes(800, 2)), condition: .create)
        try p.evict("notes/a.age", as: .dataless)
        try p.evict("notes/b.age", as: .standIn)
        let listed = try XCTUnwrap(try r.list(["notes"]))
        XCTAssertEqual(listed.map(\.name), ["a.age", "b.age"], "a stand-in is listed under its real name")
        XCTAssertEqual(listed.map(\.availability), [.remoteOnly, .remoteOnly])
        XCTAssertEqual(listed.first?.size, 1000, "a dataless file keeps its size")
        XCTAssertEqual(try r.stat(["notes", "b.age"])?.availability, .remoteOnly)
        for name in ["a.age", "b.age"] {
            XCTAssertThrowsError(try r.read(["notes", name], maxBytes: 1 << 20)) {
                XCTAssertTrue(SyncEngine.isUnavailable($0), "\($0)")
                XCTAssertTrue(($0 as? any TransientRemoteError)?.isTransient == true)
            }
        }
        p.arrivalDelay = 4
        try r.requestDownload([["notes", "a.age"], ["notes", "b.age"]])
        XCTAssertEqual(try r.stat(["notes", "a.age"])?.availability, .downloading)
        _ = try r.list(["notes"])
        XCTAssertEqual(try r.read(["notes", "a.age"], maxBytes: 1 << 20).data, bytes(1000, 1), "arrived whole")
        XCTAssertEqual(try r.read(["notes", "b.age"], maxBytes: 1 << 20).data, bytes(800, 2))
        XCTAssertEqual(try r.list(["notes"])?.map(\.name), ["a.age", "b.age"], "the stand-in is gone")
        XCTAssertGreaterThan(p.coordinatedReads, 0)
        XCTAssertGreaterThan(p.coordinatedWrites, 0)
        // A provider's stand-in name is never written.
        XCTAssertThrowsError(try r.write(["notes", ".c.age.icloud"], .data(Data([1])), condition: .create))
    }

    func testFoldersListedBeforeTheirFiles() throws {
        let (r, p) = try provider()
        _ = try r.makeCollection(["notes"])
        _ = try r.makeCollection(["notes", "n1"])
        _ = try r.makeCollection(["notes", "n2"])
        try r.write(["notes", "n1", "r.age"], .data(bytes(10, 1)), condition: .create)
        func availability(_ name: String) throws -> RemoteAvailability? {
            try r.list(["notes"])?.first { $0.name == name }?.availability
        }
        XCTAssertEqual(try availability("n1"), .available)
        XCTAssertEqual(try availability("n2"), .downloading, "an empty folder in a provider is listed before its files")
        try p.unlist("notes/n1")
        XCTAssertEqual(try r.list(["notes", "n1"]), [], "it lists empty")
        XCTAssertEqual(try availability("n1"), .remoteOnly)
        guard case .listed(let tree)? = try r.listTree(["notes"], maxBytes: 1 << 20) else { return XCTFail() }
        XCTAssertNil(tree[["n1"]], "its children are not known: no key")
        try r.requestDownload([["notes", "n1"]])
        XCTAssertEqual(try r.list(["notes", "n1"])?.map(\.name), ["r.age"])
        XCTAssertEqual(try availability("n1"), .available)
        // The base listed before its files: nothing below can be judged. Asked for; listed once it is here.
        p.arrivalDelay = 1_000
        try p.unlist("")
        XCTAssertThrowsError(try r.list([])) { XCTAssertTrue(SyncEngine.isUnavailable($0), "\($0)") }
        XCTAssertTrue(p.requested.contains(""))
        p.arrivalDelay = 0
        try r.requestDownload([[]])
        XCTAssertEqual(try r.list([])?.map(\.name).contains("notes"), true)
    }

    func testConflictVersionsAndChanges() async throws {
        let (r, p) = try provider()
        try r.write(["settings.age"], .data(bytes(10, 1)), condition: .create)
        let v = try p.addConflict("settings.age", bytes(12, 2), device: "iPad")
        XCTAssertEqual(r.conflictVersions(["settings.age"]), [v])
        XCTAssertEqual(try r.readVersion(["settings.age"], v, maxBytes: 100), bytes(12, 2))
        XCTAssertThrowsError(try r.readVersion(["settings.age"], v, maxBytes: 5))
        XCTAssertThrowsError(try r.readVersion(["settings.age"], RemoteVersion(id: "nope"), maxBytes: 100))
        try r.resolveConflicts(["settings.age"], [v])
        XCTAssertEqual(r.conflictVersions(["settings.age"]), [])

        let stream = try XCTUnwrap(r.changes())
        let got = Task { () -> RemoteChange? in
            for await c in stream { return c }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        p.announce(.paths([["notes", "n1"]]))
        let first = await got.value
        XCTAssertEqual(first, .paths([["notes", "n1"]]))
        XCTAssertNil(FolderRemote(root: tmp, provider: PlainFolder()).changes(), "a plain folder: poll")
    }

    #if canImport(Darwin)
    // MARK: Apple's hooks (on a local folder)

    func testFolderLocationClassifies() {
        let home = "/Users/x"
        XCTAssertEqual(FolderLocation.classify(URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/N.sempere"),
                                               container: home), .iCloudDrive)
        XCTAssertEqual(FolderLocation.classify(URL(fileURLWithPath: "/Users/x/Library/CloudStorage/ProtonDrive-a@b/N"),
                                               container: home), .fileProvider(name: "ProtonDrive"))
        XCTAssertEqual(FolderLocation.classify(URL(fileURLWithPath: "/Volumes/USB/N.sempere"), container: home), .other)
        XCTAssertTrue(FolderLocation.iCloudDrive.needsCoordination)
        XCTAssertFalse(FolderLocation.other.needsCoordination)
    }

    /// A local folder: plain, except for the change hints; coordinated as a provider's when classified so.
    func testUbiquitousHooksOnALocalFolder() async throws {
        let base = tmp.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let plainHooks = UbiquitousFolderHooks(root: base)
        XCTAssertFalse(plainHooks.managesFiles)
        XCTAssertFalse(plainHooks.ubiquitous)
        // As if it were another app's provider storage: every read and write coordinated (NSFileCoordinator).
        let hooks = UbiquitousFolderHooks(root: base, location: .fileProvider(name: "Test"), ubiquitous: false)
        XCTAssertTrue(hooks.managesFiles)
        let r = FolderRemote(root: base, provider: hooks)
        let stream = try XCTUnwrap(r.changes())
        let got = Task { () -> RemoteChange? in
            for await c in stream { return c }
            return nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try r.write(["vault.json"], .data(bytes(40, 1)), condition: .create)
        XCTAssertEqual(try r.read(["vault.json"], maxBytes: 100).data, bytes(40, 1))
        XCTAssertEqual(r.conflictVersions(["vault.json"]), [], "a local file has no conflict versions")
        let e = try XCTUnwrap(try r.stat(["vault.json"])?.etag)
        XCTAssertTrue(try r.write(["vault.json"], .data(bytes(40, 2)), condition: .replace(etag: e)))
        let timeout = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            got.cancel()
        }
        let change = await got.value
        timeout.cancel()
        XCTAssertNotNil(change, "the presenter heard the coordinated write")
    }
    #endif
}

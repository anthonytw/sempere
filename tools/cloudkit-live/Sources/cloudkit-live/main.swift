import CryptoKit
import Foundation
import SempereCloudKit
import SempereSync

// The real-CloudKit test driver (docs/design/1.4-cloudkit.md §10.2). A plain macOS executable that tools/cloudkit-live/run.sh puts
// in a signed bundle (the CLI's App ID and development profile) so that it may use the container; it talks to the DEVELOPMENT
// environment only (the signature says so: com.apple.developer.icloud-container-environment = Development).
//
//   cloudkit-live suite [NAME...]    the adapter and the transport against the real database, one scenario at a time
//   cloudkit-live zones [PREFIX...]  the account's zones (all, or those starting with a prefix)
//   cloudkit-live cleanup [PREFIX...] deletes the zones that start with a prefix (default: test-); prints what it deleted
//   cloudkit-live delete-zone NAME   deletes one zone (through the adapter: cktool cannot delete private zones)
//   cloudkit-live account            the account status and the hash of its user record
//   cloudkit-live cross write|verify ZONE TAG   one half of a two-platform test: files written by one process (a Mac Catalyst app, a
//                                    simulator, the Mac) and checked by another that shares only the account (run.sh catalyst|simulator|cross)
//
// Every scenario makes its own zones (`test-<uuid>`), deletes them when it ends, and prints `ok NAME` or `FAIL NAME: why`.
// Nothing here needs a push: a feed is read by asking for it, with a bounded wait for the server to show a change.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String, line: Int = #line) throws {
    if !(try condition()) { throw Failure("\(message()) (main.swift:\(line))") }
}

func note(_ s: String) { print("  \(s)"); fflush(stdout) }

/// Asks until `condition` holds (CloudKit's feeds follow a write within seconds, not instantly); fails after `seconds`.
func eventually(_ what: String, seconds: Double = 40, _ condition: () throws -> Bool) throws {
    let end = Date().addingTimeInterval(seconds)
    while true {
        if try condition() { return }
        if Date() > end { throw Failure("timed out waiting for: \(what)") }
        Thread.sleep(forTimeInterval: 1)
    }
}

func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

let scratch: URL = {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("cloudkit-live-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return u
}()

/// A file of `size` random bytes and its SHA-256, written in pieces.
func randomFile(_ name: String, size: Int) throws -> (url: URL, sha: Data) {
    let url = scratch.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var hasher = SHA256()
    var left = size
    while left > 0 {
        let n = min(left, 1 << 20)
        var piece = Data(count: n)
        piece.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        hasher.update(data: piece)
        try h.write(contentsOf: piece)
        left -= n
    }
    return (url, Data(hasher.finalize()))
}

/// One simulated device: its own adapter instance (its own kept system fields, as a process of its own would have) and its own
/// mirror on disk, on a zone.
final class Device {
    let name: String
    let store: CloudKitDatabase
    let remote: CloudRecordRemote
    let state: URL

    init(_ name: String, zone: String, layout: CloudRecordRemote.Layout = CloudRecordRemote.Layout(), state: URL? = nil) {
        self.name = name
        store = CloudKitDatabase()
        self.state = state ?? scratch.appendingPathComponent("state-\(zone)-\(name)", isDirectory: true)
        remote = CloudRecordRemote(store: store, zone: zone, stateDirectory: self.state, layout: layout)
    }

    func names(_ dir: [String]) throws -> [String] { try remote.list(dir)?.map(\.name).sorted() ?? [] }
}

struct Scenario {
    let name: String
    let run: () throws -> Void
}

var zonesMade: [String] = []
func freshZone() -> String { let z = "test-" + UUID().uuidString.lowercased(); zonesMade.append(z); return z }

let dir = ["notes", "n1"]

func smallLayout() -> CloudRecordRemote.Layout {
    var l = CloudRecordRemote.Layout()
    l.inlineLimit = 64
    l.partThreshold = 1 << 20
    l.partSize = 400 << 10
    return l
}

/// The first device: the zone made, the collections there.
func startDevice(_ name: String, zone: String, layout: CloudRecordRemote.Layout = CloudRecordRemote.Layout()) throws -> Device {
    let d = Device(name, zone: zone, layout: layout)
    try d.remote.prepareRun()
    try d.remote.createBase()
    _ = try d.remote.makeCollection(["notes"])
    _ = try d.remote.makeCollection(dir)
    return d
}

let scenarios: [Scenario] = [
    Scenario(name: "account") {
        let a = try CloudKitDatabase().account()
        try check(a.status == .available, "the account is \(a.status.rawValue)")
        try check((a.userHash ?? "").count == 64, "no user hash")
        try check(CloudKitDatabase.availability() == .available, "this process lacks the container entitlement")
    },

    Scenario(name: "zones: create twice, list, database feed, delete") {
        let db = CloudKitDatabase()
        let z = freshZone()
        var token: CloudChangeToken?
        repeat { let p = try db.fetchDatabaseChanges(since: token); token = p.token; if !p.moreComing { break } } while true
        try db.createZone(z)
        try db.createZone(z)
        try check(try db.zones().contains(z), "the new zone is not listed")
        try eventually("the database feed names the zone") {
            let p = try db.fetchDatabaseChanges(since: token)
            token = p.token
            return p.changedZones.contains(z)
        }
        try db.deleteZone(z)
        try db.deleteZone(z)   // one that is gone is fine
        try check(!(try db.zones().contains(z)), "the deleted zone is still listed")
        try eventually("the database feed names the deleted zone") {
            let p = try db.fetchDatabaseChanges(since: token)
            token = p.token
            return p.deletedZones.contains(z)
        }
    },

    Scenario(name: "records: create races, conditional replace, cold process, delete") {
        let z = freshZone()
        let a = CloudKitDatabase(), cold = CloudKitDatabase()
        try a.createZone(z)
        let name = "f-" + String(repeating: "a", count: 64)
        func save(_ s: CloudKitDatabase, _ text: String, _ p: CloudPrecondition) throws -> CloudSaveOutcome {
            let f = CloudFields(path: "x/y", sha256: sha(Data(text.utf8)), size: Int64(text.utf8.count), bytes: Data(text.utf8))
            return try s.modify(zone: z, saves: [CloudSave(name: name, kind: .file, fields: f, precondition: p)], deletes: []).saves[0]
        }
        // Eight creates of one name at once: exactly one wins.
        let results = Locked<[CloudSaveOutcome]>([])
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                let r = (try? save(CloudKitDatabase(), "v\(i)", .mustNotExist)) ?? .failed(CloudStoreError(.internalError, "threw"))
                results.mutate { $0.append(r) }
                group.leave()
            }
        }
        group.wait()
        let won = results.value.compactMap { r -> CloudRecord? in if case .saved(let rec) = r { return rec } else { return nil } }
        let lost = results.value.filter { if case .conflict = $0 { return true } else { return false } }.count
        try check(won.count == 1 && lost == 7, "creates: \(won.count) won, \(lost) lost of 8")
        let tag1 = won[0].changeTag
        // A replace under the tag the winner got: this process saved it, so no fetch is needed; a cold process has to ask first.
        guard case .saved(let r2) = try save(a, "second", .ifTag(tag1)) else { throw Failure("a replace under the current tag failed") }
        try check(r2.changeTag != tag1, "the tag did not change")
        guard case .conflict = try save(a, "stale", .ifTag(tag1)) else { throw Failure("a replace under a stale tag was accepted") }
        guard case .saved(let r3) = try save(cold, "third", .ifTag(r2.changeTag)) else { throw Failure("a cold-process replace under the current tag failed") }
        let got = try cold.fetch(zone: z, name: name, payload: true)
        try check(got?.changeTag == r3.changeTag, "fetched tag differs from the saved one")
        try check(got?.fields.bytes == Data("third".utf8), "the replace did not take")
        try check(got?.fields.path == "x/y" && got?.fields.schema == CloudSchema.current, "path or schema lost")
        guard case .saved = try save(cold, "forced", .none) else { throw Failure("an unconditional save failed") }
        guard case .conflict = try save(a, "again", .mustNotExist) else { throw Failure("a create over an existing name was accepted") }
        // Delete, and the name is free again.
        let del = try a.modify(zone: z, saves: [], deletes: [name])
        try check(del.deletes == [.deleted], "delete: \(del.deletes)")
        try check(try a.fetch(zone: z, name: name, payload: false) == nil, "a deleted record still fetches")
        guard case .saved = try save(a, "reborn", .mustNotExist) else { throw Failure("recreating a deleted name failed") }
        // A record that does not exist, replaced under a tag: a conflict, never a failure.
        let ghost = CloudSave(name: "f-" + String(repeating: "b", count: 64), kind: .file, fields: CloudFields(path: "g"), precondition: .ifTag("1"))
        guard case .conflict = try a.modify(zone: z, saves: [ghost], deletes: []).saves[0] else { throw Failure("a replace of a missing record is not a conflict") }
        try a.deleteZone(z)
    },

    Scenario(name: "convergence: two devices, one zone") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        for i in 0..<12 { try check(try a.remote.write(dir + ["rev-\(i).age"], .data(Data("A\(i)".utf8)), condition: .create), "write \(i)") }
        let b = Device("B", zone: z)
        try eventually("B lists A's twelve files") { try b.remote.prepareRun(); return try b.names(dir).count == 12 }
        for i in 0..<12 {
            let (data, etag) = try b.remote.read(dir + ["rev-\(i).age"], maxBytes: 1 << 20)
            try check(data == Data("A\(i)".utf8), "B read \(i) wrong")
            try check(etag == (try a.remote.stat(dir + ["rev-\(i).age"]))?.etag, "etags differ for \(i)")
        }
        // The other way round, and a listing of the whole tree.
        try check(try b.remote.write(dir + ["from-b.age"], .data(Data("B".utf8)), condition: .create), "B write")
        try eventually("A lists B's file") { try a.remote.prepareRun(); return try a.names(dir).contains("from-b.age") }
        guard case .listed(let tree)? = try a.remote.listTree([], maxBytes: 1 << 20) else { throw Failure("no tree") }
        try check(tree[dir]?.count == 13, "tree lists \(tree[dir]?.count ?? 0) files")
        try a.store.deleteZone(z)
    },

    Scenario(name: "conflict: create race and stale replace") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        let b = Device("B", zone: z)
        try b.remote.prepareRun()
        let path = dir + ["settings.age"]
        // Both create the same path: one wins, the other is told false.
        let outcomes = Locked<[Bool]>([])
        let group = DispatchGroup()
        for (d, text) in [(a, "from A"), (b, "from B")] {
            group.enter()
            DispatchQueue.global().async {
                outcomes.mutate { $0.append((try? d.remote.write(path, .data(Data(text.utf8)), condition: .create)) ?? false) }
                group.leave()
            }
        }
        group.wait()
        try check(outcomes.value.filter { $0 }.count == 1 && outcomes.value.count == 2, "create race: \(outcomes.value)")
        // Both read the same version, then both replace it: one wins, the other loses and sees the winner's bytes.
        try eventually("B sees the file") { try b.remote.prepareRun(); return try b.remote.stat(path) != nil }
        let etagA = try a.remote.stat(path)?.etag ?? "", etagB = try b.remote.stat(path)?.etag ?? ""
        try check(!etagA.isEmpty && etagA == etagB, "the devices see different versions (\(etagA) / \(etagB))")
        try check(try a.remote.write(path, .data(Data("A2".utf8)), condition: .replace(etag: etagA)), "A's replace failed")
        try check(try b.remote.write(path, .data(Data("B2".utf8)), condition: .replace(etag: etagB)) == false, "B's stale replace was accepted")
        let (data, _) = try b.remote.read(path, maxBytes: 1 << 20)
        try check(data == Data("A2".utf8), "the winner's bytes are not there")
        // A replace after re-reading works.
        let fresh = try b.remote.stat(path)?.etag ?? ""
        try check(fresh != etagB, "the version did not change")
        try check(try b.remote.write(path, .data(Data("B3".utf8)), condition: .replace(etag: fresh)), "B's replace after re-reading failed")
        try a.store.deleteZone(z)
    },

    Scenario(name: "delete: conditional, tombstone, recreate") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        let b = Device("B", zone: z)
        let path = dir + ["gone.age"]
        try check(try a.remote.write(path, .data(Data("one".utf8)), condition: .create), "create")
        try eventually("B sees it") { try b.remote.prepareRun(); return try b.remote.stat(path) != nil }
        let first = try a.remote.stat(path)?.etag ?? ""
        // A stale delete leaves the file, and says so.
        try check(try a.remote.write(path, .data(Data("two".utf8)), condition: .replace(etag: first)), "replace")
        try check(try b.remote.delete(path, ifETag: first) == false, "a stale delete took the file")
        try check(try b.remote.read(path, maxBytes: 100).data == Data("two".utf8), "the file changed")
        // A current delete removes it, for both.
        let current = try b.remote.stat(path)?.etag ?? ""
        try check(try b.remote.delete(path, ifETag: current), "the delete failed")
        try check(try b.remote.stat(path) == nil, "B still sees the file")
        try eventually("A no longer lists it") { try a.remote.prepareRun(); return try a.remote.stat(path) == nil }
        let name = CloudRecordNaming.fileName(path)
        let raw = try a.store.fetch(zone: z, name: name, payload: false)
        note("after the delete the record is " + (raw.map { "kept as a tombstone (tomb=\($0.fields.tomb ?? 0))" } ?? "gone"))
        try check(raw == nil || raw?.fields.tomb == 1, "the record is neither gone nor a tombstone")
        // Deleting again is fine, and the path can be created again.
        _ = try a.remote.delete(path, ifETag: nil)   // deleting what is gone is fine
        try check(try a.remote.write(path, .data(Data("three".utf8)), condition: .create), "recreating the path failed")
        try eventually("B sees it again") { try b.remote.prepareRun(); return try b.remote.stat(path) != nil }
        try check(try b.remote.read(path, maxBytes: 100).data == Data("three".utf8), "B reads the old bytes")
        // Many deletes at once go through one request each (the sweep batches them).
        for i in 0..<10 { try check(try a.remote.write(dir + ["m\(i).age"], .data(Data("m".utf8)), condition: .create), "m\(i)") }
        for i in 0..<10 { _ = try a.remote.delete(dir + ["m\(i).age"], ifETag: nil) }
        try eventually("B sees only gone.age") { try b.remote.prepareRun(); return try b.names(dir) == ["gone.age"] }
        try a.store.deleteZone(z)
    },

    Scenario(name: "parts: a file over the threshold is split and comes back whole (small layout)") {
        let z = freshZone()
        let layout = smallLayout()
        let a = try startDevice("A", zone: z, layout: layout)
        let b = Device("B", zone: z, layout: layout)
        let (file, digest) = try randomFile("parts-small.bin", size: 3 * (1 << 20) + 12345)
        let path = dir + ["big.bin"]
        try check(try a.remote.write(path, .file(file), condition: .create), "the upload failed")
        let rec = try a.store.fetch(zone: z, name: CloudRecordNaming.fileName(path), payload: false)
        let expected = Int64((3 * (1 << 20) + 12345 + layout.partSize - 1) / layout.partSize)
        try check(rec?.fields.parts == expected, "the record says \(rec?.fields.parts ?? -1) parts, expected \(expected)")
        try check(rec?.fields.assetSize == nil, "a split file also carries a whole asset")
        try eventually("B sees the big file") { try b.remote.prepareRun(); return try b.remote.stat(path) != nil }
        let out = scratch.appendingPathComponent("parts-small.out")
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        try b.remote.download(path, to: out, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 30, segmentBytes: 1 << 20, progress: nil)
        try check(sha(try Data(contentsOf: out)) == digest, "the downloaded bytes differ")
        // A replace by another file of another size leaves no old part visible.
        let (file2, digest2) = try randomFile("parts-small2.bin", size: 1_500_000)
        let etag = try a.remote.stat(path)?.etag ?? ""
        try check(try a.remote.write(path, .file(file2), condition: .replace(etag: etag)), "the replace failed")
        try eventually("B sees the new version") { try b.remote.prepareRun(); return try b.remote.stat(path)?.size == 1_500_000 }
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        try b.remote.download(path, to: out, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 30, segmentBytes: 1 << 20, progress: nil)
        try check(sha(try Data(contentsOf: out)) == digest2, "the replaced file's bytes differ")
        try a.store.deleteZone(z)
    },

    Scenario(name: "parts: a 70 MiB file with the real layout (64 MiB threshold, 16 MiB parts)") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        let b = Device("B", zone: z)
        let size = 70 << 20
        let (file, digest) = try randomFile("parts-real.bin", size: size)
        let path = dir + ["huge.bin"]
        let t0 = Date()
        try check(try a.remote.write(path, .file(file), condition: .create), "the upload failed")
        note(String(format: "uploaded 70 MiB in %.1f s", Date().timeIntervalSince(t0)))
        let rec = try a.store.fetch(zone: z, name: CloudRecordNaming.fileName(path), payload: false)
        try check(rec?.fields.parts == 5, "70 MiB in 16 MiB parts should be 5 parts, the record says \(rec?.fields.parts ?? -1)")
        try eventually("B sees it") { try b.remote.prepareRun(); return try b.remote.stat(path)?.size == size }
        let out = scratch.appendingPathComponent("parts-real.out")
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let t1 = Date()
        try b.remote.download(path, to: out, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 31, segmentBytes: 1 << 20, progress: nil)
        note(String(format: "downloaded in %.1f s", Date().timeIntervalSince(t1)))
        let (_, got) = try { () -> (Int, Data) in
            var h = SHA256(); var n = 0
            let r = try FileHandle(forReadingFrom: out); defer { try? r.close() }
            while let p = try r.read(upToCount: 1 << 20), !p.isEmpty { h.update(data: p); n += p.count }
            return (n, Data(h.finalize()))
        }()
        try check(got == digest, "the downloaded 70 MiB differ")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: out)
        try a.store.deleteZone(z)
    },

    Scenario(name: "zone deleted under a device: zoneNotFound, then recreated") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        let b = Device("B", zone: z)
        let path = dir + ["x.age"]
        try check(try a.remote.write(path, .data(Data("x".utf8)), condition: .create), "create")
        try eventually("B sees it") { try b.remote.prepareRun(); return try b.remote.stat(path) != nil }
        // The zone goes away (what iCloud settings "Delete Data" does; here through the adapter, from a third process's view).
        try CloudKitDatabase().deleteZone(z)
        var code = ""
        do { _ = try a.remote.write(dir + ["y.age"], .data(Data("y".utf8)), condition: .create); throw Failure("a write into a deleted zone worked") }
        catch let e as CloudRecordError {
            guard case .zoneGone(let userDeleted) = e else { throw Failure("a write into a deleted zone gave \(e)") }
            code = userDeleted ? "userDeletedZone" : "zoneNotFound"
        }
        note("the transport saw: \(code)")
        // The reader's run does not fail: it holds nothing, and says the base is gone.
        try b.remote.prepareRun()
        try check(try b.remote.list([]) == nil, "B still lists a deleted zone")
        try check(try b.remote.stat(path) == nil, "B still sees a file of a deleted zone")
        // Choosing to upload again makes the zone and the files again.
        a.remote.acknowledgeDeletedZone()
        try a.remote.prepareRun()
        try a.remote.createBase()
        _ = try a.remote.makeCollection(["notes"]); _ = try a.remote.makeCollection(dir)
        try check(try a.remote.write(path, .data(Data("again".utf8)), condition: .create), "the upload into the new zone failed")
        let c = Device("C", zone: z)
        try eventually("a fresh device sees the new zone") { try c.remote.prepareRun(); return try c.remote.stat(path) != nil }
        try a.store.deleteZone(z)
    },

    Scenario(name: "change tokens: round trip, quiet feed, a token from another process, a mirror kept on disk") {
        let z = freshZone()
        let a = try startDevice("A", zone: z)
        for i in 0..<5 { try check(try a.remote.write(dir + ["t\(i).age"], .data(Data("t".utf8)), condition: .create), "write") }
        let db = CloudKitDatabase()
        var token: CloudChangeToken?
        var seen = Set<String>()
        try eventually("the feed shows the five files") {
            repeat {
                let p = try db.fetchChanges(zone: z, since: token)
                token = p.token
                for r in p.changed { if let path = r.fields.path { seen.insert(path) } }
                if !p.moreComing { break }
            } while true
            return seen.count >= 5
        }
        let t1 = try check2(token)
        // Nothing changed: an empty page and the same token.
        let quiet = try db.fetchChanges(zone: z, since: t1)
        try check(quiet.changed.isEmpty && quiet.deleted.isEmpty && !quiet.moreComing, "a quiet feed returned \(quiet.changed.count) records")
        note("token \(t1.data.count) bytes; unchanged after a quiet read: \(quiet.token == t1)")
        // The token as bytes, in another adapter instance (what the mirror file does between runs).
        let revived = try check2(CloudChangeToken(t1.data))
        try check(try a.remote.write(dir + ["t5.age"], .data(Data("t".utf8)), condition: .create), "write 6")
        var after: CloudZoneChanges?
        try eventually("another instance sees the sixth file from the old token") {
            let p = try CloudKitDatabase().fetchChanges(zone: z, since: revived)
            if p.changed.contains(where: { $0.fields.path == dir.joined(separator: "/") + "/t5.age" }) { after = p; return true }
            return false
        }
        try check(after!.changed.filter { $0.fields.path?.hasSuffix(".age") == true }.count == 1, "the feed repeated records the token had passed")
        // A mirror on disk: a new process starts from its token, with no full fetch.
        let b1 = Device("B", zone: z)
        try eventually("B lists six files") { try b1.remote.prepareRun(); return try b1.names(dir).count == 6 }
        try check(b1.remote.diagnostics.fullFetches == 1, "the first run fetched the zone \(b1.remote.diagnostics.fullFetches) times")
        let b2 = Device("B", zone: z, state: b1.state)
        try b2.remote.prepareRun()
        try check(b2.remote.diagnostics.fullFetches == 0, "a second process fetched the whole zone again")
        try check(try b2.names(dir).count == 6, "the second process lost the mirror")
        try check(try a.remote.write(dir + ["t6.age"], .data(Data("t".utf8)), condition: .create), "write 7")
        try eventually("the second process sees the seventh file") { try b2.remote.prepareRun(); return try b2.names(dir).count == 7 }
        try check(b2.remote.diagnostics.fullFetches == 0, "following the token needed a full fetch")
        try a.store.deleteZone(z)
    },
]

func check2<T>(_ v: T?, line: Int = #line) throws -> T {
    guard let v else { throw Failure("a value was nil (main.swift:\(line))") }
    return v
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&v); lock.unlock() }
}

// MARK: Two platforms, one zone

/// What `cross write ZONE TAG` leaves for `cross verify ZONE TAG` (another process, maybe another platform): ten small files, a file
/// over the (small) part threshold and the digest of it, all conditional creates.
func crossWrite(zone: String, tag: String) throws {
    let d = Device("w-\(tag)", zone: zone, layout: smallLayout())
    try d.remote.prepareRun()
    try d.remote.createBase()
    _ = try d.remote.makeCollection(["notes"]); _ = try d.remote.makeCollection(dir)
    for i in 0..<10 { try check(try d.remote.write(dir + ["\(tag)-\(i).age"], .data(Data("\(tag)\(i)".utf8)), condition: .create), "write \(i)") }
    let (file, digest) = try randomFile("cross-\(tag).bin", size: 2_600_000)
    try check(try d.remote.write(dir + ["\(tag)-big.bin"], .file(file), condition: .create), "write big")
    try check(try d.remote.write(dir + ["\(tag)-big.sha"], .data(Data(digest.map { String(format: "%02x", $0) }.joined().utf8)), condition: .create), "write digest")
    print("wrote \(tag) from \(platform)")
}

func crossVerify(zone: String, tag: String) throws {
    let d = Device("v-\(tag)", zone: zone, layout: smallLayout())
    try eventually("\(tag)'s files arrive") { try d.remote.prepareRun(); return try d.names(dir).filter { $0.hasPrefix(tag + "-") }.count == 12 }
    for i in 0..<10 { try check(try d.remote.read(dir + ["\(tag)-\(i).age"], maxBytes: 1 << 20).data == Data("\(tag)\(i)".utf8), "file \(i) differs") }
    let want = String(decoding: try d.remote.read(dir + ["\(tag)-big.sha"], maxBytes: 1000).data, as: UTF8.self)
    let out = scratch.appendingPathComponent("cross-\(tag).out")
    try? FileManager.default.removeItem(at: out)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    try d.remote.download(dir + ["\(tag)-big.bin"], to: out, resumeFrom: 0, ifETag: nil, maxBytes: 1 << 30, segmentBytes: 1 << 20, progress: nil)
    let got = sha(try Data(contentsOf: out)).map { String(format: "%02x", $0) }.joined()
    try check(got == want, "the big file differs")
    print("verified \(tag) on \(platform)")
}

var platform: String {
    #if targetEnvironment(macCatalyst)
    return "Mac Catalyst"
    #elseif targetEnvironment(simulator)
    return "the iOS simulator"
    #else
    return "macOS"
    #endif
}

// MARK: Commands

func zonesWith(_ prefixes: [String]) throws -> [String] {
    try CloudKitDatabase().zones().filter { z in prefixes.isEmpty || prefixes.contains { z.hasPrefix($0) } }.sorted()
}

func deleteZones(_ names: [String]) -> Int {
    let db = CloudKitDatabase()
    var n = 0
    for z in names {
        do { try db.deleteZone(z); n += 1 } catch { print("could not delete \(z): \(error)") }
    }
    return n
}

// A Mac Catalyst app or a simulator process started through LaunchServices or `simctl` has no terminal and no exit status that
// reaches the script: CKL_OUT names the file its output goes to, CKL_ARGS holds the command line (split at `|`).
if let out = ProcessInfo.processInfo.environment["CKL_OUT"] {
    freopen(out, "w", stdout)
    freopen(out, "a", stderr)
}
setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
if let line = ProcessInfo.processInfo.environment["CKL_ARGS"] { args = line.split(separator: "|").map(String.init) }
guard CloudKitDatabase.availability() == .available else {
    print("this process is not signed for the iCloud container (run it through tools/cloudkit-live/run.sh)")
    exit(2)
}
let command = args.isEmpty ? "suite" : args.removeFirst()
switch command {
case "account":
    let a = try CloudKitDatabase().account()
    print("\(a.status.rawValue) \(a.userHash ?? "-")")
case "zones":
    for z in try zonesWith(args) { print(z) }
case "cleanup":
    let prefixes = args.isEmpty ? ["test-"] : args
    let found = try zonesWith(prefixes)
    let n = deleteZones(found)
    print("deleted \(n) of \(found.count) zones (prefixes: \(prefixes.joined(separator: ", ")))")
    exit(n == found.count ? 0 : 1)
case "delete-zone":
    guard let z = args.first else { print("usage: cloudkit-live delete-zone NAME"); exit(2) }
    try CloudKitDatabase().deleteZone(z)
case "cross":
    guard args.count == 3, ["write", "verify"].contains(args[0]) else { print("usage: cloudkit-live cross write|verify ZONE TAG"); exit(2) }
    do {
        if args[0] == "write" { try crossWrite(zone: args[1], tag: args[2]) } else { try crossVerify(zone: args[1], tag: args[2]) }
    } catch { print("FAIL cross \(args[0]) \(args[2]): \(error)"); exit(1) }
case "suite":
    let chosen = scenarios.filter { s in args.isEmpty || args.contains { s.name.hasPrefix($0) } }
    guard !chosen.isEmpty else { print("no scenario matches \(args)"); exit(2) }
    var failed = 0
    for s in chosen {
        print("run \(s.name)")
        let t0 = Date()
        do {
            try s.run()
            print(String(format: "ok  %@ (%.1f s)", s.name, Date().timeIntervalSince(t0)))
        } catch {
            failed += 1
            print("FAIL \(s.name): \(error)")
        }
    }
    // What the scenarios could not delete themselves (a failed one stops before its own delete).
    let left = zonesMade
    let db = CloudKitDatabase()
    var gone = 0
    for z in left { if (try? db.zones().contains(z)) == true { if (try? db.deleteZone(z)) != nil { gone += 1 } } }
    if gone > 0 { print("cleaned up \(gone) zones left by failed scenarios") }
    try? FileManager.default.removeItem(at: scratch)
    print(failed == 0 ? "all \(chosen.count) scenarios passed" : "\(failed) of \(chosen.count) scenarios FAILED")
    exit(failed == 0 ? 0 : 1)
default:
    print("usage: cloudkit-live suite [NAME...] | zones [PREFIX...] | cleanup [PREFIX...] | delete-zone NAME | account")
    exit(2)
}

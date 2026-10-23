import Age
import Foundation
import TempDirSupport
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// N devices on one or two remotes (docs/ci.md "Sync stress",
/// docs/design/device-first-sync.md §9 "Multi-device"): three or more
/// devices, each with its own key, clock (virtual, skewed) and sync state per
/// remote, make random edits (new notes, renames, tags, attachments, deletes,
/// thinning, shared settings) and sync in random order with a random remote
/// they use (several bridges: see `StressWorld.manyBridges`), through injected faults: requests dropped, refused, applied with
/// the answer lost, cut midway, and, on in-memory remotes, a hostile server
/// (wrong bytes, listings that drop or invent entries or misreport sizes,
/// version tokens that change underneath; on note files and on `vault.json`). The first device
/// uses every remote (a bridge); the others a random subset, so two devices often bridge the same
/// two remotes. A second remote is either
/// another `MemoryRemote` or the WebDAV mock (mixed targets).
///
/// Invariants, checked as it goes and at the end:
/// - no write-once file is ever altered: every note file on any device or
///   remote holds the bytes its writer wrote, and nothing unwritten appears;
/// - nothing is lost: every attachment and revision written is on every
///   device and remote, or (thinned or compacted) the note reads the same
///   with every one of them put back;
/// - quarantine never deletes or replaces: every file that ever appeared in a
///   quarantine folder is still there with the same bytes;
/// - with faults off, a few rounds converge: every device and remote holds
///   the same note files, nothing is left in flight, every device reads the
///   same notes and settings, and no conflict copy was made.
///
/// Seeded: a failing seed replays with `SEMPERE_SYNC_STRESS_SEED=N` (fault
/// decisions depend on the seed, the operation and its path, not on thread
/// timing; the vault's random keys can still reorder attachment names).
/// Quick mode (3 seeds of 90 steps, 3 devices, a few seconds) runs in every
/// `swift test`; `SEMPERE_SYNC_STRESS_LONG=1` runs `SEMPERE_SYNC_STRESS_SEEDS`
/// (60) seeds of 300 steps with 3 to 5 devices and simultaneous runs
/// (`scripts/sync-stress.sh`).
final class NDeviceStressTests: TempDirTestCase {
    struct Mode {
        var seeds: [UInt64]
        var devices: ClosedRange<Int>
        var steps: Int
        var simultaneous: Bool
    }

    static var mode: Mode {
        let env = ProcessInfo.processInfo.environment
        let long = env["SEMPERE_SYNC_STRESS_LONG"] == "1"
        var seeds: [UInt64] = long ? Array(1...max(env["SEMPERE_SYNC_STRESS_SEEDS"].flatMap(UInt64.init) ?? 60, 1)) : [1, 2, 3]
        if let one = env["SEMPERE_SYNC_STRESS_SEED"].flatMap(UInt64.init) { seeds = [one] }
        return long ? Mode(seeds: seeds, devices: 3...5, steps: 300, simultaneous: true)
            : Mode(seeds: seeds, devices: 3...3, steps: 90, simultaneous: false)
    }

    func testDevicesConvergeAndLoseNothing() throws {
        let mode = Self.mode
        for seed in mode.seeds {
            let start = Date()
            let world = try StressWorld(seed: seed, root: tmp.appendingPathComponent("seed-\(seed)"), mode: mode)
            try world.run()
            print("NDEVICE seed \(seed): \(world.summary), \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
    }

    /// Found by this run: two remotes holding the same shared settings sealed
    /// twice (different bytes: two devices merged the same change) made a
    /// device that syncs with both download one copy, then the other, on
    /// every run, never quiet. The same settings are nothing to transfer.
    func testABridgeSettlesSettingsSealedTwice() throws {
        let r0 = MemoryRemote(store: MemoryStore(name: "R0"), base: ["vault"])
        let r1 = MemoryRemote(store: MemoryStore(name: "R1"), base: ["vault"])
        let a = try SyncDevice(name: "A", root: tmp.appendingPathComponent("A"), identity: pqIdentity(), remote: r0,
                               device: DeviceID("aaaaaaaa"))
        _ = try TestVaults.create(at: a.folder, identities: [a.identity], names: ["A"])
        let v = try a.vault()
        var s = SharedSettings()
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: a.now)
        try v.writeSharedSettings(s)
        let s0 = a.root.appendingPathComponent("sync-R0.json"), s1 = a.root.appendingPathComponent("sync-R1.json")
        try a.sync(via: r0, state: s0); try a.sync(via: r1, state: s1)
        // Another device sealed the same settings again and put them on R1.
        let again = try v.sealSharedSettings(try XCTUnwrap(try v.readSharedSettings()))
        try r1.write([SharedSettings.fileName], .data(again), condition: .unconditional)
        XCTAssertNotEqual(again, r0.store.file(["vault", SharedSettings.fileName]))
        for _ in 0..<2 {
            let x = try a.sync(via: r0, state: s0), y = try a.sync(via: r1, state: s1)
            XCTAssertTrue(x.isEmpty && y.isEmpty, "R0: \(StressWorld.brief(x)); R1: \(StressWorld.brief(y))")
        }
        XCTAssertEqual(try a.vault().readSharedSettings(), s)
    }

    /// Found by this run with two bridges (docs/design/device-first-sync.md §5.4): devices X and Y
    /// both sync remotes R0 and R1. X thinned a note and deleted the thinned deltas from R0, then
    /// had them again from R1 (as a download from R1 brings them back); Y still holds them, in
    /// step with both remotes. Each run then undid another: Y deleted them (R0 dropped them),
    /// X uploaded them to R0 again (new there, as far as its R0 state remembered), Y fetched them
    /// from R0 and gave them to R1, X deleted them... never quiet. A deletion settled as
    /// thinning is remembered (`SyncState.thinned`), so a copy that comes back is deleted again.
    func testTwoBridgesSettleAThinnedDelta() throws {
        let store0 = MemoryStore(name: "R0"), store1 = MemoryStore(name: "R1")
        let r0 = MemoryRemote(store: store0, base: ["vault"]), r1 = MemoryRemote(store: store1, base: ["vault"])
        let ids = [pqIdentity(), pqIdentity()]
        let x = try SyncDevice(name: "X", root: tmp.appendingPathComponent("X"), identity: ids[0], remote: r0,
                               device: DeviceID("aaaaaaaa"))
        let y = try SyncDevice(name: "Y", root: tmp.appendingPathComponent("Y"), identity: ids[1], remote: r0,
                               device: DeviceID("bbbbbbbb"))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tick = Locked(0)
        for d in [x, y] { d.clock = { start.addingTimeInterval(Double(tick.value * 60)) } }
        _ = try TestVaults.create(at: x.folder, identities: ids, names: ["X", "Y"])
        let runs: [(SyncDevice, MemoryRemote, String)] = [(y, r0, "R0"), (y, r1, "R1"), (x, r0, "R0"), (x, r1, "R1")]
        func round() throws -> [String] {
            try runs.compactMap { d, r, name in
                let rep = try d.sync(via: r, state: d.root.appendingPathComponent("sync-\(name).json"))
                return rep.isEmpty ? nil : "\(d.name)/\(name): \(StressWorld.brief(rep))"
            }
        }
        let id = UUID(uuidString: "0b5e55ed-0000-4000-8000-000000000001")!
        try x.newNote("one", id: id)
        for i in 2...6 { tick.value = i; try x.rename(id, "title \(i)") }
        for _ in 0..<4 { _ = try round() }
        XCTAssertEqual(try round(), [], "in step before thinning")

        tick.value = 100
        let thinned = try x.thin(id)
        XCTAssertFalse(thinned.isEmpty, "thinning deleted nothing")
        let files = try thinned.map { n -> (String, Data) in
            let p = "notes/\(id.uuidString.lowercased())/\(n.filename)"
            return (p, try Data(contentsOf: y.folder.appendingPathComponent(p)))
        }
        try x.sync(via: r0, state: x.root.appendingPathComponent("sync-R0.json"))
        // X has them again, as a download from R1 (whose X state records them) would bring them.
        for (p, data) in files { try data.write(to: x.folder.appendingPathComponent(p)) }

        var last: [String] = []
        var quiet = false
        for _ in 0..<6 where !quiet {
            last = try round()
            quiet = last.isEmpty
        }
        XCTAssertTrue(quiet, "never quiet: \(last.joined(separator: "\n"))")
        for (p, _) in files {
            XCTAssertFalse(x.noteFiles().contains(p) || y.noteFiles().contains(p), "\(p) is back on a device")
            for store in [store0, store1] { XCTAssertNil(store.file(["vault"] + p.split(separator: "/").map(String.init)), p) }
        }
        XCTAssertEqual(x.noteFiles(), y.noteFiles())
        XCTAssertEqual(try x.vault().reconstruct(noteId: id), try y.vault().reconstruct(noteId: id))
        XCTAssertEqual(try x.vault().reconstruct(noteId: id).meta.title, "title 6")
    }

    /// Found by this run (seeds 41 and 46, long mode): A and B bridge R0 and R1, C syncs R0 only. C
    /// wrote its summaries file twice in a row (c2, then c3) with one run on R0 between. Merged by "the
    /// side that changed since the last run wins", c2 and c3 then circled R0 → B → R1 → A → R0 for ever:
    /// each bridge saw one copy changed on one side only and carried it on, and only R0 was ever put right
    /// by C. A per-device file carries its writer's version inside the sealed content, and a copy only
    /// ever replaces an older one.
    func testTwoBridgesSettleAnotherDevicesSummaries() throws {
        let r0 = MemoryRemote(store: MemoryStore(name: "R0"), base: ["vault"])
        let r1 = MemoryRemote(store: MemoryStore(name: "R1"), base: ["vault"])
        let ids = [pqIdentity(), pqIdentity(), pqIdentity()]
        let a = try SyncDevice(name: "A", root: tmp.appendingPathComponent("A"), identity: ids[0], remote: r0,
                               device: DeviceID("aaaaaaaa"))
        let b = try SyncDevice(name: "B", root: tmp.appendingPathComponent("B"), identity: ids[1], remote: r0,
                               device: DeviceID("bbbbbbbb"))
        let c = try SyncDevice(name: "C", root: tmp.appendingPathComponent("C"), identity: ids[2], remote: r0,
                               device: DeviceID("cccccccc"))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tick = Locked(0)
        for d in [a, b, c] { d.clock = { start.addingTimeInterval(Double(tick.value * 60)) } }
        _ = try TestVaults.create(at: a.folder, identities: ids, names: ["A", "B", "C"])
        func sync(_ d: SyncDevice, _ r: MemoryRemote, _ name: String) throws -> SyncReport {
            try d.sync(via: r, state: d.root.appendingPathComponent("sync-\(name).json"))
        }
        let runs: [(SyncDevice, MemoryRemote, String)] = [(a, r0, "R0"), (a, r1, "R1"), (c, r0, "R0"), (b, r0, "R0"), (b, r1, "R1")]
        func round() throws -> [String] {
            try runs.compactMap { d, r, name in
                let rep = try sync(d, r, name)
                return rep.isEmpty ? nil : "\(d.name)/\(name): \(StressWorld.brief(rep))"
            }
        }
        try a.newNote("one")
        for _ in 0..<3 { _ = try round() }
        tick.value = 1
        _ = try c.publishSummaries()
        for _ in 0..<3 { _ = try round() }
        XCTAssertEqual(try round(), [], "in step with C's first file")

        tick.value = 2
        _ = try c.publishSummaries()
        _ = try sync(c, r0, "R0")
        tick.value = 3
        let latest = try c.publishSummaries()

        var last: [String] = []
        var quiet = false
        for _ in 0..<6 where !quiet {
            last = try round()
            quiet = last.isEmpty
        }
        XCTAssertTrue(quiet, "never quiet: \(last.joined(separator: "\n"))")
        let name = PublishedSummaries.deviceFileName(c.device)
        for d in [a, b, c] { XCTAssertEqual(d.rootFolderFiles(PublishedSummaries.deviceFolderName)[name], latest, d.name) }
        for r in [r0, r1] {
            XCTAssertEqual(try r.read([PublishedSummaries.deviceFolderName, name], maxBytes: 1 << 26).data, latest, r.location)
        }
    }
}

/// One remote of the stress run and how each device reaches it.
final class StressTarget {
    let name: String
    let inspector: any SyncRemote
    /// A device's way in: its remote (seeded faults), a switch for the faults, and how many were injected.
    let connect: (UInt64) -> StressLink.Endpoint

    init(name: String, inspector: any SyncRemote, connect: @escaping (UInt64) -> StressLink.Endpoint) {
        self.name = name
        self.inspector = inspector
        self.connect = connect
    }

    static let transportRate = 0.04
    static let hostileRate = 0.02

    static func memory(_ name: String) -> StressTarget {
        let store = MemoryStore(name: name)
        let remote = MemoryRemote(store: store, base: ["vault"])
        return StressTarget(name: name, inspector: remote) { seed in
            let faults = MemoryFaults(seed: seed)
            faults.keepLog = false
            // A hostile server's answers about note files and `vault.json`. The other mutable
            // files at the root have their own suites: a changed answer about `settings.age`
            // is merged or reported, one about the rewrap journal judged under §3.3.1.
            faults.eligible = { kind, _, path in
                MemoryFaults.Kind.transport.contains(kind) || path.first == Vault.notesName || path == [Vault.manifestName]
                    || path.first == CaptureFile.folderName || path.first == PublishedSummaries.deviceFolderName
            }
            var rates = MemoryFaults.Rates.transport(transportRate)
            for k in MemoryFaults.Kind.hostile { rates[k] = hostileRate }
            return StressLink.Endpoint(remote: remote.with(faults: faults),
                                       setFaults: { faults.rates = $0 ? rates : .none }, injected: { faults.injected })
        }
    }

    /// A plain folder (`FolderRemote`), with transport faults (`FaultyRemote`): a share that drops,
    /// refuses, loses answers and cuts copies midway.
    static func folder(_ name: String, root: URL) -> StressTarget {
        let remote = FolderRemote(root: root, provider: PlainFolder())
        return StressTarget(name: name, inspector: remote) { seed in
            let on = Locked(false)
            let faulty = FaultyRemote(remote, seed: seed, faults: .all(transportRate))
            let switched = SwitchedRemote(plain: remote, faulty: faulty, on: on)
            return StressLink.Endpoint(remote: switched, setFaults: { on.value = $0 }, injected: { Int(faulty.injected.value) })
        }
    }

    static func webDAVMock(_ name: String, deepETags: Bool) -> StressTarget {
        let server = MockDAV()
        server.collectionETags = deepETags ? .deep : .none
        server.depthInfinity = deepETags ? .full : .depthZero
        let url = URL(string: "https://dav.example.com\(MockDAV.base)/")!
        let inspector = WebDAVSyncRemote(try! WebDAVClient(baseURL: url, transport: server))
        return StressTarget(name: name, inspector: inspector) { seed in
            let t = FaultyTransport(server, seed: seed)
            return StressLink.Endpoint(remote: WebDAVSyncRemote(try! WebDAVClient(baseURL: url, transport: t)),
                                       setFaults: { t.rates = $0 ? .all(transportRate) : .none },
                                       injected: { t.faults.values.reduce(0, +) })
        }
    }
}

/// A device's use of one target.
struct StressLink {
    struct Endpoint {
        var remote: any SyncRemote
        var setFaults: (Bool) -> Void
        var injected: () -> Int
    }
    let target: StressTarget
    let endpoint: Endpoint
    let state: URL
}

/// One seeded run (see `NDeviceStressTests`).
final class StressWorld {
    let seed: UInt64
    let root: URL
    let mode: NDeviceStressTests.Mode
    private var rng: SeededRNG
    private(set) var targets: [StressTarget] = []
    private(set) var devices: [SyncDevice] = []
    private(set) var links: [[StressLink]] = []
    /// Every write-once file written, by vault path, as its writer wrote it.
    private var written: [String: Data] = [:]
    /// Further bytes written at a blob path by another device (`recordWrites`).
    private var alsoWritten: [String: Set<Data>] = [:]
    /// Every file seen in a quarantine folder, with its bytes' SHA-256.
    private var quarantined: [URL: String] = [:]
    private let tick = Locked(0)
    private var counts: [String: Int] = [:]
    /// Every capture recorded, and each device's own summaries file as it last wrote it.
    private var captures = Set<UUID>()
    private var published: [String: Data] = [:]
    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    /// Whether devices other than the first may bridge both remotes (the default; each one
    /// does with a chance of one half): two devices that both sync iCloud and WebDAV are the
    /// expected setup. With two bridges on the same two remotes, a delta that thinning made
    /// deletable used to circle for ever (one bridge deleted it from a remote while the other
    /// uploaded it there again from the other remote); the engine now settles it
    /// (`SyncState.thinned`, docs/design/device-first-sync.md §5.4).
    /// `SEMPERE_SYNC_STRESS_BRIDGES=one` keeps the other devices on one remote each.
    static var manyBridges: Bool { ProcessInfo.processInfo.environment["SEMPERE_SYNC_STRESS_BRIDGES"] != "one" }

    init(seed: UInt64, root: URL, mode: NDeviceStressTests.Mode) throws {
        self.seed = seed
        self.root = root
        self.mode = mode
        rng = SeededRNG(seed)
        let deviceCount = mode.devices.lowerBound + Int(rng.next() % UInt64(mode.devices.count))
        // Seeds take turns: one remote; two in-memory ones; in-memory and the WebDAV mock. Every
        // fourth seed's first remote is a folder (`FolderRemote`) instead of an in-memory store.
        targets = [seed % 4 == 3 ? .folder("R0", root: root.appendingPathComponent("R0-folder")) : .memory("R0")]
        switch seed % 3 {
        case 1: targets.append(.memory("R1"))
        case 2: targets.append(.webDAVMock("R1", deepETags: rng.next() % 2 == 0))
        default: break
        }
        let tick = self.tick
        for i in 0..<deviceCount {
            let name = String(UnicodeScalar(UInt8(65 + i)))
            let hex = String(repeating: String(UnicodeScalar(UInt8(97 + i))), count: 8)
            // The first device bridges every target; each other one a random non-empty subset, so
            // two devices often bridge both (or, with `SEMPERE_SYNC_STRESS_BRIDGES=one`, one of them).
            var mine = targets.indices.filter { _ in i == 0 || (Self.manyBridges && rng.next() % 2 == 0) }
            if mine.isEmpty { mine = [Int(rng.next() % UInt64(targets.count))] }
            let deviceLinks = mine.map { ti in
                StressLink(target: targets[ti], endpoint: targets[ti].connect(seed &* 1_000_003 &+ UInt64(i * 31 + ti)),
                           state: root.appendingPathComponent(name).appendingPathComponent("sync-\(targets[ti].name).json"))
            }
            let d = try SyncDevice(name: name, root: root.appendingPathComponent(name), identity: pqIdentity(),
                                   remote: deviceLinks[0].endpoint.remote, device: DeviceID(hex))
            d.clock = { StressWorld.epoch.addingTimeInterval(Double(tick.value)) }
            d.skew = Double(Int(rng.next() % 7200) - 3600)
            devices.append(d)
            links.append(deviceLinks)
        }
    }

    var summary: String {
        let injected = links.joined().map { $0.endpoint.injected() }.reduce(0, +)
        let kinds = targets.map { $0.inspector is MemoryRemote ? "memory" : $0.inspector is FolderRemote ? "folder" : "webdav-mock" }
        let ops = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(devices.count) devices on \(targets.count) remotes (\(kinds.joined(separator: ", "))), "
            + "\(written.count) files written, \(injected) faults, \(quarantined.count) quarantined; \(ops)"
    }

    private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTFail("seed \(seed): \(message)", file: file, line: line)
    }

    private func seededUUID() -> UUID {
        var b = (0..<16).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func pick<T>(_ xs: [T]) -> T? { xs.isEmpty ? nil : xs[Int(rng.next() % UInt64(xs.count))] }

    // MARK: Invariants

    /// `d`'s note files, without the hidden ones (downloads in progress, kept for the next run).
    private func files(_ d: SyncDevice) -> Set<String> {
        d.noteFiles().filter { !($0.split(separator: "/").last ?? "").hasPrefix(".") }
    }

    /// Records the files a local edit on `d` wrote.
    private func recordWrites(_ d: SyncDevice) {
        for p in files(d) {
            guard let data = try? Data(contentsOf: d.folder.appendingPathComponent(p)) else { continue }
            guard let first = written[p] else { written[p] = data; continue }
            // Two devices adopting one capture each write its audio under the same keyed name (format.md §11.3):
            // the same content, encrypted twice. Neither copy replaces the other; both are the writers' bytes.
            if first != data, p.split(separator: "/").dropLast().last == Substring(Vault.attachmentsName) {
                alsoWritten[p, default: []].insert(data)
            }
        }
    }

    /// Whether `data` is what some device wrote at `p`.
    private func isWritten(_ p: String, _ data: Data?) -> Bool {
        guard let data else { return false }
        return written[p] == data || alsoWritten[p]?.contains(data) == true
    }

    /// Every note file on `d` was written by some device, with the same bytes.
    private func checkPlaced(_ d: SyncDevice, _ when: String) {
        for p in files(d) {
            guard written[p] != nil else { fail("\(d.name) \(when): \(p) appeared, but no device wrote it"); continue }
            if !isWritten(p, try? Data(contentsOf: d.folder.appendingPathComponent(p))) { fail("\(d.name) \(when): \(p) altered") }
        }
    }

    /// Every note file on the target's store (temporary names aside) was written by a device, with the same bytes.
    private func checkRemote(_ t: StressTarget) throws -> Set<String> {
        let all = try SyncDevices.remoteFiles(t.inspector)
        let visible = all.filter { !($0.split(separator: "/").last ?? "").hasPrefix(".") }
        for p in visible {
            guard written[p] != nil else { fail("\(t.name): \(p) is on the remote, but no device wrote it"); continue }
            let comps = p.split(separator: "/").map(String.init)
            if !isWritten(p, try? t.inspector.read(comps, maxBytes: 1 << 26).data) { fail("\(t.name): \(p) altered on the remote") }
        }
        return visible
    }

    /// Notes what a run quarantined; each must be kept (format.md §9.1), and nothing kept before
    /// may be gone or changed (design §6, I6: nothing leaves quarantine without Adopt or Export).
    private func noteQuarantined(_ r: SyncReport, _ link: StressLink, _ d: SyncDevice) {
        let dir = link.state.deletingPathExtension().appendingPathExtension("quarantine")
        for q in r.quarantined where q.message.contains("not kept") {
            fail("\(d.name): quarantined \(q.path) was not kept: \(q.message)")
        }
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            guard let hash = try? FileDigest.sha256(of: url).hex else { continue }
            if let before = quarantined[url], before != hash { fail("\(d.name): quarantined \(url.lastPathComponent) was replaced") }
            quarantined[url] = hash
        }
        // Kept under its path, or beside it as a further distinct copy (`<path>.copy-<hash>`).
        for q in r.quarantined where !quarantined.keys.contains(where: { $0.path.hasSuffix("/" + q.path) || $0.path.contains("/\(q.path).copy-") }) {
            fail("\(d.name): quarantined \(q.path) is not in \(dir.path)")
        }
    }

    // MARK: The run

    private func sync(_ i: Int, _ link: StressLink, _ edit: (inout SyncOptions) -> Void = { _ in }) -> SyncReport? {
        let d = devices[i]
        counts["sync", default: 0] += 1
        guard let r = try? d.sync(via: link.endpoint.remote, state: link.state, edit) else {
            counts["threw", default: 0] += 1
            return nil
        }
        noteQuarantined(r, link, d)
        return r
    }

    func run() throws {
        // The first device creates the vault (every device's key a recipient) and every device pulls it, without faults.
        _ = try TestVaults.create(at: devices[0].folder, identities: devices.map(\.identity), names: devices.map(\.name))
        for (i, d) in devices.enumerated() {
            for link in links[i] { for _ in 0..<3 { _ = sync(i, link) } }
            guard d.hasVault else { return fail("\(d.name) did not pull the vault") }
        }
        for l in links.joined() { l.endpoint.setFaults(true) }

        let settingKeys = ["history.thinAfterDays", "photos.removeMetadata", "eraser.mode"]
        for step in 0..<mode.steps {
            tick.value = step * 7
            let i = Int(rng.next() % UInt64(devices.count))
            let d = devices[i]
            let known = (try? d.vault().noteIDs()) ?? []
            let roll = rng.next() % 23
            do {
                switch roll {
                case 0, 1, 2:
                    try d.newNote("note \(step) by \(d.name)", id: seededUUID())
                    counts["new", default: 0] += 1
                case 3, 4:
                    guard let id = pick(known) else { continue }
                    try d.rename(id, "renamed \(step) by \(d.name)")
                    counts["rename", default: 0] += 1
                case 5:
                    guard let id = pick(known) else { continue }
                    try d.tag(id, "t\(step % 4)")
                    counts["tag", default: 0] += 1
                case 6:
                    guard let id = pick(known) else { continue }
                    var bytes = Data(count: 2000 + Int(rng.next() % 6000))
                    for k in bytes.indices { bytes[k] = UInt8(truncatingIfNeeded: rng.next()) }
                    try d.attach(id, bytes)
                    counts["attach", default: 0] += 1
                case 7:
                    guard rng.next() % 3 == 0, let id = pick(known) else { continue }
                    try d.delete(id)
                    counts["delete", default: 0] += 1
                case 8:
                    // The note with the longest history here (thinning a short one deletes nothing).
                    let v = try d.vault()
                    guard rng.next() % 2 == 0,
                          let id = try known.max(by: { try v.revisionNames(of: $0).count < v.revisionNames(of: $1).count })
                    else { continue }
                    let deleted = try d.thin(id)
                    counts["thin", default: 0] += 1
                    counts["thinned files", default: 0] += deleted.count
                case 9:
                    let v = try d.vault()
                    var s = try v.readSharedSettings() ?? SharedSettings()
                    try s.set(SettingSlotKey(settingKeys[Int(rng.next() % 3)]), to: .string("\(d.name)\(step)"), type: .mac, now: d.now)
                    try v.writeSharedSettings(s)
                    counts["settings", default: 0] += 1
                case 10 where mode.simultaneous:
                    // Two devices on one target at the same time.
                    guard let link = pick(links[i]),
                          let j = pick(devices.indices.filter { $0 != i && links[$0].contains { $0.target === link.target } }),
                          let other = links[j].first(where: { $0.target === link.target }) else { continue }
                    let group = DispatchGroup()
                    let reports = Locked([SyncReport?](repeating: nil, count: 2))
                    for (n, (k, l)) in [(i, link), (j, other)].enumerated() {
                        // Only Sendable values cross into the closure: the device (internally
                        // synchronized test harness), its remote (a `SyncRemote`) and the state file.
                        let dev = devices[k], remote = l.endpoint.remote, state = l.state
                        DispatchQueue.global().async(group: group) {
                            let r = try? dev.sync(via: remote, state: state)
                            reports.value[n] = r
                        }
                    }
                    if group.wait(timeout: .now() + 120) != .success { return fail("simultaneous runs hung") }
                    for (n, (k, l)) in [(i, link), (j, other)].enumerated() {
                        if let r = reports.value[n] { noteQuarantined(r, l, devices[k]) }
                    }
                    counts["simultaneous", default: 0] += 1
                    checkPlaced(devices[j], "after a simultaneous run")
                case 20:
                    // A voice note recorded into the inbox (quick capture), adopted later by any device.
                    var audio = Data(count: 1000 + Int(rng.next() % 3000))
                    for k in audio.indices { audio[k] = UInt8(truncatingIfNeeded: rng.next()) }
                    captures.insert(try d.captureVoiceNote(audio, id: seededUUID()))
                    counts["capture", default: 0] += 1
                case 21:
                    counts["adopted", default: 0] += try d.adoptInbox()
                case 22:
                    published[d.name] = try d.publishSummaries()
                    counts["publish", default: 0] += 1
                default:
                    guard let link = pick(links[i]) else { continue }
                    _ = sync(i, link)
                }
            } catch {
                fail("step \(step) on \(d.name): \(error)")
            }
            if roll <= 9 || roll >= 20 { recordWrites(d) } else { checkPlaced(d, "after step \(step)") }
        }

        // Faults off: rounds of every device on every target it uses, until one changes nothing.
        for l in links.joined() { l.endpoint.setFaults(false) }
        tick.value = mode.steps * 7 + 60
        var quiet = false
        var last: [String] = []
        for round in 0..<12 where !quiet {
            quiet = true
            for (i, d) in devices.enumerated() {
                for link in links[i] {
                    // As Repair does: files quarantined by a hostile answer are checked again.
                    guard let r = sync(i, link, { $0.retryQuarantined = true }) else {
                        quiet = false
                        last.append("round \(round) \(d.name)/\(link.target.name): threw")
                        continue
                    }
                    if !r.isEmpty {
                        quiet = false
                        last.append("round \(round) \(d.name)/\(link.target.name): \(Self.brief(r))")
                    }
                }
            }
        }
        if !quiet { return fail("no quiet round in 12:\n" + last.suffix(40).joined(separator: "\n")) }
        try checkConverged()
    }

    /// What a run changed or reported, in one line.
    static func brief(_ r: SyncReport) -> String {
        var parts: [String] = []
        func add(_ name: String, _ xs: [String]) { if !xs.isEmpty { parts.append("\(name) \(xs)") } }
        add("up", r.uploaded); add("down", r.downloaded)
        add("deleted", r.deleted.map { "\($0.side):\($0.path)" })
        add("conflicts", r.conflicts.map(\.path)); add("errors", r.errors.map { "\($0.path): \($0.message)" })
        add("rejected", r.rejected.map { "\($0.path): \($0.message)" }); add("quarantined", r.quarantined.map(\.path))
        add("merged", r.merged); add("extraneous", r.extraneous); add("overwritten", r.overwritten)
        return parts.joined(separator: "; ")
    }

    private func checkConverged() throws {
        let fm = FileManager.default
        let a = devices[0]
        let reference = files(a)
        for d in devices {
            checkPlaced(d, "at the end")
            let files = self.files(d)
            if files != reference {
                fail("\(d.name) holds other files than A: only here \(files.subtracting(reference).sorted().prefix(3)), "
                     + "only on A \(reference.subtracting(files).sorted().prefix(3))")
            }
            let partial = SyncDevices.hiddenFiles(in: d.folder)
            if !partial.isEmpty { fail("\(d.name): files in progress left: \(partial.prefix(3))") }
            let copies = ((try? fm.contentsOfDirectory(atPath: d.folder.path)) ?? []).filter { $0.contains(".conflict-") }
            if !copies.isEmpty { fail("\(d.name): conflict copies \(copies)") }
        }
        for t in targets {
            let all = try SyncDevices.remoteFiles(t.inspector)
            let leftovers = all.filter { ($0.split(separator: "/").last ?? "").hasPrefix(".") }
            if !leftovers.isEmpty { fail("\(t.name): temporary files left: \(leftovers.sorted().prefix(3))") }
            let visible = try checkRemote(t)
            if visible != reference {
                fail("\(t.name) holds other files than A: only there \(visible.subtracting(reference).sorted().prefix(3)), "
                     + "only on A \(reference.subtracting(visible).sorted().prefix(3))")
            }
        }

        // Every device reads the same notes and settings.
        let va = try a.vault()
        var states: [UUID: NoteState] = [:]
        for id in try va.noteIDs() { states[id] = try va.reconstruct(noteId: id) }
        let settings = try va.readSharedSettings()
        for d in devices.dropFirst() {
            let v = try d.vault()
            for id in try v.noteIDs() where (try? v.reconstruct(noteId: id)) != states[id] { fail("\(d.name) reads note \(id) otherwise") }
            if try v.readSharedSettings() != settings { fail("\(d.name) reads other settings") }
        }

        // Nothing lost: every attachment is there, and every revision is there or (thinned) changes nothing.
        let present = reference
        var missing: [String: [String]] = [:]
        for p in written.keys where !present.contains(p) {
            let parts = p.split(separator: "/").map(String.init)
            if parts.count == 4, parts[2] == Vault.attachmentsName {
                fail("attachment \(p) lost")
            } else if parts.count == 3 {
                missing[parts[1], default: []].append(p)
            }
        }
        for (note, paths) in missing.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: note), let actual = states[id] else {
                fail("note \(note) lost entirely (\(paths.count) revisions)")
                continue
            }
            let ideal = root.appendingPathComponent("ideal-\(note)")
            try? fm.removeItem(at: ideal)
            try fm.copyItem(at: a.folder, to: ideal)
            for p in paths { try written[p]?.write(to: ideal.appendingPathComponent(p)) }
            let full = try Vault.open(at: ideal, identities: [a.identity]).reconstruct(noteId: id)
            if full.deleted != actual.deleted || full.meta != actual.meta || full.pages != actual.pages {
                fail("note \(note): \(paths.count) revisions gone, and the note reads otherwise without them "
                     + "(title \(actual.meta.title) vs \(full.meta.title))")
            }
            try? fm.removeItem(at: ideal)
        }

        // The inbox and the per-device summaries are the same everywhere; no capture is lost
        // (it is in every inbox, or its note is on every device); each device's own file is what it wrote.
        let inbox = a.rootFolderFiles(CaptureFile.folderName), summaries = a.rootFolderFiles(PublishedSummaries.deviceFolderName)
        for d in devices {
            if Set(d.rootFolderFiles(CaptureFile.folderName).keys) != Set(inbox.keys) { fail("\(d.name) holds another inbox than A") }
            if d.rootFolderFiles(PublishedSummaries.deviceFolderName) != summaries { fail("\(d.name) holds other summaries than A") }
            if let mine = published[d.name], summaries[PublishedSummaries.deviceFileName(d.device)] != mine {
                fail("\(d.name)'s own summaries file is not the one it wrote")
            }
        }
        for t in targets {
            for (folder, want) in [(CaptureFile.folderName, inbox), (PublishedSummaries.deviceFolderName, summaries)] {
                let names = Set((try t.inspector.list([folder]) ?? []).map(\.name).filter { !$0.hasPrefix(".") })
                if names != Set(want.keys) { fail("\(t.name): \(folder)/ holds \(names.sorted()), A \(want.keys.sorted())") }
                for n in names where (try? t.inspector.read([folder, n], maxBytes: 1 << 28).data) != want[n] {
                    if folder != CaptureFile.folderName { fail("\(t.name): \(folder)/\(n) differs from A's") }
                }
            }
        }
        for id in captures {
            let waiting = inbox.keys.contains(CaptureFile.name(id, .capture))
            let note = CaptureAdoption.ids(for: id).note
            if !waiting, states[note]?.recordings.isEmpty != false { fail("capture \(id) lost: not in the inbox and not adopted") }
        }

        // Quarantine never deletes or replaces.
        for (q, hash) in quarantined where (try? FileDigest.sha256(of: q).hex) != hash {
            fail("quarantined \(q.lastPathComponent) is gone or changed")
        }
        let injected = links.joined().map { $0.endpoint.injected() }.reduce(0, +)
        if injected == 0 { fail("no fault was injected") }
    }
}

/// A remote that goes through its faulty twin while `on` is set.
struct SwitchedRemote: SyncRemote {
    var plain: any SyncRemote
    var faulty: any SyncRemote
    let on: Locked<Bool>
    private var now: any SyncRemote { on.value ? faulty : plain }

    var location: String { plain.location }
    var capabilities: RemoteCapabilities { plain.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { plain.interrupt }
        set { plain.interrupt = newValue; faulty.interrupt = newValue }
    }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try now.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try now.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try now.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try now.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try now.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes, segmentBytes: segmentBytes,
                         progress: progress)
    }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool { try now.write(path, body, condition: condition) }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool { try now.moveNoOverwrite(path, to: destination) }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try now.makeCollection(path) }
    func createBase() throws { try now.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try now.delete(path, ifETag: ifETag) }
    func missingCollectionError(_ path: [String]) -> any Error { plain.missingCollectionError(path) }
}

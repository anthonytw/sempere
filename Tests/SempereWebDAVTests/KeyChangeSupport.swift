import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

// Support for the key-change safety gate (docs/design/device-first-sync.md §6.4):
// devices with their own keys, trust records, keyrings and coordinators, on
// targets that can go offline, and the invariants I1 to I6.

/// A remote that can be switched off (a target out of reach).
struct SwitchableRemote: SyncRemote {
    var inner: any SyncRemote
    let offline: Locked<Bool>

    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { inner.interrupt }
        set { inner.interrupt = newValue }
    }

    func check() throws { if offline.value { throw MemoryRemoteError.offline("switched off") } }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try check(); return try inner.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try check(); return try inner.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try check(); return try inner.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try check(); return try inner.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try check()
        return try inner.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                                  segmentBytes: segmentBytes, progress: progress)
    }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try check(); return try inner.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try check(); return try inner.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try check(); return try inner.makeCollection(path) }
    func createBase() throws { try check(); try inner.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try check(); return try inner.delete(path, ifETag: ifETag) }
    func missingCollectionError(_ path: [String]) -> any Error { inner.missingCollectionError(path) }
    func requestDownload(_ paths: [[String]]) throws { try check(); try inner.requestDownload(paths) }
    func conflictVersions(_ path: [String]) -> [RemoteVersion] { offline.value ? [] : inner.conflictVersions(path) }
    func readVersion(_ path: [String], _ version: RemoteVersion, maxBytes: Int) throws -> Data {
        try check(); return try inner.readVersion(path, version, maxBytes: maxBytes)
    }
    func resolveConflicts(_ path: [String], _ versions: [RemoteVersion]) throws { try check(); try inner.resolveConflicts(path, versions) }
}

/// One target: an in-memory store under `vault/`, the WebDAV mock, a plain folder (`FolderRemote`), or a
/// folder a simulated provider holds (`EvictingFolderProvider`: the design's `EvictingFolderRemote`).
final class KCTarget: @unchecked Sendable {
    enum Kind { case memory, webdav, folder, evicting }
    let name: String
    let offline = Locked(false)
    let store: MemoryStore?
    let dav: MockDAV?
    let folder: URL?
    let provider: EvictingFolderProvider?

    init(name: String, webdav: Bool = false) {
        self.name = name
        store = webdav ? nil : MemoryStore(name: name)
        dav = webdav ? MockDAV() : nil
        folder = nil
        provider = nil
    }

    init(name: String, kind: Kind, dir: URL) {
        self.name = name
        store = kind == .memory ? MemoryStore(name: name) : nil
        dav = kind == .webdav ? MockDAV() : nil
        if kind == .folder || kind == .evicting {
            let root = dir.appendingPathComponent("\(name).sempere")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            folder = root
            provider = kind == .evicting ? EvictingFolderProvider(root: root, cloud: dir.appendingPathComponent("\(name)-cloud")) : nil
        } else {
            folder = nil
            provider = nil
        }
    }

    private var bare: any SyncRemote {
        if let store { return MemoryRemote(store: store, base: ["vault"]) }
        if let folder { return FolderRemote(root: folder, provider: provider ?? PlainFolder()) }
        return WebDAVSyncRemote(try! WebDAVClient(baseURL: URL(string: "https://dav.example.com\(MockDAV.base)/")!,
                                                  credentials: nil, transport: dav!))
    }

    /// How a device reaches it (`faults`: that device's own transport faults, in-memory targets only).
    func remote(faults: MemoryFaults? = nil) -> any SyncRemote {
        let inner: any SyncRemote = store.map { MemoryRemote(store: $0, base: ["vault"], faults: faults) } ?? bare
        return SwitchableRemote(inner: inner, offline: offline)
    }

    /// The target itself, never offline, with no faults (for checking it).
    var inspector: any SyncRemote { bare }

    func file(_ path: [String]) -> Data? { try? inspector.read(path, maxBytes: 1 << 26).data }
    /// Puts a file there directly (making its parents), as a server or another writer would.
    func put(_ path: [String], _ data: Data) {
        if let store { store.putDirect(["vault"] + path, data) } else if let folder {
            let url = folder.appendingPathComponent(path.joined(separator: "/"))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        } else { dav?.putDirect(path.joined(separator: "/"), data) }
    }
    func remove(_ path: [String]) { _ = try? inspector.delete(path) }

    /// Every file under `notes/`, as `notes/...` → bytes.
    func noteFiles() -> [String: Data] {
        var out: [String: Data] = [:]
        let r = inspector
        func walk(_ path: [String]) {
            for e in (try? r.list(path)) ?? [] ?? [] {
                if e.name.hasPrefix(".") { continue }
                if e.isCollection { walk(path + [e.name]) } else if let d = try? r.read(path + [e.name], maxBytes: 1 << 26).data {
                    out[(path + [e.name]).joined(separator: "/")] = d
                }
            }
        }
        walk([Vault.notesName])
        return out
    }
}

/// One device of a key-change test.
final class KCDevice: @unchecked Sendable {
    let name: String
    let root: URL
    /// Every key this device holds, newest first.
    var identities: [NativeIdentity]
    let trust = MemoryRecipientsTrustStore()
    let keyring = MemorySecretKeyringStore()
    let targets: [KCTarget]
    var faults: [String: MemoryFaults] = [:]
    /// Removed from the vault (it keeps its working copy and keys).
    var removed = false
    let device: DeviceID
    /// The revision the last `attach` wrote.
    var lastAttachRevision: Revision?

    init(name: String, root: URL, targets: [KCTarget], device: DeviceID) throws {
        self.name = name
        self.root = root
        self.targets = targets
        self.device = device
        identities = [pqIdentity()]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DeviceState(device: device).save(to: deviceStateURL)
    }

    var folder: URL { root.appendingPathComponent("Vault.sempere", isDirectory: true) }
    var deviceStateURL: URL { root.appendingPathComponent("device.json") }
    var identity: NativeIdentity { identities[0] }
    var hasVault: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(Vault.manifestName).path) }
    func stateURL(_ t: String) -> URL { root.appendingPathComponent("sync-\(t).json") }
    func quarantine(_ t: String) -> URL { root.appendingPathComponent("sync-\(t).quarantine") }

    var coordinator: KeyChangeCoordinator {
        KeyChangeCoordinator(folder: folder, targets: targets.map {
            KeyChangeTarget(id: $0.name, remote: $0.remote(faults: faults[$0.name]), stateURL: stateURL($0.name))
        }, keyring: keyring, ledger: root.appendingPathComponent("keychange.json"))
    }

    func vault() throws -> Vault { try Vault.open(at: folder, identities: identities, trust: trust) }

    // MARK: Writes

    @discardableResult
    func write(_ id: UUID, _ title: String, now: Date) throws -> RevisionName {
        let r = try vault().apply([.setMeta(.title(title))], to: id, deviceState: deviceStateURL, app: "kc/\(name)", wall: now)
        return r.name
    }

    @discardableResult
    func attach(_ id: UUID, _ bytes: Data, now: Date) throws -> String {
        let v = try vault()
        let ref = try v.writeBlob(note: id, bytes, type: "image/png")
        let page = UUID()
        lastAttachRevision = try v.apply([.addPage(Page(id: page, order: "z\(UUID().uuidString.prefix(8))")),
                     .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                       frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a"))],
                    to: id, deviceState: deviceStateURL, app: "kc/\(name)", wall: now)
        return try v.blobFileName(for: ref)
    }

    // MARK: Sync

    func options(_ now: Date) -> SyncOptions {
        var o = SyncOptions(deviceLabel: name, now: now)
        o.blobRetention = 0
        o.ownDevices = [device]
        return o
    }

    /// One run with target `t` through the coordinator (a first pull when there is no vault yet).
    @discardableResult
    func sync(_ t: String, now: Date, faults kf: KeyChangeFaults = KeyChangeFaults(),
              edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        guard let target = targets.first(where: { $0.name == t }) else { throw SyncError.io("no \(t)") }
        var o = options(now)
        o.quarantineDirectory = quarantine(t)
        edit(&o)
        guard hasVault else {
            o.firstPullIdentities = identities
            o.keyring = keyring
            return try SyncEngine(directory: folder, vault: nil, remote: target.remote(faults: faults[t]),
                                  stateURL: stateURL(t), options: o).run()
        }
        var v = try vault()
        guard v.canRead else { throw SyncError.io("\(name) cannot open the vault") }
        let watch = ProcessInfo.processInfo.environment["SEMPERE_KEYCHANGE_WATCH"]
        let had = watch.map { w in noteFiles().keys.filter { $0.contains(w) } } ?? []
        let r = try coordinator.sync(target: t, vault: &v, options: o, faults: kf).report
        if let watch {
            let has = noteFiles().keys.filter { $0.contains(watch) }
            if Set(has) != Set(had) { print("WATCH \(name)/\(t) at \(now.timeIntervalSince1970 - 1_790_000_000): \(had.count) -> \(has.count): \(KCWorld.brief(r)) \(r.downloaded.filter { $0.contains(watch) }) \(r.deleted)") }
        }
        return r
    }

    /// Syncs every target of this device in turn; errors become empty reports.
    @discardableResult
    func syncAll(now: Date) -> [SyncReport] {
        targets.map { t in (try? sync(t.name, now: now)) ?? { var r = SyncReport(); r.errors = [.init(path: "", message: "threw")]; return r }() }
    }

    // MARK: What it holds

    func noteFiles() -> [String: Data] {
        var out: [String: Data] = [:]
        let base = folder.appendingPathComponent(Vault.notesName)
        guard let e = FileManager.default.enumerator(atPath: base.path) else { return out }
        for case let rel as String in e {
            let url = base.appendingPathComponent(rel)
            var dir: ObjCBool = false
            guard !(rel as NSString).lastPathComponent.hasPrefix("."),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue,
                  let d = try? Data(contentsOf: url) else { continue }
            out["notes/" + rel] = d
        }
        return out
    }

    func manifest() -> Data? { try? Data(contentsOf: folder.appendingPathComponent(Vault.manifestName)) }

    /// Every file in this device's quarantine folders (late files included), by full path.
    func quarantined() -> [String: Data] {
        var out: [String: Data] = [:]
        for t in targets {
            let q = quarantine(t.name)
            guard let e = FileManager.default.enumerator(atPath: q.path) else { continue }
            for case let rel as String in e {
                let url = q.appendingPathComponent(rel)
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue,
                   let d = try? Data(contentsOf: url) { out[url.path] = d }
            }
        }
        return out
    }

    func lateFiles() -> [LateFiles.Item] { targets.flatMap { LateFiles.list(quarantine: quarantine($0.name)) } }
}

/// Every key and secret the test world ever made: what I1 and I3 read with.
final class KCOracle: @unchecked Sendable {
    var identities: [NativeIdentity] = []
    var secrets: [VaultSecret] = []
    /// Body (`gzip(JSON)`, or a blob's content hash) of every revision written, by path.
    var written: [String: Data] = [:]
    /// The device that wrote each revision.
    var writer: [String: String] = [:]
    /// Every attachment written: `notes/<note>` → content hashes, with their writer.
    var attached: [String: [String: String]] = [:]

    func learn(_ d: KCDevice) {
        for i in d.identities where !identities.contains(where: { $0.recipient.string == i.recipient.string }) { identities.append(i) }
        if let ring = try? d.keyring.load(vaultId: (try? d.vault().vaultId) ?? UUID()) {
            for s in ring.entries.compactMap({ Hex.decode($0.secret).flatMap { try? VaultSecret(bytes: $0) } })
            where !secrets.contains(s) { secrets.append(s) }
        }
        if let v = try? d.vault(), let s = v.currentSecret, !secrets.contains(s) { secrets.append(s) }
    }

    /// The body of a revision file under any secret ever, opened with `keys` (default: every key ever),
    /// nil when none opens it.
    func body(_ data: Data, path: String, keys: [NativeIdentity]? = nil) -> Data? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, let plain = try? AgeFile.decrypt(data, with: keys ?? identities) else { return nil }
        for s in secrets {
            if let u = try? BodyFraming.unframe(plain, noteId: parts[1], filename: parts[2], secret: s) { return u.gzip }
        }
        return nil
    }

    /// Records a revision just written by `d`.
    func wrote(_ d: KCDevice, note: UUID, name: RevisionName) {
        learn(d)
        let path = "notes/\(note.uuidString.lowercased())/\(name.filename)"
        if let data = try? Data(contentsOf: d.folder.appendingPathComponent(path)), let b = body(data, path: path) {
            written[path] = b
            writer[path] = d.name
        }
    }
}

/// Devices and targets of one key-change scenario, on a virtual clock.
final class KCWorld: @unchecked Sendable {
    let targets: [KCTarget]
    let devices: [KCDevice]
    let oracle = KCOracle()
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// A spare key listed in the vault that no device holds (a paper key): added and removed freely.
    var spare: NativeIdentity?

    /// `deviceCount` devices; device i uses the targets `uses[i]` (default: every target).
    init(root: URL, deviceCount: Int = 3, targetCount: Int = 2, webdav: Set<Int> = [], uses: [[Int]]? = nil,
         kinds: [KCTarget.Kind]? = nil) throws {
        let ts = (0..<targetCount).map { i in
            kinds.map { KCTarget(name: "T\(i)", kind: $0[i], dir: root.appendingPathComponent("targets")) }
                ?? KCTarget(name: "T\(i)", webdav: webdav.contains(i))
        }
        targets = ts
        var ds: [KCDevice] = []
        for i in 0..<deviceCount {
            let name = String(UnicodeScalar(UInt8(65 + i)))
            let hex = String(repeating: String(UnicodeScalar(UInt8(97 + i))), count: 8)
            let use = uses?[i] ?? Array(0..<targetCount)
            ds.append(try KCDevice(name: name, root: root.appendingPathComponent(name), targets: use.map { ts[$0] },
                                   device: DeviceID(hex)!))
        }
        devices = ds
        _ = try Vault.create(at: ds[0].folder, recipients: ds.map(\.identity.recipient), labels: ds.map(\.name),
                             identities: [ds[0].identity], created: now, trust: ds[0].trust)
        for d in ds { oracle.learn(d) }
        try converge()
    }

    var a: KCDevice { devices[0] }
    var b: KCDevice { devices[1] }
    var c: KCDevice { devices[2] }

    func tick(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }

    /// Every (still listed) device syncs every target in turn until a whole round changes nothing.
    func converge(rounds: Int = 10, skip: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) throws {
        var last: [String] = []
        for _ in 0..<rounds {
            last = []
            for d in devices where !d.removed && !skip.contains(d.name) {
                for t in d.targets where !t.offline.value {
                    tick()
                    do {
                        let r = try d.sync(t.name, now: now)
                        if !r.isEmpty { last.append("\(d.name)/\(t.name): \(KCWorld.brief(r))") }
                        if ProcessInfo.processInfo.environment["SEMPERE_KEYCHANGE_TRACE"] == "2" {
                            func fp(_ d: Data?) -> String { d.flatMap { Vault.listFingerprint($0) }.map { String($0.prefix(6)) } ?? "-" }
                            print("  \(d.name)/\(t.name): local \(fp(d.manifest())) T0 \(fp(targets[0].file([Vault.manifestName]))) "
                                  + "T1 \(fp(targets.count > 1 ? targets[1].file([Vault.manifestName]) : nil)) | \(KCWorld.brief(r)) "
                                  + "\(r.uploaded.prefix(2)) \(r.downloaded.prefix(2)) \(r.skipped.prefix(2).map(\.message))")
                        }
                    } catch {
                        last.append("\(d.name)/\(t.name): threw \(error)")
                    }
                }
            }
            for d in devices { oracle.learn(d) }
            if last.isEmpty { return }
        }
        XCTFail("no quiet round in \(rounds): \(last.prefix(6))", file: file, line: line)
    }

    static func brief(_ r: SyncReport) -> String {
        var parts: [String] = []
        if !r.uploaded.isEmpty { parts.append("up \(r.uploaded.count)") }
        if !r.downloaded.isEmpty { parts.append("down \(r.downloaded.count)") }
        if !r.deleted.isEmpty { parts.append("del \(r.deleted.map(\.path).prefix(3))") }
        if !r.conflicts.isEmpty { parts.append("conflicts \(r.conflicts.map(\.path))") }
        if !r.errors.isEmpty { parts.append("errors \(r.errors.prefix(3).map { "\($0.path): \($0.message)" })") }
        if !r.rejected.isEmpty { parts.append("rejected \(r.rejected.map { "\($0.path): \($0.message)" })") }
        if !r.quarantined.isEmpty { parts.append("quarantined \(r.quarantined.prefix(3).map { "\($0.path): \($0.message)" })") }
        if let k = r.keyChange, !k.isEmpty {
            parts.append("kc replaced \(k.replaced.count) late \(k.lateAccepted.count)/\(k.lateQuarantined.count) r3 \(k.rewrapped)")
        }
        return parts.joined(separator: "; ")
    }

    /// Attaches `bytes` to `note` on `d` (blob and revision) and records both for I1.
    @discardableResult
    func attach(_ d: KCDevice, _ note: UUID, _ bytes: Data) throws -> String {
        tick()
        let name = try d.attach(note, bytes, now: now)
        if let r = d.lastAttachRevision { oracle.wrote(d, note: note, name: r.name) }
        oracle.attached["notes/\(note.uuidString.lowercased())", default: [:]][FileDigest.sha256(bytes)] = d.name
        return name
    }

    /// Writes a revision on `d` and records it for I1.
    @discardableResult
    func write(_ d: KCDevice, _ note: UUID, _ title: String) throws -> RevisionName {
        tick()
        let n = try d.write(note, title, now: now)
        oracle.wrote(d, note: note, name: n)
        return n
    }

    /// A key change on `d` through its coordinator, after a fresh sync of its targets (C0).
    @discardableResult
    func change(_ d: KCDevice, overriding: Set<String> = [], syncFirst: Bool = true,
                faults: KeyChangeFaults = KeyChangeFaults(),
                _ prepare: (inout Vault) throws -> PreparedKeyChange) throws -> Vault.RewrapReport {
        if syncFirst { for t in d.targets where !t.offline.value { tick(); _ = try? d.sync(t.name, now: now) } }
        tick()
        var v = try d.vault()
        defer { oracle.learn(d) }
        return try d.coordinator.change(&v, overriding: overriding, now: now, faults: faults, prepare: prepare)
    }

    /// Adds a spare (paper) key; returns it.
    @discardableResult
    func addSpare(on d: KCDevice, policy: KeyChangePolicy = .routine) throws -> NativeIdentity {
        let s = pqIdentity()
        oracle.identities.append(s)
        try change(d) { try $0.prepareAddRecipient(s.recipient, label: "paper", keyChange: policy, now: now) }
        spare = s
        return s
    }

    // MARK: Invariants (design §6.4)

    /// I2: every listed device and every target hold the same `vault.json` and the same bytes for every note file.
    func assertConverged(ignoring: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        let listed = devices.filter { !$0.removed }
        guard let reference = listed.first?.manifest() else { return XCTFail("no vault.json", file: file, line: line) }
        let files = listed[0].noteFiles()
        func diff(_ x: Data?) -> String {
            guard let x, let a = try? JSONSerialization.jsonObject(with: x) as? [String: Any],
                  let b = try? JSONSerialization.jsonObject(with: reference) as? [String: Any] else { return "?" }
            return Set(a.keys).union(b.keys).sorted().filter { k in
                "\(a[k].map { "\($0)" } ?? "nil")" != "\(b[k].map { "\($0)" } ?? "nil")"
            }.map { k in "\(k): \(String("\(a[k] ?? "nil")".prefix(70))) vs \(String("\(b[k] ?? "nil")".prefix(70)))" }.joined(separator: "; ")
        }
        for d in listed {
            XCTAssertEqual(d.manifest(), reference, "\(d.name): another vault.json: \(diff(d.manifest()))", file: file, line: line)
            let mine = d.noteFiles()
            XCTAssertEqual(Set(mine.keys), Set(files.keys), "\(d.name): other files: "
                + "\(Set(mine.keys).symmetricDifference(files.keys).sorted().prefix(4))", file: file, line: line)
            let differ = mine.filter { files[$0.key] != nil && files[$0.key] != $0.value }.keys.sorted()
            XCTAssertTrue(differ.isEmpty, "\(d.name): other bytes at \(differ.prefix(4))", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: d.folder.appendingPathComponent(Vault.journalName).path),
                           "\(d.name): a journal is left", file: file, line: line)
        }
        for t in targets {
            XCTAssertEqual(t.file([Vault.manifestName]), reference, "\(t.name): another vault.json: \(diff(t.file([Vault.manifestName])))",
                           file: file, line: line)
            XCTAssertNil(t.file([Vault.journalName]), "\(t.name): a journal is left (I5)", file: file, line: line)
            let there = t.noteFiles().filter { !ignoring.contains($0.key) }
            XCTAssertEqual(Set(there.keys), Set(files.keys), "\(t.name): other files: "
                + "\(Set(there.keys).symmetricDifference(files.keys).sorted().prefix(4))", file: file, line: line)
            let differ = there.filter { files[$0.key] != nil && files[$0.key] != $0.value }.keys.sorted()
            XCTAssertTrue(differ.isEmpty, "\(t.name): other bytes at \(differ.prefix(4))", file: file, line: line)
        }
    }

    /// Every note file on every device and target, by location.
    func everyCopy() -> [(String, String, Data)] {
        var out: [(String, String, Data)] = []
        for d in devices where !d.removed { for (p, data) in d.noteFiles() { out.append((d.name, p, data)) } }
        for t in targets { for (p, data) in t.noteFiles() { out.append((t.name, p, data)) } }
        return out
    }

    /// I4: no file anywhere (quarantines aside) opens with a removed key, and every one has one stanza per listed key.
    func assertRevoked(_ removed: [NativeIdentity], ignoring: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        guard let m = devices.first(where: { !$0.removed })?.manifest(), let manifest = try? VaultManifest.decode(m) else { return }
        for (loc, path, data) in everyCopy() where !ignoring.contains(path) {
            if let header = try? AgeFile.parseHeader(data).header {
                XCTAssertEqual(header.stanzas.count, manifest.recipients.count, "\(loc) \(path): stanzas", file: file, line: line)
            }
            for r in removed {
                XCTAssertNil(try? AgeFile.decrypt(data, with: [r]), "\(loc) \(path) opens with a removed key \(r.recipient.string.prefix(16))",
                             file: file, line: line)
            }
        }
    }

    /// I1 and I3: every revision written by a listed device is readable somewhere (vault or quarantine)
    /// with its body; no copy of a path anywhere has another body.
    func assertNoLoss(file: StaticString = #filePath, line: UInt = #line) {
        for d in devices { oracle.learn(d) }
        // Recoverable means readable with the keys the vault lists NOW, not with a removed one.
        let listedKeys = Set(devices.first(where: { !$0.removed })?.manifest()
            .flatMap { try? VaultManifest.decode($0) }?.recipients.map(\.key) ?? [])
        let current = oracle.identities.filter { listedKeys.contains($0.recipient.string) }
        var found = Set<String>()
        var copies = everyCopy().map { ($0.0, $0.1, $0.2) }
        for d in devices {
            for (full, data) in d.quarantined() {
                guard let r = full.range(of: "/notes/") else { continue }
                var p = "notes/" + full[r.upperBound...]
                if let c = p.range(of: ".copy-") { p = String(p[..<c.lowerBound]) }
                copies.append(("\(d.name) quarantine", p, data))
            }
        }
        var blobsFound = Set<String>()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kc-blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (loc, path, data) in copies {
            if path.contains("/att/") {
                // A blob: its content hash, opened with the listed keys (framing and padding checked).
                try? data.write(to: scratch)
                if let (header, _) = try? Vault.readBlobFile(scratch, identities: current, secrets: [], expected: nil,
                                                             maxContent: BlobRef.maxSize) {
                    blobsFound.insert(path.split(separator: "/").prefix(2).joined(separator: "/") + "#" + header.sha256)
                }
                continue
            }
            guard let want = oracle.written[path] else { continue }
            if let b = oracle.body(data, path: path) {
                XCTAssertEqual(b, want, "\(loc) \(path): another body (I3)", file: file, line: line)
            }
            if let b = oracle.body(data, path: path, keys: current), b == want { found.insert(path) }
        }
        let listedWriters = Set(devices.filter { !$0.removed }.map(\.name))
        let lost = oracle.written.keys.filter { listedWriters.contains(oracle.writer[$0] ?? "") && !found.contains($0) }
        XCTAssertTrue(lost.isEmpty, "lost (I1): \(lost.sorted().prefix(4))", file: file, line: line)
        let lostBlobs = oracle.attached.flatMap { note, hashes in
            hashes.filter { listedWriters.contains($0.value) }.keys.map { note + "#" + $0 }
        }.filter { !blobsFound.contains($0) }
        XCTAssertTrue(lostBlobs.isEmpty, "attachments lost (I1): \(lostBlobs.sorted().prefix(4))", file: file, line: line)
        // Every reference a listed device reads resolves there.
        for d in devices where !d.removed {
            guard let v = try? d.vault(), let ids = try? v.noteIDs() else { continue }
            for id in ids {
                let missing = (try? v.blobInventory(note: id))?.missing ?? []
                XCTAssertTrue(missing.isEmpty, "\(d.name): \(id) references attachments it lacks (I1)", file: file, line: line)
            }
        }
    }
}

extension KCDevice {
    /// Each note's title, as this device reads it.
    func notes() throws -> [UUID: String] {
        let v = try vault()
        var out: [UUID: String] = [:]
        for id in try v.noteIDs() { out[id] = try v.reconstruct(noteId: id).meta.title }
        return out
    }
}

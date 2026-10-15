import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// One device of a multi-device sync test (docs/ci.md "Sync stress"): its own
/// vault folder, key (the vault lists every device's key; each device opens it
/// with its own only), device clock (`device.json`: device id and hybrid
/// clock, as the CLI keeps them, with an optional skew of its wall clock) and
/// sync state, all under `root`, on one remote shared with the other devices.
final class SyncDevice: @unchecked Sendable {
    let name: String
    let root: URL
    let identity: NativeIdentity
    /// The remote as this device reaches it (its own transport, faults and all).
    var client: WebDAVClient
    /// Added to the real time for this device's writes and sync runs.
    var skew: TimeInterval = 0
    /// Applied to the options of every run (concurrency, limits, ...).
    var tune: (inout WebDAVSyncOptions) -> Void = { _ in }

    init(name: String, root: URL, identity: NativeIdentity, client: WebDAVClient, device: DeviceID? = nil) throws {
        self.name = name
        self.root = root
        self.identity = identity
        self.client = client
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let device, !FileManager.default.fileExists(atPath: deviceStateURL.path) {
            try DeviceState(device: device).save(to: deviceStateURL)
        }
    }

    var folder: URL { root.appendingPathComponent("Vault.sempere", isDirectory: true) }
    var deviceStateURL: URL { root.appendingPathComponent("device.json") }
    var stateURL: URL { root.appendingPathComponent("sync.json") }
    var now: Date { Date().addingTimeInterval(skew) }
    var device: DeviceID { (try? DeviceState.loadOrCreate(at: deviceStateURL).device) ?? DeviceID("00000000")! }
    var hasVault: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(Vault.manifestName).path) }

    func vault() throws -> Vault { try Vault.open(at: folder, identities: [identity]) }

    // MARK: Writes (one delta each, with this device's clock, as the CLI and the app write)

    /// Creates a note titled `title`; returns its id.
    @discardableResult
    func newNote(_ title: String, id: UUID = UUID()) throws -> UUID {
        try vault().apply([.setMeta(.title(title))], to: id, deviceState: deviceStateURL, app: "stress/\(name)", wall: now)
        return id
    }

    /// Renames a note (a last-writer-wins register: concurrent renames converge to one title).
    @discardableResult
    func rename(_ id: UUID, _ title: String) throws -> Revision {
        try vault().apply([.setMeta(.title(title))], to: id, deviceState: deviceStateURL, app: "stress/\(name)", wall: now)
    }

    /// Adds a tag (tags merge per tag, so concurrent adds are all kept).
    @discardableResult
    func tag(_ id: UUID, _ tag: String) throws -> Revision {
        try vault().apply([.addTag(tag)], to: id, deviceState: deviceStateURL, app: "stress/\(name)", wall: now)
    }

    /// Stores `bytes` as an image blob of the note and references it in one delta.
    @discardableResult
    func attach(_ id: UUID, _ bytes: Data) throws -> String {
        let v = try vault()
        let ref = try v.writeBlob(note: id, bytes, type: "image/png")
        let page = UUID()
        try v.apply([.addPage(Page(id: page, order: "z\(UUID().uuidString.prefix(8))")),
                     .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                       frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a"))],
                    to: id, deviceState: deviceStateURL, app: "stress/\(name)", wall: now)
        return try v.blobFileName(for: ref)
    }

    // MARK: Sync

    func options(_ edit: (inout WebDAVSyncOptions) -> Void = { _ in }) -> WebDAVSyncOptions {
        var o = WebDAVSyncOptions(deviceLabel: name, now: now)
        if !hasVault { o.firstPullIdentities = [identity] }
        tune(&o)
        edit(&o)
        return o
    }

    /// A two-way run (the CLI's `sync webdav`).
    @discardableResult
    func sync(_ edit: (inout WebDAVSyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let v = hasVault ? try vault() : nil
        return try WebDAVSync(directory: folder, vault: v, client: client, stateURL: stateURL, options: options(edit)).run()
    }

    /// The app's push (push-only, keeping what another device changed on the server).
    @discardableResult
    func push() throws -> SyncReport {
        try sync { $0.pushOnly = true; $0.keepServerChanges = true }
    }

    /// Two-way runs until one changes nothing and reports no problem; fails after `rounds`.
    @discardableResult
    func syncUntilQuiet(rounds: Int = 12, file: StaticString = #filePath, line: UInt = #line) throws -> [SyncReport] {
        var reports: [SyncReport] = []
        for _ in 0..<rounds {
            let r: SyncReport
            do { r = try sync() } catch {
                reports.append(SyncReport())
                continue
            }
            reports.append(r)
            if r.isEmpty { return reports }
        }
        XCTFail("\(name): no quiet run in \(rounds): \(reports.last.map { "\($0)" } ?? "")", file: file, line: line)
        return reports
    }

    // MARK: What it holds

    /// Every visible file under `notes/`, as `notes/<id>/<name>` and `notes/<id>/att/<name>`.
    func noteFiles() -> Set<String> { Self.noteFiles(in: folder) }

    static func noteFiles(in folder: URL) -> Set<String> {
        var out = Set<String>()
        let notes = folder.appendingPathComponent(Vault.notesName)
        let fm = FileManager.default
        for id in (try? fm.contentsOfDirectory(atPath: notes.path)) ?? [] where !id.hasPrefix(".") {
            let dir = notes.appendingPathComponent(id)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                if name == Vault.attachmentsName {
                    for blob in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(name).path)) ?? [] {
                        out.insert("\(Vault.notesName)/\(id)/\(name)/\(blob)")
                    }
                } else {
                    out.insert("\(Vault.notesName)/\(id)/\(name)")
                }
            }
        }
        return out
    }

    /// Each note's title and tags, as this device reads them.
    func notes() throws -> [UUID: String] {
        let v = try vault()
        var out: [UUID: String] = [:]
        for id in try v.noteIDs() {
            let s = try v.reconstruct(noteId: id)
            out[id] = s.meta.title + " #" + s.meta.tags.sorted().joined(separator: ",")
        }
        return out
    }
}

/// Two (or more) devices on one remote, for interleaved writes and syncs.
final class SyncDevices: @unchecked Sendable {
    let devices: [SyncDevice]
    var a: SyncDevice { devices[0] }
    var b: SyncDevice { devices[1] }
    /// A client for checking the remote itself, with no faults.
    let inspector: WebDAVClient

    init(_ devices: [SyncDevice], inspector: WebDAVClient) {
        self.devices = devices
        self.inspector = inspector
    }

    /// `count` devices under `root`, each with its own key and transport
    /// (`client(name)`); the first creates the vault (every device's key a
    /// recipient), syncs it up, and the others pull it.
    static func make(root: URL, count: Int = 2, client: (String) throws -> WebDAVClient, inspector: WebDAVClient,
                     pull: Bool = true) throws -> SyncDevices {
        var devices: [SyncDevice] = []
        for i in 0..<count {
            let name = String(UnicodeScalar(UInt8(65 + i)))
            let hex = String(repeating: String(UnicodeScalar(UInt8(97 + i))), count: 8)
            devices.append(try SyncDevice(name: name, root: root.appendingPathComponent(name), identity: pqIdentity(),
                                          client: try client(name), device: DeviceID(hex)))
        }
        _ = try Vault.create(at: devices[0].folder, recipients: devices.map(\.identity.recipient),
                             labels: devices.map(\.name), identities: [devices[0].identity])
        let set = SyncDevices(devices, inspector: inspector)
        if pull {
            try set.a.syncUntilQuiet()
            for d in devices.dropFirst() { try d.syncUntilQuiet() }
        }
        return set
    }

    /// Two devices on a vault the CLI made (`scripts/make-stress-vault.sh`):
    /// device A starts with a copy of it, B with nothing; their keys and
    /// device states are the script's.
    static func adopt(seed: URL, root: URL, client: (String) throws -> WebDAVClient, inspector: WebDAVClient) throws -> SyncDevices {
        let fm = FileManager.default
        var devices: [SyncDevice] = []
        for name in ["A", "B"] {
            let lower = name.lowercased()
            let keyText = try String(contentsOf: seed.appendingPathComponent("key-\(lower).txt"), encoding: .utf8)
            guard let line = keyText.split(separator: "\n").first(where: { $0.hasPrefix("AGE-SECRET-KEY-") }) else {
                throw VaultError.io("no key in \(seed.path)/key-\(lower).txt")
            }
            let d = try SyncDevice(name: name, root: root.appendingPathComponent(name),
                                   identity: try NativeIdentity(string: String(line)), client: try client(name))
            try fm.copyItem(at: seed.appendingPathComponent("state-\(lower)/sempere/device.json"), to: d.deviceStateURL)
            devices.append(d)
        }
        try fm.copyItem(at: seed.appendingPathComponent("Stress.sempere"), to: devices[0].folder)
        return SyncDevices(devices, inspector: inspector)
    }

    /// Every device runs two-way syncs in turn until a whole round changes nothing.
    func converge(rounds: Int = 8, file: StaticString = #filePath, line: UInt = #line) throws {
        for _ in 0..<rounds {
            var quiet = true
            for d in devices {
                let r = (try? d.sync()) ?? { var r = SyncReport(); r.errors = [.init(path: "", message: "threw")]; return r }()
                if !r.isEmpty { quiet = false }
            }
            if quiet { return }
        }
        XCTFail("no quiet round in \(rounds)", file: file, line: line)
    }

    /// Every device and the server hold the same note files, every file in
    /// `written` is among them, nothing is in flight on the server, and every
    /// device reads the same notes.
    func assertConverged(written: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let server = try SyncDevices.remoteFiles(inspector)
        let leftovers = server.filter { $0.split(separator: "/").last?.hasPrefix(".") == true }
        XCTAssertTrue(leftovers.isEmpty, "temporary files left on the server: \(leftovers.sorted())", file: file, line: line)
        let visible = server.subtracting(leftovers)
        XCTAssertTrue(visible.isSuperset(of: written), "lost on the server: \(written.subtracting(visible).sorted())",
                      file: file, line: line)
        let reference = try a.notes()
        for d in devices {
            let files = d.noteFiles()
            XCTAssertEqual(files, visible, "\(d.name): only here \(files.subtracting(visible).sorted().prefix(5)); "
                           + "only on the server \(visible.subtracting(files).sorted().prefix(5))", file: file, line: line)
            let partials = Self.hiddenFiles(in: d.folder)
            XCTAssertTrue(partials.isEmpty, "\(d.name): files in progress left: \(partials.prefix(5))", file: file, line: line)
            if d !== a { XCTAssertEqual(try d.notes(), reference, "\(d.name) reads other notes than A", file: file, line: line) }
        }
    }

    /// Hidden files under `notes/` (temporary and partial downloads).
    static func hiddenFiles(in folder: URL) -> [String] {
        let notes = folder.appendingPathComponent(Vault.notesName)
        guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
        return e.compactMap { $0 as? String }.filter { ($0 as NSString).lastPathComponent.hasPrefix(".") }
    }

    /// Every file under the remote's `notes/` (hidden names included), as `notes/<id>/...`.
    static func remoteFiles(_ client: WebDAVClient) throws -> Set<String> {
        var out = Set<String>()
        for note in try client.list([Vault.notesName]) ?? [] where note.isCollection {
            for e in try client.list([Vault.notesName, note.name]) ?? [] {
                if e.isCollection && e.name == Vault.attachmentsName {
                    for blob in try client.list([Vault.notesName, note.name, e.name]) ?? [] where !blob.isCollection {
                        out.insert("\(Vault.notesName)/\(note.name)/\(e.name)/\(blob.name)")
                    }
                } else if !e.isCollection {
                    out.insert("\(Vault.notesName)/\(note.name)/\(e.name)")
                }
            }
        }
        return out
    }
}

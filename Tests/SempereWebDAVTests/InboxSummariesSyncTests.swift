import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The capture inbox (format.md §11.4) and per-device published summaries
/// (format.md §12.5) through the engine (docs/design/device-first-sync.md §5.1,
/// §5.3), over every transport: the scenarios run in the subclasses below over
/// `MemoryRemote`, `WebDAVSyncRemote` on `MockDAV`, `FolderRemote` (plain and
/// in a simulated provider), `MemoryRemote` with every file evicted, and wsgidav.
class InboxSummariesScenarioCase: SyncTestCase {
    func transport() throws -> TransportUnderTest { throw XCTSkip("abstract") }
    func tune(_ options: inout SyncOptions) {}

    private(set) var t: TransportUnderTest!
    private var label: String { t.kind }
    let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    let started = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        t = try transport()
    }

    /// The device of each folder name.
    func device(_ name: String) -> DeviceID { name == "A" ? devA : name == "B" ? devB : DeviceID("cccccccc")! }
    func deviceState(_ name: String) -> URL { tmp.appendingPathComponent("device-\(name).json") }

    @discardableResult
    func run(_ name: String, via remote: (any SyncRemote)? = nil, locked: Bool = false, state: String? = nil,
             _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        let v: Vault? = !exists ? nil : locked ? try Vault.open(at: dir(name)) : try openVault(name)
        var o = SyncOptions(deviceLabel: name)
        o.deviceID = device(name)
        if !locked { o.firstPullIdentities = [identity] }
        tune(&o)
        edit(&o)
        return try SyncEngine(directory: dir(name), vault: v, remote: remote ?? t.remote,
                              stateURL: tmp.appendingPathComponent("state-\(state ?? name).json"), options: o).run()
    }

    /// Runs until quiet (at most `rounds`); returns the last report.
    @discardableResult
    func settle(_ name: String, rounds: Int = 6, file: StaticString = #filePath, line: UInt = #line) throws -> SyncReport {
        var last = SyncReport()
        for _ in 0..<rounds {
            last = try run(name)
            if last.isEmpty { return last }
        }
        XCTFail("\(label) \(name): never quiet: \(StressWorld.brief(last))", file: file, line: line)
        return last
    }

    /// A vault on A, uploaded, pulled by B.
    func twoDevices() throws {
        let a = try makeVault("A")
        try DeviceState(device: devA).save(to: deviceState("A"))
        try DeviceState(device: devB).save(to: deviceState("B"))
        _ = try a.apply([.setMeta(.title("first"))], to: noteID, deviceState: deviceState("A"), app: "test/0")
        try settle("A")
        try settle("B")
    }

    /// Seals a capture (and its transcript) into `name`'s inbox with that device's capture profile.
    @discardableResult
    func capture(on name: String, id: UUID = UUID(), audio: Data? = nil, transcript: Bool = false) throws -> UUID {
        let v = try openVault(name)
        let w = try CaptureWriter(profile: try v.captureProfile(device: device(name)))
        let bytes = audio ?? self.audio
        try CaptureWriter.store(try w.seal(audio: bytes, started: started, id: id), in: v.inboxURL)
        if transcript {
            let t = TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: id).recording, engine: "e", language: "en-US",
                                                 created: started, segments: [.init(start: 0, end: 1, text: "Hello.")])
            try CaptureWriter.store(try w.seal(transcript: t, capture: id, audio: BlobRef(content: bytes, type: "audio/mp4")),
                                    in: v.inboxURL)
        }
        return id
    }

    func inbox(_ name: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(name).appendingPathComponent("inbox").path)) ?? []).sorted()
    }

    /// Another writer puts `data` at `path` on the remote.
    func plant(_ path: [String], _ data: Data) throws {
        _ = try t.inspector.makeCollection(Array(path.dropLast()))
        try t.inspector.write(path, .data(data), condition: .unconditional)
    }

    func remoteInbox() throws -> [String] { (try t.inspector.list(["inbox"]) ?? []).map(\.name).sorted() }

    func adopt(_ name: String, _ id: UUID) throws -> Vault.CaptureAdoptionResult {
        let r = try openVault(name).adoptCapture(id, deviceState: deviceState(name), app: "test/0")
        XCTAssertNil(r.error, "\(label): \(r)")
        return r
    }

    // MARK: Inbox

    /// A capture made on A reaches B (checked first); B adopts it; the adopted note
    /// travels and the inbox file goes from every side, and nothing is left behind.
    func scenarioCaptureTravelsAndAdoptionClearsIt() throws {
        try twoDevices()
        let id = try capture(on: "A", transcript: true)
        let up = try run("A")
        XCTAssertEqual(up.uploaded.filter { $0.hasPrefix("inbox/") }.count, 2, "\(label): \(StressWorld.brief(up))")
        let down = try run("B")
        XCTAssertEqual(down.downloaded.filter { $0.hasPrefix("inbox/") }.count, 2, "\(label): \(StressWorld.brief(down))")
        XCTAssertEqual(inbox("B"), inbox("A"))
        let adopted = try adopt("B", id)
        XCTAssertTrue(adopted.created && adopted.transcript, "\(label): \(adopted)")
        XCTAssertEqual(inbox("B"), [])
        let push = try run("B")
        XCTAssertEqual(push.deleted.filter { $0.side == "remote" }.count, 2, "\(label): \(StressWorld.brief(push))")
        XCTAssertEqual(try remoteInbox().filter { !$0.hasPrefix(".") }, [])
        let pull = try run("A")
        XCTAssertEqual(pull.deleted.filter { $0.side == "local" }.count, 2, "\(label): \(StressWorld.brief(pull))")
        XCTAssertEqual(inbox("A"), [])
        let note = CaptureAdoption.ids(for: id).note
        XCTAssertEqual(try openVault("A").reconstruct(noteId: note).recordings.first?.transcript != nil, true, label)
        try settle("A"); try settle("B")
        XCTAssertEqual(SyncDevices.hiddenFiles(in: dir("A")), [], label)
        XCTAssertTrue(try run("A").isEmpty && run("B").isEmpty, label)
    }

    /// An inbox file gone from one side with no adoption to explain it is copied back,
    /// in both directions: nothing but adoption ever deletes one.
    func scenarioUnexplainedInboxDeletionIsRestored() throws {
        try twoDevices()
        _ = try capture(on: "A")
        try run("A"); try run("B")
        let name = try XCTUnwrap(inbox("B").first)
        try FileManager.default.removeItem(at: dir("B").appendingPathComponent("inbox/\(name)"))
        let back = try run("B")
        XCTAssertTrue(back.downloaded.contains("inbox/\(name)"), "\(label): \(StressWorld.brief(back))")
        XCTAssertTrue(back.deleted.isEmpty, label)
        try t.inspector.delete(["inbox", name])
        let again = try run("A")
        XCTAssertTrue(again.uploaded.contains("inbox/\(name)"), "\(label): \(StressWorld.brief(again))")
        XCTAssertEqual(try remoteInbox(), [name])
        XCTAssertEqual(inbox("A"), [name]); XCTAssertEqual(inbox("B"), [name])
    }

    /// A locked device uploads its captures (quick capture into a closed vault), but judges
    /// no deletion: it waits for an unlocked run, which follows the adoption.
    func scenarioLockedRunsUploadButNeverJudge() throws {
        try twoDevices()
        let id = try capture(on: "A")
        let up = try run("A", locked: true)
        XCTAssertEqual(up.uploaded.filter { $0.hasPrefix("inbox/") }.count, 1, "\(label): \(StressWorld.brief(up))")
        try run("B")
        _ = try adopt("B", id)
        try run("B")
        let locked = try run("A", locked: true)
        XCTAssertTrue(locked.deleted.isEmpty && locked.uploaded.filter { $0.hasPrefix("inbox/") }.isEmpty,
                      "\(label): \(StressWorld.brief(locked))")
        XCTAssertTrue(locked.skipped.contains { $0.path.hasPrefix("inbox/") }, "\(label): \(locked.skipped)")
        XCTAssertEqual(inbox("A").count, 1)
        let unlocked = try run("A")
        XCTAssertEqual(unlocked.deleted.map(\.side), ["local"], "\(label): \(StressWorld.brief(unlocked))")
        XCTAssertEqual(inbox("A"), [])
        XCTAssertEqual(try remoteInbox().filter { !$0.hasPrefix(".") }, [])
    }

    /// A file under an inbox name that is not a capture of this vault is quarantined, never placed,
    /// and not fetched again while unchanged.
    func scenarioForgedInboxFileIsQuarantined() throws {
        try twoDevices()
        let name = CaptureFile.name(UUID(), .capture)
        let forged = try Vault.encrypt(Data("SMPC junk".utf8), to: [identity.recipient])
        try plant(["inbox", name], forged)
        let r = try run("B")
        XCTAssertEqual(r.quarantined.map(\.path), ["inbox/\(name)"], "\(label): \(StressWorld.brief(r))")
        XCTAssertEqual(inbox("B"), [])
        let again = try run("B")
        XCTAssertTrue(again.quarantined.isEmpty && again.downloaded.isEmpty, "\(label): \(StressWorld.brief(again))")
        XCTAssertEqual(try remoteInbox(), [name], "\(label): a forged file is never deleted from the remote")
    }

    /// A large capture over a transport that cuts bodies: no half file ever appears in an inbox
    /// (here or there), the run is retried, and the capture arrives whole.
    func scenarioLargeCaptureThroughCutTransfers() throws {
        try twoDevices()
        var big = Data(count: 6 << 20)
        for i in stride(from: 0, to: big.count, by: 4096) { big[i] = UInt8(truncatingIfNeeded: i >> 12) }
        let id = try capture(on: "A", audio: big)
        let flaky = t.faulty(7, TransportFaults(dropBefore: 0.3, loseAnswer: 0.2, cutBody: 0.5, only: { $0.first == "inbox" }))
        for _ in 0..<12 {
            _ = try? run("A", via: flaky)
            _ = try? run("B", via: flaky)
            for f in inbox("B") { XCTAssertFalse(f.hasSuffix(".age") && !inbox("A").contains(f), "\(label): \(f)") }
            if inbox("B").contains(CaptureFile.name(id, .capture)) { break }
        }
        try settle("A"); try settle("B")
        XCTAssertEqual(inbox("B").filter { !$0.hasPrefix(".") }, [CaptureFile.name(id, .capture)], label)
        XCTAssertEqual(try openVault("B").readCapture(id).audio, big, label)
        XCTAssertEqual(try remoteInbox(), [CaptureFile.name(id, .capture)], "\(label): no temporary name left")
    }

    /// Two devices adopt the same capture while offline: the derived ids make them write the
    /// same note, and once both sync every inbox is empty and both read one recording.
    func scenarioTwoDevicesAdoptTheSameCaptureOffline() throws {
        try twoDevices()
        let id = try capture(on: "A", transcript: true)
        try run("A"); try run("B")
        _ = try adopt("A", id)
        _ = try adopt("B", id)
        for _ in 0..<3 { try run("A"); try run("B") }
        try settle("A"); try settle("B")
        XCTAssertEqual(inbox("A"), []); XCTAssertEqual(inbox("B"), [])
        XCTAssertEqual(try remoteInbox().filter { !$0.hasPrefix(".") }, [])
        let note = CaptureAdoption.ids(for: id).note
        let a = try openVault("A").reconstruct(noteId: note), b = try openVault("B").reconstruct(noteId: note)
        XCTAssertEqual(a, b, label)
        XCTAssertEqual(a.recordings.count, 1, label)
    }

    /// A push-only run (the web viewer's mirror) uploads inbox files and never downloads one.
    func scenarioPushOnlyNeverDownloads() throws {
        try twoDevices()
        _ = try capture(on: "A")
        let mirror = try run("A") { $0.pushOnly = true }
        XCTAssertEqual(mirror.uploaded.filter { $0.hasPrefix("inbox/") }.count, 1, label)
        let other = try run("B") { $0.pushOnly = true }
        XCTAssertTrue(other.downloaded.isEmpty, "\(label): \(StressWorld.brief(other))")
        XCTAssertEqual(inbox("B"), [])
    }

    // MARK: Per-device summaries

    func publish(_ name: String) throws -> Data {
        let v = try openVault(name)
        return try v.writeDevicePublishedSummaries(try v.publishedSummaryEntries().entries, device: device(name))
    }

    func summaries(_ name: String) -> [String: Data] {
        let d = dir(name).appendingPathComponent("summaries")
        var out: [String: Data] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where !n.hasPrefix(".") {
            out[n] = try? Data(contentsOf: d.appendingPathComponent(n))
        }
        return out
    }

    /// Each device's file reaches the other, a newer one replaces the older, and a device's
    /// own file is never taken from the remote: one changed there is put back.
    func scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A")
        try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a1, label)
        let b1 = try publish("B")
        try run("B"); try run("A")
        XCTAssertEqual(summaries("A")["bbbbbbbb.sealed"], b1, label)
        let a2 = try publish("A")
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, "\(label): the newer copy replaces the older")
        // Another writer replaces A's file on the remote: A puts its own back and keeps it. (wsgidav keeps
        // an ETag over a same-size rewrite within its second: the change is seen once the token moves.)
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(b1), condition: .unconditional)
        let r = try run("A")
        XCTAssertTrue(r.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(r))")
        XCTAssertEqual(summaries("A")["aaaaaaaa.sealed"], a2)
        XCTAssertEqual(try t.inspector.read(["summaries", "aaaaaaaa.sealed"], maxBytes: 1 << 26).data, a2, label)
        try settle("A"); try settle("B")
    }

    /// A per-device file that does not open under the vault's secret is not placed (a hint only).
    func scenarioForeignSummariesAreNotPlaced() throws {
        try twoDevices()
        try plant(["summaries", "cccccccc.sealed"], Data("SMPU".utf8) + Data([1]) + Data(count: 64))
        try plant(["summaries", "not-a-device.sealed"], Data("x".utf8))
        let r = try run("B")
        XCTAssertTrue(r.skipped.contains { $0.path == "summaries/cccccccc.sealed" }, "\(label): \(r.skipped)")
        XCTAssertTrue(r.ignored.contains("summaries/not-a-device.sealed"), "\(label): \(r.ignored)")
        XCTAssertEqual(summaries("B"), [:])
    }

    func version(_ data: Data?, of name: String) throws -> Int64? {
        guard let data else { return nil }
        return try openVault("A").openDevicePublishedSummaries(data, device: device(name)).version
    }

    /// Another device's file is ordered by the version inside it, never by which side changed: a bridge
    /// that puts an older copy on the remote (it changed there since B's last run) does not make B take it,
    /// B puts the later one back; and a push-only run never replaces a later copy with an older one.
    func scenarioAnOlderCopyNeverReplacesANewer() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        let a2 = try publish("A")
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
        XCTAssertGreaterThan(try XCTUnwrap(try version(a2, of: "A")), try XCTUnwrap(try version(a1, of: "A")))
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(a1), condition: .unconditional)
        let r = try run("B")
        XCTAssertTrue(r.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(r))")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
        XCTAssertEqual(try t.inspector.read(["summaries", "aaaaaaaa.sealed"], maxBytes: 1 << 26).data, a2, label)

        // B holds the older copy again (a restore): a push-only run leaves the remote's later one alone,
        // and a two-way run takes it.
        try a1.write(to: dir("B").appendingPathComponent("summaries/aaaaaaaa.sealed"))
        let mirror = try run("B") { $0.pushOnly = true }
        XCTAssertFalse(mirror.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(mirror))")
        XCTAssertEqual(try t.inspector.read(["summaries", "aaaaaaaa.sealed"], maxBytes: 1 << 26).data, a2, label)
        try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
        try settle("A"); try settle("B")
    }

    func remoteA() throws -> Data { try t.inspector.read(["summaries", "aaaaaaaa.sealed"], maxBytes: 1 << 26).data }
    var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Review of #83 (S1): another key holder seals A's file at the version cap. Beyond the 7-day window it
    /// is no version: it never wins, B takes A's real file back, and the runs go quiet at once.
    func scenarioAForgedCapVersionNeverWins() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        let forged = try openVault("B").sealPublishedSummaries(
            PublishedSummaries.Contents(entries: [:], device: device("A"), version: PublishedSummaries.maxVersion))
        try forged.write(to: dir("B").appendingPathComponent("summaries/aaaaaaaa.sealed"))
        var uploads = 0
        for _ in 0..<5 {
            for name in ["A", "B"] where try run(name).uploaded.contains("summaries/aaaaaaaa.sealed") { uploads += 1 }
        }
        XCTAssertEqual(uploads, 0, label)
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a1, "\(label): B takes A's real file back")
        XCTAssertEqual(try remoteA(), a1, label)
        try settle("A"); try settle("B")
    }

    /// Review of #83 (S1): a forged copy one below the cap, put on the remote, is no version either: A puts
    /// its own back and goes on writing ordinary versions.
    func scenarioAForgedNearCapVersionDoesNotFreezeTheOwner() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        let forged = try openVault("B").sealPublishedSummaries(
            PublishedSummaries.Contents(entries: [:], device: device("A"), version: PublishedSummaries.maxVersion - 1))
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(forged), condition: .unconditional)
        let r = try run("A")
        XCTAssertTrue(r.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(r))")
        XCTAssertEqual(summaries("A")["aaaaaaaa.sealed"], a1, "\(label): A's own file is untouched")
        XCTAssertEqual(try remoteA(), a1, label)
        let a2 = try publish("A")
        let v2 = try XCTUnwrap(try version(a2, of: "A"))
        XCTAssertLessThan(v2, nowMillis + 1000, "\(label): an ordinary version, nowhere near the cap")
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
        try settle("A"); try settle("B")
    }

    /// Review of #83 (M2): a copy B cannot open whose clear header names a later epoch (here sealed under
    /// another vault's key with epoch 2 in the header, as a copy of a later epoch is for a removed or lagging
    /// device) is never replaced by B's older readable one, nor by the owner; B reports it and goes quiet.
    /// One of B's own epoch that does not open (damaged, cut short by a server) is replaced.
    func scenarioALaterEpochCopyIsNeverReplaced() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a1, label)
        let a = try openVault("A"), other = try makeVault("X")
        func sealed(epoch: Int) throws -> Data {
            let json = try PublishedSummaries.encode([:], vaultId: a.vaultId, device: device("A"), version: nowMillis + 10_000)
            return try PublishedSummaries.seal(try Gzip.compress(json), secret: try other.requireSecret(), vaultId: a.vaultId,
                                               epoch: epoch)
        }
        let later = try sealed(epoch: a.manifest.epoch + 1)
        XCTAssertEqual(PublishedSummaries.sealedEpoch(later), a.manifest.epoch + 1)
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(later), condition: .unconditional)
        let r = try run("B")
        XCTAssertFalse(r.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(r))")
        XCTAssertTrue(r.skipped.contains { $0.path == "summaries/aaaaaaaa.sealed" }, "\(label): \(r.skipped)")
        XCTAssertEqual(try remoteA(), later, label)
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a1, label)
        // The owner leaves it too (it may be its own file under a key it no longer holds).
        XCTAssertFalse(try run("A").uploaded.contains("summaries/aaaaaaaa.sealed"), label)
        XCTAssertEqual(try remoteA(), later, label)
        try settle("A"); try settle("B")

        // Of this epoch but not opening (damaged): replaced by the readable copy.
        let damaged = try sealed(epoch: a.manifest.epoch)
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(damaged), condition: .unconditional)
        XCTAssertTrue(try run("B").uploaded.contains("summaries/aaaaaaaa.sealed"), label)
        XCTAssertEqual(try remoteA(), a1, label)
        try settle("A"); try settle("B")
    }

    /// Review of #83 (M1): a per-device file without `device` and `version` (what `vault summaries
    /// --device-file` wrote before) is never placed; the file `writeDevicePublishedSummaries` writes (what
    /// it writes now) is.
    func scenarioOnlyAVersionedDeviceFileTravels() throws {
        try twoDevices()
        let v = try openVault("A")
        let entries = try v.publishedSummaryEntries().entries
        let unversioned = try v.sealPublishedSummaries(entries)
        let url = v.devicePublishedSummariesURL(device("A"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try unversioned.write(to: url)
        try run("A")
        try run("B")
        XCTAssertNil(summaries("B")["aaaaaaaa.sealed"], label)
        let versioned = try v.writeDevicePublishedSummaries(entries, device: device("A"))
        try run("A"); try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], versioned, label)
        try settle("A"); try settle("B")
    }

    /// A copy forged within the window, or one written by another install with A's device id, is ordered
    /// after A's own: A leaves it rather than rewriting above it (two installs would otherwise outbid each
    /// other on every run), and the runs go quiet. It holds until A writes a later version (at most the window).
    func scenarioALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() throws {
        try twoDevices()
        let a1 = try publish("A")
        try run("A"); try run("B")
        let ahead = try openVault("B").sealPublishedSummaries(
            PublishedSummaries.Contents(entries: [:], device: device("A"), version: nowMillis + 3_600_000))
        if t.deviations.contains(.etagKeepsTheSecond) { Thread.sleep(forTimeInterval: 1.1) }
        try t.inspector.write(["summaries", "aaaaaaaa.sealed"], .data(ahead), condition: .unconditional)
        let r = try run("A")
        XCTAssertFalse(r.uploaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(r))")
        XCTAssertEqual(summaries("A")["aaaaaaaa.sealed"], a1, "\(label): A's own file is never taken")
        try run("B")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], ahead, label)
        try settle("A"); try settle("B")
        XCTAssertEqual(try remoteA(), ahead, label)
    }

    /// Locked, nothing is ordered: a two-way locked run leaves a differing copy; a locked staging run
    /// (pull-only) stages the remote copy for the placing run to order (review of #83, nit).
    func scenarioLockedRunsLeaveAndStagingStages() throws {
        try twoDevices()
        _ = try publish("A")
        try run("A"); try run("B")
        let a2 = try publish("A")
        try run("A")
        let left = try run("B", locked: true)
        XCTAssertFalse(left.downloaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(left))")
        XCTAssertNotEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
        let staged = try run("B", locked: true, state: "B-staging") { $0.pullOnly = true }
        XCTAssertTrue(staged.downloaded.contains("summaries/aaaaaaaa.sealed"), "\(label): \(StressWorld.brief(staged))")
        XCTAssertEqual(summaries("B")["aaaaaaaa.sealed"], a2, label)
    }

    /// A device with two targets carries another device's newer file from one to the other.
    func scenarioABridgeCarriesSummaries() throws {
        try twoDevices()
        let second = MemoryRemote(store: MemoryStore(name: "second"), base: ["vault"])
        try run("A", via: second, state: "A-second")
        let b1 = try publish("B")
        try run("B"); try run("A"); try run("A", via: second, state: "A-second")
        XCTAssertEqual(try second.read(["summaries", "bbbbbbbb.sealed"], maxBytes: 1 << 26).data, b1, label)
        let b2 = try publish("B")
        try run("B"); try run("A"); try run("A", via: second, state: "A-second")
        XCTAssertEqual(try second.read(["summaries", "bbbbbbbb.sealed"], maxBytes: 1 << 26).data, b2, label)
        XCTAssertTrue(try run("A", via: second, state: "A-second").isEmpty, label)
    }
}

final class InboxSummariesOverMemoryTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { .memory() }

    /// Found by the N-device stress run: two devices that both sync two remotes handed an adopted
    /// capture back and forth (one deleted it from a remote, the other uploaded it there again from
    /// the other remote, where its record was gone). A file adoption explains is never copied.
    func testTwoBridgesSettleAnAdoptedCapture() throws {
        let r0 = MemoryRemote(store: MemoryStore(name: "R0"), base: ["vault"])
        let r1 = MemoryRemote(store: MemoryStore(name: "R1"), base: ["vault"])
        let ids = [pqIdentity(), pqIdentity()]
        let x = try SyncDevice(name: "X", root: tmp.appendingPathComponent("X"), identity: ids[0], remote: r0,
                               device: DeviceID("aaaaaaaa"))
        let y = try SyncDevice(name: "Y", root: tmp.appendingPathComponent("Y"), identity: ids[1], remote: r0,
                               device: DeviceID("bbbbbbbb"))
        _ = try TestVaults.create(at: x.folder, identities: ids, names: ["X", "Y"])
        let runs: [(SyncDevice, MemoryRemote, String)] = [(x, r0, "R0"), (x, r1, "R1"), (y, r1, "R1"), (y, r0, "R0")]
        func round() throws -> [String] {
            try runs.compactMap { d, r, name in
                let rep = try d.sync(via: r, state: d.root.appendingPathComponent("sync-\(name).json"))
                return rep.isEmpty ? nil : "\(d.name)/\(name): \(StressWorld.brief(rep))"
            }
        }
        for _ in 0..<3 { _ = try round() }
        let id = try x.captureVoiceNote(audio)
        _ = try round()
        // X adopts between its two runs, as a device does whenever it unlocks.
        try x.sync(via: r0, state: x.root.appendingPathComponent("sync-R0.json"))
        XCTAssertEqual(try x.adoptInbox(), 1)
        var quiet = false
        var last: [String] = []
        for _ in 0..<6 where !quiet {
            last = try round()
            quiet = last.isEmpty
        }
        XCTAssertTrue(quiet, "never quiet: \(last.joined(separator: "\n"))")
        for d in [x, y] { XCTAssertEqual(d.rootFolderFiles("inbox"), [:], d.name) }
        for r in [r0, r1] { XCTAssertEqual((try r.list(["inbox"]) ?? []).filter { !$0.name.hasPrefix(".") }, [], r.location) }
        XCTAssertEqual(try y.vault().reconstruct(noteId: CaptureAdoption.ids(for: id).note).recordings.count, 1)
    }

    /// A run killed while it checked a received capture leaves its staging folder in `inbox/`
    /// (hidden: no reader lists it). A later run removes it once it is an hour old, and the
    /// capture arrives whole.
    func testAKilledRunsStagingFolderIsCleanedUp() throws {
        try twoDevices()
        let id = try capture(on: "A")
        try run("A")
        let stage = dir("B").appendingPathComponent("inbox/.sempere-tmp-killed", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: stage.appendingPathComponent(CaptureFile.name(id, .capture)))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stage.path)
        XCTAssertEqual(try openVault("B").inboxEntries().map(\.id), [], "a staging folder is no inbox entry")
        try run("B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(inbox("B"), [CaptureFile.name(id, .capture)])
        XCTAssertEqual(try openVault("B").readCapture(id).audio, audio)
    }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testLockedRunsUploadButNeverJudge() throws { try scenarioLockedRunsUploadButNeverJudge() }
    func testForgedInboxFileIsQuarantined() throws { try scenarioForgedInboxFileIsQuarantined() }
    func testLargeCaptureThroughCutTransfers() throws { try scenarioLargeCaptureThroughCutTransfers() }
    func testTwoDevicesAdoptTheSameCaptureOffline() throws { try scenarioTwoDevicesAdoptTheSameCaptureOffline() }
    func testPushOnlyNeverDownloads() throws { try scenarioPushOnlyNeverDownloads() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
    func testForeignSummariesAreNotPlaced() throws { try scenarioForeignSummariesAreNotPlaced() }
    func testABridgeCarriesSummaries() throws { try scenarioABridgeCarriesSummaries() }
    func testAnOlderCopyNeverReplacesANewer() throws { try scenarioAnOlderCopyNeverReplacesANewer() }
    func testAForgedCapVersionNeverWins() throws { try scenarioAForgedCapVersionNeverWins() }
    func testAForgedNearCapVersionDoesNotFreezeTheOwner() throws { try scenarioAForgedNearCapVersionDoesNotFreezeTheOwner() }
    func testALaterEpochCopyIsNeverReplaced() throws { try scenarioALaterEpochCopyIsNeverReplaced() }
    func testOnlyAVersionedDeviceFileTravels() throws { try scenarioOnlyAVersionedDeviceFileTravels() }
    func testALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() throws { try scenarioALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() }
    func testLockedRunsLeaveAndStagingStages() throws { try scenarioLockedRunsLeaveAndStagingStages() }
}

final class InboxSummariesOverWebDAVMockTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { try .mockDAV() }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testLockedRunsUploadButNeverJudge() throws { try scenarioLockedRunsUploadButNeverJudge() }
    func testForgedInboxFileIsQuarantined() throws { try scenarioForgedInboxFileIsQuarantined() }
    func testLargeCaptureThroughCutTransfers() throws { try scenarioLargeCaptureThroughCutTransfers() }
    func testTwoDevicesAdoptTheSameCaptureOffline() throws { try scenarioTwoDevicesAdoptTheSameCaptureOffline() }
    func testPushOnlyNeverDownloads() throws { try scenarioPushOnlyNeverDownloads() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
    func testForeignSummariesAreNotPlaced() throws { try scenarioForeignSummariesAreNotPlaced() }
    func testABridgeCarriesSummaries() throws { try scenarioABridgeCarriesSummaries() }
    func testAnOlderCopyNeverReplacesANewer() throws { try scenarioAnOlderCopyNeverReplacesANewer() }
    func testAForgedCapVersionNeverWins() throws { try scenarioAForgedCapVersionNeverWins() }
    func testAForgedNearCapVersionDoesNotFreezeTheOwner() throws { try scenarioAForgedNearCapVersionDoesNotFreezeTheOwner() }
    func testALaterEpochCopyIsNeverReplaced() throws { try scenarioALaterEpochCopyIsNeverReplaced() }
    func testOnlyAVersionedDeviceFileTravels() throws { try scenarioOnlyAVersionedDeviceFileTravels() }
    func testALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() throws { try scenarioALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() }
    func testLockedRunsLeaveAndStagingStages() throws { try scenarioLockedRunsLeaveAndStagingStages() }
}

final class InboxSummariesOverFolderTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { .folder(tmp.appendingPathComponent("remote")) }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testLockedRunsUploadButNeverJudge() throws { try scenarioLockedRunsUploadButNeverJudge() }
    func testForgedInboxFileIsQuarantined() throws { try scenarioForgedInboxFileIsQuarantined() }
    func testLargeCaptureThroughCutTransfers() throws { try scenarioLargeCaptureThroughCutTransfers() }
    func testTwoDevicesAdoptTheSameCaptureOffline() throws { try scenarioTwoDevicesAdoptTheSameCaptureOffline() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
    func testABridgeCarriesSummaries() throws { try scenarioABridgeCarriesSummaries() }
    func testAnOlderCopyNeverReplacesANewer() throws { try scenarioAnOlderCopyNeverReplacesANewer() }
    func testAForgedCapVersionNeverWins() throws { try scenarioAForgedCapVersionNeverWins() }
    func testAForgedNearCapVersionDoesNotFreezeTheOwner() throws { try scenarioAForgedNearCapVersionDoesNotFreezeTheOwner() }
    func testALaterEpochCopyIsNeverReplaced() throws { try scenarioALaterEpochCopyIsNeverReplaced() }
    func testOnlyAVersionedDeviceFileTravels() throws { try scenarioOnlyAVersionedDeviceFileTravels() }
    func testALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() throws { try scenarioALaterCopyOfTheOwnFileIsLeftAndRunsGoQuiet() }
    func testLockedRunsLeaveAndStagingStages() throws { try scenarioLockedRunsLeaveAndStagingStages() }
}

final class InboxSummariesOverEvictingFolderTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { TransportUnderTest.evictingFolder(tmp.appendingPathComponent("remote")).0 }
    override func tune(_ options: inout SyncOptions) { options.unlistedTimeout = 0 }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testLockedRunsUploadButNeverJudge() throws { try scenarioLockedRunsUploadButNeverJudge() }
    func testTwoDevicesAdoptTheSameCaptureOffline() throws { try scenarioTwoDevicesAdoptTheSameCaptureOffline() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
}

final class InboxSummariesOverEvictedMemoryTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { .evictedMemory() }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testTwoDevicesAdoptTheSameCaptureOffline() throws { try scenarioTwoDevicesAdoptTheSameCaptureOffline() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
}

final class InboxSummariesOverWsgidavTests: InboxSummariesScenarioCase {
    override func transport() throws -> TransportUnderTest { try .wsgidav() }
    func testCaptureTravelsAndAdoptionClearsIt() throws { try scenarioCaptureTravelsAndAdoptionClearsIt() }
    func testUnexplainedInboxDeletionIsRestored() throws { try scenarioUnexplainedInboxDeletionIsRestored() }
    func testLargeCaptureThroughCutTransfers() throws { try scenarioLargeCaptureThroughCutTransfers() }
    func testDeviceSummariesTravelAndOwnFileIsNeverTaken() throws { try scenarioDeviceSummariesTravelAndOwnFileIsNeverTaken() }
}

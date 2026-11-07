import Age
import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing
import VaultTestSupport

/// Quick voice notes' rules that need no recorder (docs/quick-capture.md): a recording folder's segments, what a seal
/// may delete, and where a sealed capture goes. The recorder, the Live Activity and the full start/stop/sweep flow:
/// `QuickCaptureTests`, `QuickCaptureRobustnessTests` (SempereAppTests).
struct QuickCaptureLogicTests {
    static func tempDir(_ name: String = "capture") throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Segments

    @Test func segmentFilesAreTheSessionsOwnInOrder() throws {
        #expect(CaptureSegments.number("segment-007.m4a") == 7)
        #expect(CaptureSegments.number("segment-007.aac") == 7)
        #expect(CaptureSegments.number("segment-1000.m4a") == 1000)
        for name in ["capture.m4a", "manifest.json", "segment-.m4a", "segment-1a.m4a", "segment-+1.m4a", "segment-001.caf",
                     "../segment-001.m4a"] {
            #expect(CaptureSegments.number(name) == nil, "\(name)")
        }
        let folder = try Self.tempDir("segments")
        for name in ["segment-1000.m4a", "segment-999.m4a", "segment-001.m4a", "capture.m4a", "manifest.json"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        let listed = [folder.appendingPathComponent("segment-001.m4a")]
        #expect(CaptureSegments.files(listed: listed, in: folder).map(\.lastPathComponent)
                == ["segment-001.m4a", "segment-999.m4a", "segment-1000.m4a"])
        let manifest = RecordingManifest(note: UUID(), recording: UUID(), started: nil, codec: "aac",
                                         segments: ["../../escape.m4a", "segment-001.m4a"], finished: 5)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        let leftover = try #require(CaptureSegments.Leftover(folder: folder))
        #expect(leftover.id == manifest.recording)
        #expect(leftover.segments.map(\.lastPathComponent) == ["segment-001.m4a", "segment-999.m4a", "segment-1000.m4a"])
        #expect(leftover.finished == 1, "never more than the manifest lists")
    }

    /// Without a manifest: the folder's name is the id, and every segment but the last counts as complete.
    @Test func aLeftoverWithoutAManifestIsReadFromItsFiles() throws {
        let id = UUID()
        let folder = try Self.tempDir().appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["segment-002.aac", "segment-001.aac"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
        let leftover = try #require(CaptureSegments.Leftover(folder: folder))
        #expect(leftover.id == id)
        #expect(leftover.segments.map(\.lastPathComponent) == ["segment-001.aac", "segment-002.aac"])
        #expect(leftover.finished == 1)
        // A garbled manifest is read the same way.
        try Data("not json".utf8).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        #expect(try #require(CaptureSegments.Leftover(folder: folder)).id == id)
    }

    /// The seal's rule (docs/quick-capture.md): a folder goes unsealed only when nothing was recorded; a complete
    /// segment that does not decode, or bytes of which nothing decodes, keep it; only an unfinished last segment may
    /// be left out.
    @Test func aSealNeverDeletesAudioItDidNotSeal() {
        let a = URL(fileURLWithPath: "/r/segment-001.aac"), b = URL(fileURLWithPath: "/r/segment-002.aac")
        #expect(CaptureSegments.plan(held: [], listed: [], finished: nil) == .nothingRecorded)
        #expect(CaptureSegments.plan(held: [(a, .none), (b, .none)], listed: [a, b], finished: 2) == .nothingRecorded)
        #expect(CaptureSegments.plan(held: [(a, .undecodable), (b, .audio)], listed: [a, b], finished: 1)
                == .completeSegmentUndecodable("segment-001.aac"))
        #expect(CaptureSegments.plan(held: [(a, .audio), (b, .undecodable)], listed: [a, b], finished: 1) == .seal([a]),
                "the unfinished last one is left out")
        #expect(CaptureSegments.plan(held: [(a, .audio), (b, .undecodable)], listed: [a, b], finished: nil)
                == .completeSegmentUndecodable("segment-002.aac"), "all listed are complete without a count")
        #expect(CaptureSegments.plan(held: [(a, .undecodable)], listed: [a], finished: 0) == .noReadableAudio)
        #expect(CaptureSegments.plan(held: [(a, .none), (b, .audio)], listed: [a, b], finished: 2) == .seal([b]))
        #expect(CaptureSegments.SealPlan.nothingRecorded.discardsFolder)
        #expect(!CaptureSegments.SealPlan.noReadableAudio.discardsFolder)
    }

    /// ADTS segments, AAC for Apple Lossless (ADTS carries only AAC).
    @Test func voiceNotesRecordADTSInAAC() {
        #expect(CaptureSegments.segmentExtension == "aac")
        #expect(CaptureSegments.captureFormat(RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 48_000, channels: 1)) == .default)
        let he = RecordingFormat(codec: .heAAC, bitRate: 32_000, sampleRate: 48_000, channels: 1)
        #expect(CaptureSegments.captureFormat(he) == he)
    }

    @Test func theSettingsListWhatKeepsVoiceNotesFromRecording() {
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: true, microphoneDenied: false).isEmpty)
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: false, microphoneDenied: true) == [.liveActivitiesOff, .microphoneDenied])
    }

    @Test func theMemoryStoreKeepsOneProfile() throws {
        let store = MemoryCaptureProfileStore()
        #expect(try store.load() == nil)
        let (_, stored) = try Self.profile(in: try Self.tempDir())
        try store.save(stored)
        #expect(try store.load() == stored)
        try store.delete()
        #expect(try store.load() == nil)
    }

    // MARK: - Delivery

    /// A vault in `dir` and a stored capture profile of it (its bookmark a path bookmark).
    static func profile(in dir: URL) throws -> (URL, StoredCaptureProfile) {
        let identity = try NativeIdentity.generate(.postQuantum)
        let url = dir.appendingPathComponent("sample.sempere")
        let vault = try TestVaults.create(at: url, identities: [identity])
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        return (url, StoredCaptureProfile(profile: profile, vaultName: "sample",
                                          bookmark: try PathBookmarks().bookmark(for: url), transcribe: false))
    }

    static func delivery(_ dir: URL, ledger: MemoryWriteLedger? = nil, delivered: Box? = nil) -> CaptureDelivery {
        var ledgerFor: (@Sendable (UUID) -> any WriteLedgerStore)?
        if let ledger { ledgerFor = { _ in ledger } }
        return CaptureDelivery(queueRoot: dir.appendingPathComponent("queue"), vaultStore: nil, bookmarks: PathBookmarks(),
                               ledger: ledgerFor, delivered: { id in delivered?.add(id) })
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID] = []
        func add(_ id: UUID) { lock.withLock { values.append(id) } }
        var all: [UUID] { lock.withLock { values } }
    }

    static func seal(_ stored: StoredCaptureProfile) throws -> SealedCapture {
        try CaptureWriter(profile: stored.profile).seal(audio: Data("audio".utf8), started: Date(), id: UUID())
    }

    static func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Into the vault's inbox, recorded in its ledger first, and the app told.
    @Test func aReachableVaultGetsTheCaptureInItsInbox() throws {
        let dir = try Self.tempDir()
        let (url, stored) = try Self.profile(in: dir)
        let ledger = MemoryWriteLedger()
        let told = Box()
        let delivery = Self.delivery(dir, ledger: ledger, delivered: told)
        let sealed = try Self.seal(stored)
        #expect(try delivery.deliver(sealed, stored) == .vault)
        #expect(Self.names(url.appendingPathComponent("inbox")) == [sealed.name])
        #expect(try ledger.entries().map(\.path) == ["inbox/\(sealed.name)"])
        #expect(told.all == [stored.profile.vaultId])
    }

    /// The bookmark names a folder that is not the vault: queued with its epoch, then moved in by a flush.
    @Test func anUnreachableVaultQueuesTheCaptureWithItsEpoch() throws {
        let dir = try Self.tempDir()
        let (url, original) = try Self.profile(in: dir)
        var stored = original
        stored.bookmark = try PathBookmarks().bookmark(for: try Self.tempDir("not-the-vault"))
        let ledger = MemoryWriteLedger()
        let delivery = Self.delivery(dir, ledger: ledger)
        let sealed = try Self.seal(stored)
        #expect(try delivery.deliver(sealed, stored) == .queued)
        let queue = delivery.queueFolder(stored.profile.vaultId)
        #expect(Self.names(queue) == [sealed.name, sealed.name + ".epoch"])
        let epoch = try #require(CaptureDelivery.queuedEpoch(queue.appendingPathComponent(sealed.name)))
        #expect(epoch.0 == stored.profile.epoch)
        #expect(Self.names(url.appendingPathComponent("inbox")).isEmpty)
        // The profile moves on to a later epoch: the flush records the one it was sealed under (review M4).
        var later = original
        later.profile.epoch += 1
        #expect(delivery.flushQueue(into: url, vaultId: stored.profile.vaultId, profile: later.profile,
                                    files: UncoordinatedFiles()) == 1)
        #expect(Self.names(url.appendingPathComponent("inbox")) == [sealed.name])
        #expect(Self.names(queue).isEmpty, "the sidecar goes with the file")
        #expect(try ledger.entries().first?.epoch == original.profile.epoch)
    }

    /// With a ledger and no profile of the vault, nothing is placed unrecorded.
    @Test func aFlushWithoutAProfileLeavesTheQueue() throws {
        let dir = try Self.tempDir()
        let (url, original) = try Self.profile(in: dir)
        var stored = original
        stored.bookmark = Data("not a bookmark".utf8)
        let delivery = Self.delivery(dir, ledger: MemoryWriteLedger())
        #expect(try delivery.deliver(try Self.seal(stored), stored) == .queued)
        #expect(delivery.flushQueue(into: url, vaultId: stored.profile.vaultId, profile: nil, files: nil) == 0)
        #expect(delivery.flushQueue(of: original) == 1, "the stored profile's vault, by its bookmark")
    }

    /// Security review 2026-10 (N2): a vault whose `vault.json` names a newer format is read-only for this version
    /// (format.md §7.3), so a voice note for it waits in the queue, and the queue is not flushed into it.
    @Test func aReadOnlyVaultGetsNoCaptures() throws {
        let dir = try Self.tempDir()
        let (url, stored) = try Self.profile(in: dir)
        let manifest = url.appendingPathComponent("vault.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        obj["format"] = "sempere/9"
        try JSONSerialization.data(withJSONObject: obj).write(to: manifest)
        #expect(!CaptureDelivery.acceptsCaptures(at: url, vaultId: stored.profile.vaultId))
        #expect(!CaptureDelivery.acceptsCaptures(at: dir, vaultId: stored.profile.vaultId))
        let delivery = Self.delivery(dir)
        #expect(try delivery.deliver(try Self.seal(stored), stored) == .queued)
        #expect(delivery.flushQueue(into: url, vaultId: stored.profile.vaultId, profile: stored.profile, files: nil) == 0)
        #expect(Self.names(url.appendingPathComponent("inbox")).isEmpty)
    }

    @Test func aSidecarThatDoesNotParseNamesNoEpoch() throws {
        let file = try Self.tempDir().appendingPathComponent("x.capture.age")
        for text in ["", "1", "x \(String(repeating: "ab", count: 32))", "1 abc", "1 \(String(repeating: "zz", count: 32))"] {
            try Data(text.utf8).write(to: CaptureDelivery.epochSidecar(file))
            #expect(CaptureDelivery.queuedEpoch(file) == nil, "\(text)")
        }
    }
}

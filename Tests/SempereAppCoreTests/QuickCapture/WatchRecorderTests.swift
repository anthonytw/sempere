import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereCapture
import SempereCaptureShared
import TempDirSupport
import Testing
import VaultTestSupport

/// The Apple Watch's recorder state machine (docs/design/1.1-watch.md §3.5) over the quick voice note fakes
/// (`CaptureTestKit`): start, stop and seal into the outbox, an interruption, a crash leftover, a seal that fails, the
/// 60 minute limit and a full outbox.
@Suite(.serialized)
@MainActor
struct WatchRecorderTests {
    /// ADTS frames (24 kHz mono AAC-LC headers, payloads that are never decoded).
    static func adts(frames: Int, seed: UInt8 = 1) -> Data {
        var d = Data()
        for i in 0..<frames {
            let length = 7 + 24 + (i % 5)
            d.append(contentsOf: [0xFF, 0xF1, 0x58, UInt8(0x40 | ((length >> 11) & 3)), UInt8((length >> 3) & 0xFF),
                                  UInt8(((length & 7) << 5) | 0x1F), 0xFC])
            d.append(contentsOf: (7..<length).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 3) })
        }
        return d
    }

    @MainActor
    final class Rig {
        let clock = CaptureClock()
        let audio: FakeAudio
        let outbox: WatchOutbox
        let recorder: WatchRecorder
        let keeper = MemoryRecordingProfileKeeper()
        let root = CaptureFixture.temp("watch-root")
        let status = CaptureFixture.temp("watch-status")
        let vault: URL
        let identity: NativeIdentity
        var payload: WatchProfilePayload?
        var readable = true

        init(limits: WatchOutbox.Limits = .init(), profile: Bool = true, maxDuration: TimeInterval = WatchRecorder.defaultMaxDuration,
             freeBytes: Int64? = nil) throws {
            let (url, identity, stored, _) = try CaptureFixture.vault()
            vault = url
            self.identity = identity
            payload = profile ? WatchProfilePayload(profile: stored.profile, vaultName: "sample", seq: 1, issued: Date()) : nil
            audio = FakeAudio(clock: clock)
            let clock = self.clock
            outbox = try WatchOutbox(directory: CaptureFixture.temp("watch-outbox"), limits: limits, now: { Date(timeIntervalSince1970: 1_800_000_000) })
            var holder: Rig?
            recorder = WatchRecorder(audio: audio, outbox: outbox, profile: { holder?.payload }, root: root, keeper: keeper, profileReadable: { holder?.readable ?? true },
                                     statusStore: VoiceNoteStatusStore(directory: status), freeBytes: { freeBytes },
                                     timeZone: TimeZone(identifier: "UTC") ?? .current, maxDuration: maxDuration, now: { clock.now })
            holder = self
            keep = self
        }

        /// The profile closure reads `payload` through this reference, which lives as long as the rig.
        private var keep: Rig?

        /// Starts, then makes the recording's segment hold `frames` ADTS frames.
        func record(frames: Int = 40) async throws -> FakeRecording {
            try await recorder.start()
            let r = try #require(audio.lastRecording)
            try Self.write(Data(WatchRecorderTests.adts(frames: frames)), to: r.segments[0])
            return r
        }

        static func write(_ d: Data, to url: URL) throws { try d.write(to: url) }

        var folders: [String] { CaptureRig.names(root) }

        /// The vault's reading of the capture `id` the outbox holds (its file placed in a copy of the vault's inbox).
        func read(_ id: UUID) throws -> PendingCapture {
            let inbox = vault.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: outbox.fileURL(id), to: inbox.appendingPathComponent(CaptureFile.name(id, .capture)))
            return try TestVaults.open(at: vault, identity: identity).readCapture(id)
        }
    }

    @Test func aWatchNoteIsSealedIntoTheOutboxAndTheFolderGoes() async throws {
        let rig = try Rig()
        let rec = try await rig.record(frames: 100)
        #expect(rig.recorder.phase == .recording)
        #expect(rig.recorder.isRecording)
        #expect(rig.audio.formats == [WatchRecorder.format])
        #expect(rec.segments.first?.pathExtension == CaptureSegments.segmentExtension)
        rig.clock.advance(7)
        #expect(rig.recorder.elapsed == 7)
        let note = try await rig.recorder.stop()
        #expect(rig.recorder.phase == .idle)
        #expect(note.id == rec.id && note.vaultName == "sample" && !note.reachedLimit && !note.recovered)
        #expect(abs(note.duration - 100 * 1024 / 24000.0) < 1e-9)
        #expect(rig.folders.isEmpty, "the plaintext is deleted once sealed")
        // The outbox holds the sealed file, unsent, and the vault reads it.
        let entry = try #require(rig.outbox.entry(note.id))
        #expect(entry.state == .sealed)
        #expect(entry.meta.vault == rig.payload?.profile.vaultId)
        let sealed = try rig.outbox.sealedData(note.id)
        #expect(sealed.range(of: Data(WatchRecorderTests.adts(frames: 1).prefix(7))) == nil, "encrypted on disk")
        let pending = try rig.read(note.id)
        let manifest = try #require(pending.manifest)
        #expect(manifest.audio.type == "audio/mp4")
        #expect(manifest.title == "Watch voice note 2027-01-15 08:00")
        #expect(manifest.codec == "aac" && manifest.sampleRate == 24000 && manifest.channels == 1)
        #expect(manifest.device == rig.payload?.profile.device)
        let audio = try #require(pending.audio)
        #expect(try AudioProbe.probe(audio).codec == "aac")
        #expect(audio.range(of: Data("ftyp".utf8)) != nil)
        // The widgets' status went back to ready.
        #expect(VoiceNoteStatusStore(directory: rig.status).read()?.phase == .ready)
    }

    @Test func theStatusFollowsTheRecording() async throws {
        let rig = try Rig()
        let store = VoiceNoteStatusStore(directory: rig.status)
        #expect(rig.recorder.status.phase == .ready)
        let rec = try await rig.record()
        #expect(store.read()?.phase == .recording)
        // An interruption pauses the audio; the platform tells `publishStatus`.
        rig.clock.advance(5)
        rec.interrupt()
        #expect(rig.recorder.phase == .paused)
        #expect(rig.recorder.publishStatus())
        #expect(store.read()?.paused != nil)
        rig.clock.advance(30)   // a call: not audio
        rec.resume()
        #expect(rig.recorder.phase == .recording)
        #expect(rig.recorder.elapsed == 5, "pause time is not audio")
        rig.clock.advance(3)
        #expect(rig.recorder.elapsed == 8)
        rig.recorder.publishStatus()
        #expect(store.read()?.paused == nil)
        _ = try await rig.recorder.stop()
        #expect(store.read()?.phase == .ready)
        let off = try Rig(profile: false)
        #expect(off.recorder.status.phase == .notSetUp)
    }

    @Test func aRecordingTheSystemStoppedIsSealedAsAfterStop() async throws {
        let rig = try Rig()
        let rec = try await rig.record()
        rec.stop()
        rec.onStoppedBySystem?()
        #expect(await CaptureRig.settleAsync { rig.recorder.lastSystemStop != nil && rig.recorder.phase == .idle })
        guard case .success(let note)? = rig.recorder.lastSystemStop else { Issue.record("not sealed"); return }
        #expect(rig.outbox.entry(note.id)?.state == .sealed)
        #expect(rig.folders.isEmpty)
    }

    @Test func aCrashLeftoverIsSealedBySweepAndAnUnreadableOneStays() async throws {
        let rig = try Rig()
        // A crash: one finished segment and one cut off in its last frame, with a manifest naming both.
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        try Self.adts(frames: 12, seed: 9).dropLast(5).write(to: folder.appendingPathComponent("segment-002.aac"))
        let manifest = RecordingManifest(note: UUID(), recording: id, started: rig.clock.now, codec: "aac",
                                         segments: ["segment-001.aac", "segment-002.aac"], finished: 1,
                                         vault: try #require(rig.payload).profile.vaultId, epochId: String(repeating: "ab", count: 32))
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        // Another folder whose complete segment does not decode: kept.
        let bad = rig.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: bad.appendingPathComponent("segment-001.aac"))
        try Self.adts(frames: 3).write(to: bad.appendingPathComponent("segment-002.aac"))
        // And an empty one: nothing recorded.
        let empty = rig.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("segment-001.aac"))

        let notes = await rig.recorder.sweep()
        #expect(notes.map(\.id) == [id])
        #expect(notes.first?.recovered == true)
        #expect(abs((notes.first?.duration ?? 0) - 41 * 1024 / 24000.0) < 1e-9, "the cut-off last frame is dropped")
        #expect(rig.folders == [bad.lastPathComponent], "only the unreadable one waits; the empty one went")
        #expect(rig.outbox.entry(id)?.state == .sealed)
        #expect(try rig.read(id).manifest?.title == WatchRecorder.title(rig.clock.now, timeZone: TimeZone(identifier: "UTC") ?? .current))
        // A second sweep seals nothing more.
        #expect(await rig.recorder.sweep().isEmpty)
    }

    // MARK: The profile a recording starts with (docs/design/1.1-watch.md §3.5)

    /// The manifest names the vault and the epoch the recording started under.
    @Test func startBindsTheRecordingToTheProfilesVault() async throws {
        let rig = try Rig()
        let rec = try await rig.record()
        let p = try #require(rig.payload).profile
        #expect(rec.bound?.vault == p.vaultId)
        #expect(rec.bound?.epochId == p.epochId)
        #expect(rig.keeper.load(for: rec.id) == rig.payload, "kept for the length of the recording")
        let manifest = RecordingManifest(note: UUID(), recording: rec.id, started: nil, codec: "aac", segments: [], finished: 0,
                                         vault: p.vaultId, epochId: p.epochId)
        let back = try JSONDecoder().decode(RecordingManifest.self, from: try JSONEncoder().encode(manifest))
        #expect(back.vault == p.vaultId && back.epochId == p.epochId)
        // A manifest an earlier build wrote has neither.
        let old = Data(#"{"note":"\#(UUID().uuidString)","recording":"\#(UUID().uuidString)","codec":"aac","segments":[],"finished":0}"#.utf8)
        #expect(try JSONDecoder().decode(RecordingManifest.self, from: old).vault == nil)
    }

    /// C-03: with no profile at all (a clear, Reset), leftovers are deleted, as the phone's sweep does.
    @Test func leftoversWithNoProfileAreDeletedNotKeptForever() async throws {
        let rig = try Rig()
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        rig.payload = nil
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders.isEmpty, "the plaintext does not wait for a profile that may never come")
        #expect(rig.outbox.all.isEmpty)
    }

    /// C-03: a leftover is sealed only with a profile of the same vault; another vault's stays, never sealed into this one.
    @Test func aLeftoverIsSealedOnlyWithAProfileOfItsOwnVault() async throws {
        let rig = try Rig()
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        let write = { (vault: UUID) throws in
            let m = RecordingManifest(note: UUID(), recording: id, started: rig.clock.now, codec: "aac", segments: ["segment-001.aac"],
                                      finished: 1, vault: vault, epochId: String(repeating: "ab", count: 32))
            try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        }
        try write(UUID())
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders == [folder.lastPathComponent], "kept, not sealed into another vault")
        try write(try #require(rig.payload).profile.vaultId)
        #expect(await rig.recorder.sweep().map(\.id) == [id])
        #expect(rig.folders.isEmpty)
    }

    /// A leftover whose manifest names no vault (its manifest saves failed) is kept, never sealed under the current profile,
    /// which may be another vault's; one with nothing recorded goes.
    @Test func aLeftoverWithNoVaultIsKeptNotSealed() async throws {
        let rig = try Rig()
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        let m = RecordingManifest(note: UUID(), recording: id, started: rig.clock.now, codec: "aac", segments: ["segment-001.aac"],
                                  finished: 1)
        try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
        let empty = rig.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("segment-001.aac"))
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders == [folder.lastPathComponent], "kept, not sealed; the empty one went")
        #expect(rig.outbox.all.isEmpty)
        // A clear (no profile) deletes it with the rest.
        rig.payload = nil
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders.isEmpty)
    }

    /// The leftovers a sweep keeps are reported (counts and a size only), computed from the folders, so they survive a relaunch;
    /// Delete removes exactly those folders; an empty leftover is still removed silently.
    @Test func keptLeftoversAreReportedAndDeleteRemovesExactlyThem() async throws {
        let rig = try Rig()
        func leftover(vault: UUID?, started: Date? = nil) throws -> URL {
            let id = UUID()
            let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
            let m = RecordingManifest(note: UUID(), recording: id, started: started ?? rig.clock.now, codec: "aac",
                                      segments: ["segment-001.aac"], finished: 1, vault: vault,
                                      epochId: vault == nil ? nil : String(repeating: "ab", count: 32))
            try JSONEncoder().encode(m).write(to: folder.appendingPathComponent(RecordingManifest.fileName))
            return folder
        }
        let noVault = try leftover(vault: nil)
        let other = try leftover(vault: UUID(), started: rig.clock.now.addingTimeInterval(-40 * 24 * 3600))
        // One that this watch can place is sealed, not reported.
        let mine = try leftover(vault: try #require(rig.payload).profile.vaultId)
        // And an empty one: removed silently.
        let empty = rig.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("segment-001.aac"))

        let report = await rig.recorder.sweepReport()
        #expect(report.sealed.count == 1)
        #expect(report.kept.noVault == 1 && report.kept.otherVault == 1 && report.kept.count == 2)
        #expect(report.kept.bytes > 0)
        #expect(report.kept.older == 1, "the one that began 40 days ago is mentioned once more")
        #expect(Set(rig.folders) == [noVault.lastPathComponent, other.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: mine.path) && !FileManager.default.fileExists(atPath: empty.path))
        // A relaunch (another recorder over the same folders) counts the same: nothing is stored.
        #expect(rig.recorder.leftovers() == report.kept)
        // Delete removes exactly them.
        let unrelated = rig.root.appendingPathComponent("not-a-recording", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        #expect(rig.recorder.deleteLeftovers() == 2)
        #expect(rig.folders == [unrelated.lastPathComponent])
        #expect(rig.recorder.leftovers().count == 0)
        // With no profile at all they are deleted by the sweep, and nothing is reported.
        let again = try leftover(vault: nil)
        rig.payload = nil
        #expect(await rig.recorder.sweepReport().kept.count == 0)
        #expect(!FileManager.default.fileExists(atPath: again.path))
    }

    /// A clear that arrived mid-recording and then a crash: the kept start-time profile still seals the leftover, once.
    @Test func aKeptProfileSealsALeftoverAfterAClearAndACrash() async throws {
        let rig = try Rig()
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        try rig.keeper.keep(try #require(rig.payload), for: id)
        rig.payload = nil
        #expect(await rig.recorder.sweep().map(\.id) == [id])
        #expect(rig.folders.isEmpty)
        #expect(rig.keeper.count == 0)
    }

    /// A sweep while the stored profile cannot be read deletes nothing: that is not "no profile".
    @Test func anUnreadableProfileIsNotNoProfile() async throws {
        let rig = try Rig()
        let folder = rig.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.adts(frames: 30).write(to: folder.appendingPathComponent("segment-001.aac"))
        rig.payload = nil
        rig.readable = false
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders == [folder.lastPathComponent])
        rig.readable = true
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders.isEmpty)
    }

    /// A kept-profile seal that fails after a clear is deleted, and kept profiles with no folder are collected.
    @Test func aFailedSealWithoutAProfileIsDeletedAndOrphanKeptProfilesGo() async throws {
        let rig = try Rig()
        let id = UUID()
        let folder = rig.root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("segment-001.aac"))
        try Self.adts(frames: 3).write(to: folder.appendingPathComponent("segment-002.aac"))
        let payload = try #require(rig.payload)
        try rig.keeper.keep(payload, for: id)
        try rig.keeper.keep(payload, for: UUID())   // an orphan: no folder
        rig.payload = nil
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.folders.isEmpty, "the plaintext that cannot be sealed does not wait forever")
        #expect(rig.keeper.count == 0)
    }

    @Test func aSweepSkipsTheRecordingInProgress() async throws {
        let rig = try Rig()
        _ = try await rig.record()
        #expect(await rig.recorder.sweep().isEmpty)
        #expect(rig.recorder.isRecording)
        #expect(rig.folders.count == 1)
    }

    @Test func aSealThatFailsKeepsTheFolder() async throws {
        // A complete segment that does not decode.
        let rig = try Rig()
        let rec = try await rig.record()
        try Self.Rig.write(Data("not audio".utf8), to: rec.segments[0])
        await #expect(throws: WatchRecorderError.segmentUndecodable("segment-001.aac")) { _ = try await rig.recorder.stop() }
        #expect(rig.recorder.phase == .idle)
        #expect(rig.folders.count == 1, "never delete audio that was not sealed")
        #expect(rig.outbox.all.isEmpty)

        // The profile is gone when it stops (a clear arrived mid-recording): it takes effect after the seal.
        let rig2 = try Rig()
        let rec2 = try await rig2.record()
        rig2.payload = nil
        let sealed2 = try await rig2.recorder.stop()
        #expect(rig2.outbox.entry(sealed2.id)?.state == .sealed)
        #expect(rig2.folders.isEmpty, "the plaintext is gone")
        #expect(rig2.keeper.count == 0, "the kept profile goes with the seal")
        _ = rec2

        // The outbox cannot be written.
        let rig3 = try Rig()
        _ = try await rig3.record()
        try FileManager.default.removeItem(at: rig3.outbox.directory)
        try Data().write(to: rig3.outbox.directory)   // a file where the folder was
        await #expect(throws: (any Error).self) { _ = try await rig3.recorder.stop() }
        #expect(rig3.folders.count == 1)
    }

    @Test func aNoteThatRecordedNothingIsDropped() async throws {
        let rig = try Rig()
        let rec = try await rig.record()
        try Self.Rig.write(Data(), to: rec.segments[0])
        await #expect(throws: WatchRecorderError.nothingRecorded) { _ = try await rig.recorder.stop() }
        #expect(rig.folders.isEmpty)
        #expect(rig.outbox.all.isEmpty)
    }

    @Test func theSixtyMinuteLimitStopsAndSeals() async throws {
        let rig = try Rig()
        _ = try await rig.record(frames: 60)
        rig.clock.advance(3599)
        #expect(await rig.recorder.checkLimit() == nil)
        #expect(rig.recorder.isRecording)
        rig.clock.advance(1)
        let note = try #require(await rig.recorder.checkLimit())
        #expect(note.reachedLimit)
        #expect(rig.recorder.phase == .idle)
        #expect(rig.outbox.entry(note.id)?.state == .sealed)
        #expect(await rig.recorder.checkLimit() == nil, "it does not start another")
        #expect(WatchRecorder.defaultMaxDuration == 3600)
    }

    @Test func startRefusesWithWhyAndNeverRecords() async throws {
        // No profile.
        let off = try Rig(profile: false)
        await #expect(throws: WatchRecorderError.notSetUp) { try await off.recorder.start() }
        // The microphone.
        let mic = try Rig()
        mic.audio.allowed = { false }
        await #expect(throws: WatchRecorderError.microphoneDenied) { try await mic.recorder.start() }
        // The audio session.
        let session = try Rig()
        session.audio.configure = { $0.failNonMixable = true }
        await #expect(throws: (any Error).self) { try await session.recorder.start() }
        #expect(session.recorder.phase == .idle)
        // The recorder itself.
        let refused = try Rig()
        refused.audio.configure = { $0.failStart = true }
        do { try await refused.recorder.start(); Issue.record("started") } catch let e as WatchRecorderError {
            guard case .cannotStart = e else { Issue.record("\(e)"); return }
        }
        #expect(refused.recorder.phase == .idle)
        #expect(refused.folders.isEmpty, "a start that failed leaves no folder")
        // Twice.
        let twice = try Rig()
        _ = try await twice.record()
        await #expect(throws: WatchRecorderError.alreadyRecording) { try await twice.recorder.start() }
        await #expect(throws: WatchRecorderError.notRecording) { _ = try await Rig().recorder.stop() }
    }

    @Test func aFullOutboxOrLowStorageRefusesTheStart() async throws {
        var limits = WatchOutbox.Limits()
        limits.maxFiles = 1
        let rig = try Rig(limits: limits)
        _ = try await rig.record()
        _ = try await rig.recorder.stop()
        await #expect(throws: WatchRecorderError.outboxFull) { try await rig.recorder.start() }
        #expect(rig.audio.recorders.count == 1, "nothing was asked of the audio system")
        // The note it holds is still there; an ack makes room.
        try rig.outbox.acknowledge(rig.outbox.unsent.map(\.id))
        try await rig.recorder.start()
        #expect(rig.recorder.isRecording)

        let low = try Rig(freeBytes: 100 << 20)
        await #expect(throws: WatchRecorderError.lowStorage) { try await low.recorder.start() }
    }
}

extension CaptureRig {
    /// `settle`, for a condition tested without a rig.
    static func settleAsync(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

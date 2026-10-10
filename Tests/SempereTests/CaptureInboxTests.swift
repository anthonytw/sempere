import Age
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// Quick capture without unlocking (format.md §11, docs/quick-capture.md).
final class CaptureInboxTests: VaultTestCase {
    let audio = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    var audioRef: BlobRef { BlobRef(content: audio, type: "audio/mp4") }

    func deviceState() -> URL { tmp.appendingPathComponent("device-\(UUID().uuidString).json") }

    /// A profile made while unlocked, then the vault reopened with no identity.
    func setUp(notebook: String = "Inbox") throws -> (identity: NativeIdentity, profile: CaptureProfile, locked: Vault) {
        try XCTSkipUnless(postQuantumAvailable)
        let id = pqIdentity()
        let vault = try makeVault(id)
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!, notebook: notebook)
        return (id, profile, try Vault.open(at: vault.url))
    }

    func transcript(_ capture: UUID) -> Transcript {
        TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: capture).recording, engine: "apple-speechtranscriber-26.7",
                                     language: "en-US", created: started,
                                     segments: [.init(start: 0, end: 1, text: "Buy milk.", confidence: 0.9,
                                                      words: [.init("Buy", start: 0, end: 0.4), .init("milk.", start: 0.4, end: 1)])])
    }

    /// The profile holds only public recipients and the capture key, never
    /// the secret; captures are written with the vault locked and read back
    /// with the identity.
    func testCaptureWithoutUnlockingIsAdoptedWithTheIdentity() throws {
        let (identity, profile, locked) = try setUp()
        XCTAssertTrue(locked.isLocked)
        XCTAssertNotEqual(profile.key, try Vault.open(at: locked.url, identities: [identity]).requireSecret().bytes)
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let sealed = try writer.seal(audio: audio, started: started, title: nil, id: id, created: started)
        XCTAssertNil(sealed.data.range(of: audio.prefix(64)), "nothing in the clear")
        try CaptureWriter.store(sealed, in: locked.inboxURL)
        XCTAssertEqual(try locked.inboxEntries().map(\.id), [id])
        XCTAssertThrowsError(try locked.readCapture(id), "a locked vault cannot read captures")

        // Stock age decrypts it with the identity, as every vault file.
        let plain = try AgeFile.decrypt(sealed.data, with: [identity])
        // The JSON line starts after the 37-byte header, whose tag may itself hold a 0x0A byte.
        let header = plain.startIndex + CaptureFile.headerSize
        let line = plain[header..<(try XCTUnwrap(plain[header...].firstIndex(of: 0x0A)))]
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line)))
        XCTAssertEqual(plain.suffix(audio.count), audio)

        let vault = try Vault.open(at: locked.url, identities: [identity])
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.created)
        let ids = CaptureAdoption.ids(for: id)
        let state = try vault.reconstruct(noteId: ids.note)
        XCTAssertEqual(state.meta.title, CaptureWriter.defaultTitle(started))
        XCTAssertEqual(state.meta.notebook, "Inbox")
        XCTAssertEqual(state.pages.map(\.id), [ids.page])
        let rec = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(rec.id, ids.recording)
        XCTAssertEqual(rec.started, started)
        XCTAssertNil(rec.transcript)
        XCTAssertEqual(try vault.readBlob(note: ids.note, rec.blob), audio)
        XCTAssertEqual(try vault.inboxEntries().count, 0, "the inbox file is deleted once adopted")
        XCTAssertEqual(try vault.loadNote(ids.note).revisions.count, 1, "one delta")
    }

    /// A transcript made later (background transcription, or the next time
    /// the app runs) is added to the adopted recording.
    func testTranscriptAddedLater() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "test/1").error)

        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id, audio: audioRef), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertFalse(r.created)
        XCTAssertTrue(r.transcript)
        let ids = CaptureAdoption.ids(for: id)
        let rec = try XCTUnwrap(try vault.reconstruct(noteId: ids.note).recordings.first)
        let t = try Transcript.decode(try vault.readBlob(note: ids.note, try XCTUnwrap(rec.transcript)))
        XCTAssertEqual(t.segments.first?.text, "Buy milk.")
        XCTAssertEqual(try vault.inboxEntries().count, 0)
    }

    /// Security review 2026-10 (C1): the capture key is on every capturing
    /// device and capture ids are in the clear (file names), so a transcript
    /// must prove it was made by whoever had the audio. One bound to other
    /// audio is never added to an existing voice note, nor to a new one, and
    /// is deleted rather than kept forever.
    func testATranscriptBoundToOtherAudioIsNeverAdopted() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "test/1").error)

        let forged = BlobRef(content: Data("guessed audio".utf8), type: "audio/mp4")
        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id, audio: forged), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertFalse(r.transcript)
        XCTAssertNil(r.file, "nothing written")
        let ids = CaptureAdoption.ids(for: id)
        XCTAssertNil(try vault.reconstruct(noteId: ids.note).recordings.first?.transcript)
        XCTAssertTrue(try vault.inboxEntries().isEmpty, "an unbound transcript is not kept")

        // Planted before the capture is adopted: the capture is adopted without it.
        let other = UUID()
        try CaptureWriter.store(try writer.seal(transcript: transcript(other), capture: other, audio: forged), in: locked.inboxURL)
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: other), in: locked.inboxURL)
        let both = vault.adoptCapture(other, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(both.error)
        XCTAssertTrue(both.created)
        XCTAssertFalse(both.transcript)
        XCTAssertNil(try vault.reconstruct(noteId: CaptureAdoption.ids(for: other).note).recordings.first?.transcript)
        XCTAssertTrue(try vault.inboxEntries().isEmpty)
    }

    /// A transcript sealed before the binding (an empty payload) is bound to
    /// nothing: it is not adopted, even into an existing recording without one.
    func testAnUnboundTranscriptIsNotAdopted() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "test/1").error)

        let name = CaptureFile.name(id, .transcript)
        let plain = try CaptureFile.frame(line: try transcript(id).encoded(), payload: Data(), filename: name, key: writer.key)
        try CaptureWriter.store(SealedCapture(name: name, data: try Vault.encrypt(plain, to: writer.recipients)), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        XCTAssertFalse(r.transcript)
        XCTAssertNil(try vault.reconstruct(noteId: CaptureAdoption.ids(for: id).note).recordings.first?.transcript)
    }

    func testTranscriptBeforeItsCaptureWaitsAndBothTogetherAreOneDelta() throws {
        let (identity, profile, locked) = try setUp(notebook: "Voice/Quick")
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id, audio: audioRef), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        let early = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(early.error)
        XCTAssertNil(early.file)
        XCTAssertEqual(try vault.inboxEntries().first?.kinds, [.transcript], "kept until its capture arrives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent(
            "notes/\(CaptureAdoption.ids(for: id).note.uuidString.lowercased())").path), "nothing written while it waits")

        try CaptureWriter.store(try writer.seal(audio: audio, started: started, title: "Groceries", id: id), in: locked.inboxURL)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertNil(r.error)
        let ids = CaptureAdoption.ids(for: id)
        let state = try vault.reconstruct(noteId: ids.note)
        XCTAssertEqual(state.meta.title, "Groceries")
        XCTAssertEqual(state.meta.notebook, "Voice/Quick")
        XCTAssertNotNil(state.recordings.first?.transcript)
        XCTAssertEqual(try vault.loadNote(ids.note).revisions.count, 1)
        XCTAssertTrue(try vault.inboxEntries().isEmpty)
    }

    /// An adoption interrupted after its blobs and before its delta leaves a
    /// note folder holding only `att/`. That is still a new note: the retry
    /// creates it, instead of failing on a note "with no revisions" forever.
    func testAnAdoptionInterruptedAfterItsBlobsIsFinished() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id, audio: audioRef), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        _ = try vault.writeCaptureBlobs(try vault.readCapture(id))   // then the crash
        let ids = CaptureAdoption.ids(for: id)
        XCTAssertEqual(try vault.noteIDs(), [ids.note])
        XCTAssertTrue(try vault.revisionNames(of: ids.note).isEmpty)

        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.created)
        XCTAssertTrue(r.transcript)
        let state = try vault.reconstruct(noteId: ids.note)
        XCTAssertEqual(state.recordings.map(\.id), [ids.recording])
        XCTAssertNotNil(state.recordings.first?.transcript)
        XCTAssertTrue(try vault.inboxEntries().isEmpty)
    }

    /// Two devices adopting the same capture write the same note; adopting
    /// twice (the inbox file not deleted yet) adds nothing.
    func testAdoptionIsIdempotentAcrossDevices() throws {
        let (identity, profile, locked) = try setUp()
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let sealed = try writer.seal(audio: audio, started: started, id: id)
        try CaptureWriter.store(sealed, in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "a").error)
        try CaptureWriter.store(sealed, in: locked.inboxURL)   // the other device's copy, still in its inbox
        let again = vault.adoptCapture(id, deviceState: deviceState(), app: "b")
        XCTAssertNil(again.error)
        XCTAssertNil(again.file, "nothing new to write")
        let state = try vault.reconstruct(noteId: CaptureAdoption.ids(for: id).note)
        XCTAssertEqual(state.recordings.count, 1)
        XCTAssertEqual(state.pages.count, 1)
    }

    /// Anyone can encrypt to the public recipients; without the capture key
    /// (a holder of the vault secret) a capture does not verify and is kept,
    /// never adopted. A capture renamed to another id fails too.
    func testForgedOrRenamedCapturesAreRefused() throws {
        let (identity, profile, locked) = try setUp()
        var forger = profile
        forger.key = Data(repeating: 7, count: 32)
        let id = UUID()
        try CaptureWriter.store(try CaptureWriter(profile: forger).seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1")
        XCTAssertEqual(r.error, CaptureError.badTag.description)
        XCTAssertFalse(try vault.noteIDs().contains(CaptureAdoption.ids(for: id).note))
        XCTAssertEqual(try vault.inboxEntries().count, 1, "kept and reported")

        let good = try CaptureWriter(profile: profile).seal(audio: audio, started: started, id: UUID())
        let other = UUID()
        try good.data.write(to: locked.inboxURL.appendingPathComponent(CaptureFile.name(other, .capture)))
        XCTAssertEqual(vault.adoptCapture(other, deviceState: deviceState(), app: "test/1").error, CaptureError.badTag.description)
    }

    /// Security review 2026-10 (C5): a failing inbox file is recorded and not
    /// read again until its back-off ends, unless it changes; a file that
    /// verifies clears its record.
    func testFailingInboxFilesBackOff() throws {
        let (identity, profile, locked) = try setUp()
        var forger = profile
        forger.key = Data(repeating: 7, count: 32)
        let id = UUID()
        let name = CaptureFile.name(id, .capture)
        try CaptureWriter.store(try CaptureWriter(profile: forger).seal(audio: audio, started: started, id: id), in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        let file = tmp.appendingPathComponent("backoff.json")
        var backoff = InboxBackoff(fileURL: file)
        let t0 = Date()

        XCTAssertThrowsError(try vault.readCapture(id, backoff: backoff, now: t0)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertEqual(backoff.entries(vault: vault.vaultId)[name]?.failures, 1)
        // Within the hour it is not read: the error says so.
        XCTAssertThrowsError(try vault.readCapture(id, backoff: backoff, now: t0.addingTimeInterval(1800))) { error in
            guard case CaptureError.backedOff(let n, let after, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(n, 1)
            XCTAssertEqual(after, t0.addingTimeInterval(InboxBackoff.firstDelay))
        }
        // The record survives a restart, and the wait doubles after the next failure.
        backoff = InboxBackoff(fileURL: file)
        let t1 = t0.addingTimeInterval(InboxBackoff.firstDelay + 1)
        XCTAssertThrowsError(try vault.readCapture(id, backoff: backoff, now: t1)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        let e = try XCTUnwrap(backoff.entries(vault: vault.vaultId)[name])
        XCTAssertEqual(e.failures, 2)
        XCTAssertEqual(e.retryAfter, t1.addingTimeInterval(2 * InboxBackoff.firstDelay))
        // Adoption reports the back-off and keeps the file.
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "test/1", backoff: backoff, now: t1.addingTimeInterval(60))
        XCTAssertTrue(r.error?.contains("failed 2 time(s)") == true, r.error ?? "")
        XCTAssertEqual(try vault.inboxEntries().count, 1)

        // A changed file is read at once; once it verifies, its record goes.
        try CaptureWriter(profile: profile).seal(audio: audio + Data([1]), started: started, id: id).data
            .write(to: locked.inboxURL.appendingPathComponent(name))
        XCTAssertNoThrow(try vault.readCapture(id, backoff: backoff, now: t1.addingTimeInterval(120)))
        XCTAssertNil(backoff.entries(vault: vault.vaultId)[name])
    }

    /// Security review 2026-10 (C2): a capture's title and notebook come from
    /// whoever holds the capture key; the note gets them bounded and on one line.
    func testCaptureTitleAndNotebookAreBounded() throws {
        let (identity, profile, locked) = try setUp(notebook: "Voice\nNotes")
        let id = UUID()
        let long = String(repeating: "é", count: 5000) + "\u{1B}[2J"
        try CaptureWriter.store(try CaptureWriter(profile: profile).seal(audio: audio, started: started, title: long, id: id),
                                in: locked.inboxURL)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertNil(vault.adoptCapture(id, deviceState: deviceState(), app: "test/1").error)
        let meta = try vault.reconstruct(noteId: CaptureAdoption.ids(for: id).note).meta
        XCTAssertEqual(meta.title.count, CaptureAdoption.maxNameLength)
        XCTAssertEqual(meta.notebook, "Voice Notes")
        XCTAssertEqual(CaptureAdoption.boundedName("a\u{1B}b\tc"), "a b c")
    }

    /// C2: one grapheme cluster has no length limit (a base letter and any
    /// number of combining marks), so a cap in characters alone lets a
    /// megabyte title through as "one character". Scalars are capped too.
    func testBoundedNameCapsOneHugeGraphemeCluster() {
        let huge = "a" + String(repeating: "\u{301}", count: 200_000)
        XCTAssertEqual(huge.count, 1)
        let bounded = CaptureAdoption.boundedName(huge)
        XCTAssertLessThanOrEqual(bounded.unicodeScalars.count, CaptureAdoption.maxNameScalars)
        XCTAssertEqual(bounded.unicodeScalars.first, "a")
        // Ordinary text is unchanged: emoji with modifiers stay whole.
        XCTAssertEqual(CaptureAdoption.boundedName("Meeting 👍🏽 notes"), "Meeting 👍🏽 notes")
        let manyEmoji = String(repeating: "👨‍👩‍👧‍👦", count: 400)
        XCTAssertLessThanOrEqual(CaptureAdoption.boundedName(manyEmoji).unicodeScalars.count, CaptureAdoption.maxNameScalars)
    }

    /// C5: a transcript file has a much smaller bound than a capture, checked
    /// from its size before anything is decrypted; and a capture's tag is
    /// checked streamed before the file is read whole.
    func testInboxFileSizeIsBoundedByItsKind() throws {
        let (identity, _, locked) = try setUp()
        let id = UUID()
        try FileManager.default.createDirectory(at: locked.inboxURL, withIntermediateDirectories: true)
        let url = locked.inboxURL.appendingPathComponent(CaptureFile.name(id, .transcript))
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("age-encryption.org/v1\n".utf8)))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(CaptureFile.maxSealedBytes(.transcript) + 1))   // sparse: nothing is written
        try h.close()
        XCTAssertLessThan(CaptureFile.maxSealedBytes(.transcript), CaptureFile.maxSealedBytes(.capture) / 3)
        let vault = try Vault.open(at: locked.url, identities: [identity])
        XCTAssertThrowsError(try vault.readCapture(id)) { error in
            guard case CaptureError.tooLarge = error else { return XCTFail("\(error)") }
        }
        // Junk of an allowed size fails as "not a capture", from the stream.
        try Data(repeating: 0x41, count: 70_000).write(to: url)
        XCTAssertThrowsError(try vault.readCapture(id)) { error in
            guard case CaptureError.notCapture = error else { return XCTFail("\(error)") }
        }
    }

    /// Removing a recipient rotates the secret and with it the capture key:
    /// a profile from before no longer verifies.
    func testKeyRotationRevokesOldProfiles() throws {
        let (identity, profile, _) = try setUp()
        var vault = try Vault.open(at: vaultURL(), identities: [identity])
        let second = pqIdentity()
        _ = try vault.addRecipient(second.recipient, label: "second")
        _ = try vault.removeRecipient(second.recipient)
        XCTAssertNotEqual(try vault.captureKey().bytes, profile.key)
        let id = UUID()
        try CaptureWriter.store(try CaptureWriter(profile: profile).seal(audio: audio, started: started, id: id), in: vault.inboxURL)
        XCTAssertEqual(vault.adoptCapture(id, deviceState: deviceState(), app: "t").error, CaptureError.badTag.description)
    }

    /// A capture waiting in the inbox when a key is removed was tagged under
    /// the outgoing secret's capture key. The rewrap re-tags it (format.md
    /// §3.3.1 step 3, §11.1), so it is still adopted after the journal, the
    /// only copy of that secret, is gone.
    func testRemovingAKeyKeepsWaitingCapturesAdoptable() throws {
        let (identity, profile, _) = try setUp()
        var vault = try Vault.open(at: vaultURL(), identities: [identity])
        let second = pqIdentity()
        _ = try vault.addRecipient(second.recipient, label: "second")
        let id = UUID()
        let writer = try CaptureWriter(profile: profile)
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, id: id), in: vault.inboxURL)
        try CaptureWriter.store(try writer.seal(transcript: transcript(id), capture: id, audio: audioRef), in: vault.inboxURL)

        let report = try vault.removeRecipient(second.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(vault.pendingRewrap, "the journal is gone")
        XCTAssertEqual(Set(report.rewrapped.filter { $0.hasPrefix("inbox/") }),
                       ["inbox/\(CaptureFile.name(id, .capture))", "inbox/\(CaptureFile.name(id, .transcript))"])
        // The removed key opens neither file any more.
        for kind in CaptureFile.Kind.allCases {
            let sealed = try Data(contentsOf: vault.inboxURL.appendingPathComponent(CaptureFile.name(id, kind)))
            XCTAssertThrowsError(try AgeFile.decrypt(sealed, with: [second]))
        }

        let reopened = try Vault.open(at: vault.url, identities: [identity])
        let r = reopened.adoptCapture(id, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.created)
        XCTAssertTrue(r.transcript)
        XCTAssertEqual(try reopened.inboxEntries().count, 0)
        let rec = try XCTUnwrap(try reopened.reconstruct(noteId: CaptureAdoption.ids(for: id).note).recordings.first)
        XCTAssertEqual(try reopened.readBlob(note: CaptureAdoption.ids(for: id).note, rec.blob), audio)

        // A second run finds the inbox current.
        let again = try reopened.rewrapNotes(stopAfter: nil)
        XCTAssertTrue(again.rewrapped.filter { $0.hasPrefix("inbox/") }.isEmpty)
    }

    /// A device added while captures wait can adopt them: the rewrap
    /// re-encrypts inbox files to the new recipients.
    func testAnAddedDeviceCanAdoptWaitingCaptures() throws {
        let (identity, profile, _) = try setUp()
        var vault = try Vault.open(at: vaultURL(), identities: [identity])
        let id = UUID()
        try CaptureWriter.store(try CaptureWriter(profile: profile).seal(audio: audio, started: started, id: id), in: vault.inboxURL)
        let added = pqIdentity()
        _ = try vault.addRecipient(added.recipient, label: "new iPad")

        let onNewDevice = try Vault.open(at: vault.url, identities: [added])
        let r = onNewDevice.adoptCapture(id, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.created)
    }

    /// An inbox file that verifies under neither capture key (forged, or
    /// sealed with a profile revoked earlier) is left as it is and does not
    /// keep the journal, which would otherwise hold the outgoing secret forever.
    func testAForgedInboxFileDoesNotBlockARecipientChange() throws {
        let (identity, _, _) = try setUp()
        var vault = try Vault.open(at: vaultURL(), identities: [identity])
        let second = pqIdentity()
        _ = try vault.addRecipient(second.recipient, label: "second")
        let forger = CaptureProfile(vaultId: vault.vaultId, recipients: vault.recipients.map(\.key),
                                    key: Data(repeating: 7, count: 32), device: "0badf00d", notebook: "Inbox")
        let id = UUID()
        let forged = try CaptureWriter(profile: forger).seal(audio: audio, started: started, id: id)
        try CaptureWriter.store(forged, in: vault.inboxURL)

        let report = try vault.removeRecipient(second.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(vault.pendingRewrap)
        XCTAssertEqual(report.inboxSkipped, ["inbox/\(forged.name)"])
        XCTAssertEqual(try Data(contentsOf: vault.inboxURL.appendingPathComponent(forged.name)), forged.data, "left untouched")
        XCTAssertEqual(vault.adoptCapture(id, deviceState: deviceState(), app: "t").error, CaptureError.badTag.description)
    }

    /// Inbox files follow FileIO's write contract: written once, under a
    /// temporary name every listing ignores, never over an existing file.
    func testStoreWritesOnceThroughFileIO() throws {
        let inbox = tmp.appendingPathComponent("inbox")
        let name = CaptureFile.name(UUID(), .capture)
        try CaptureWriter.store(SealedCapture(name: name, data: Data("one".utf8)), in: inbox)
        try CaptureWriter.store(SealedCapture(name: name, data: Data("two".utf8)), in: inbox)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(name)), Data("one".utf8))
        XCTAssertEqual(try FileIO.entries(inbox), [name], "no temporary file is left")
    }

    func testFileNamesAndFraming() throws {
        let id = UUID()
        XCTAssertEqual(CaptureFile.parse(name: CaptureFile.name(id, .capture))?.id, id)
        XCTAssertEqual(CaptureFile.parse(name: CaptureFile.name(id, .transcript))?.kind, .transcript)
        for bad in ["x.capture.age", "\(id.uuidString).capture.age", "\(id.uuidString.lowercased()).audio.age", ".tmp", "a.b.c.d"] {
            XCTAssertNil(CaptureFile.parse(name: bad), bad)
        }
        let key = try CaptureKey(bytes: Data(repeating: 1, count: 32))
        let framed = try CaptureFile.frame(line: Data("{}".utf8), payload: Data([0x0A, 1, 2]), filename: "f", key: key)
        let (line, payload) = try CaptureFile.unframe(framed, filename: "f", key: key)
        XCTAssertEqual(line, Data("{}".utf8))
        XCTAssertEqual(payload, Data([0x0A, 1, 2]), "newlines in the audio are kept")
        XCTAssertThrowsError(try CaptureFile.unframe(framed, filename: "g", key: key)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertThrowsError(try CaptureFile.frame(line: Data("{\n}".utf8), payload: Data(), filename: "f", key: key))
        XCTAssertThrowsError(try CaptureKey(bytes: Data(count: 31)))
        XCTAssertEqual(CaptureWriter.defaultTitle(started, timeZone: TimeZone(identifier: "UTC")!), "Voice note 2027-01-15 08:00")
    }

    /// The tag is 32 arbitrary bytes, so about one capture in eight has a
    /// 0x0A in its header: the JSON line is found after the header, by the
    /// reader and by the stock-CLI recipe (`tail -c +38 | head -n 1`).
    func testATagHoldingANewlineStillFramesTheLine() throws {
        let key = try CaptureKey(bytes: Data(repeating: 3, count: 32))
        let line = Data("{\"a\":1}".utf8)
        var found: (name: String, framed: Data)?
        for i in 0..<2_000 {
            let name = "capture-\(i)"
            let framed = try CaptureFile.frame(line: line, payload: Data([9]), filename: name, key: key)
            if framed.prefix(CaptureFile.headerSize).contains(0x0A) { found = (name, framed); break }
        }
        let (name, framed) = try XCTUnwrap(found, "2000 tags without a 0x0A: the search is wrong")
        let opened = try CaptureFile.unframe(framed, filename: name, key: key)
        XCTAssertEqual(opened.line, line)
        XCTAssertEqual(opened.payload, Data([9]))
        let afterHeader = framed.dropFirst(CaptureFile.headerSize)
        XCTAssertEqual(afterHeader.prefix { $0 != 0x0A }, line[...], "tail -c +38 | head -n 1")
    }
}

/// Inbox files come from storage: hostile bytes must fail with a typed error.
extension SempereFuzzTests {
    func testFuzzCaptureFraming() throws {
        let key = try CaptureKey(bytes: Data(repeating: 9, count: 32))
        let manifest = CaptureManifest(id: UUID(), device: "0badf00d", vault: UUID(), created: Date(timeIntervalSince1970: 0),
                                       started: Date(timeIntervalSince1970: 0), title: "t", notebook: "Inbox",
                                       audio: BlobRef(content: Data([1, 2, 3]), type: "audio/mp4"))
        let seed = try CaptureFile.frame(line: try InkJSON.encoder().encode(manifest), payload: Data([1, 2, 3]), filename: "f", key: key)
        assertClean(Fuzz.run("capture", seeds: [seed, try InkJSON.encoder().encode(manifest)], quick: 1500) { input in
            // The tag check comes first; parse the JSON line directly too (as if the tag had passed).
            do { _ = try CaptureFile.unframe(input, filename: "f", key: key) } catch is CaptureError {} catch {
                return "untyped unframe error \(type(of: error))"
            }
            do { _ = try InkJSON.decoder().decode(CaptureManifest.self, from: input) } catch is DecodingError {} catch {
                return "untyped manifest error \(type(of: error))"
            }
            return nil
        })
    }
}

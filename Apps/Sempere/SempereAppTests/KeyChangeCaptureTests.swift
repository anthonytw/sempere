import Age
import Foundation
@testable import Sempere
import Testing
@testable import SempereApp

/// Audit check c43, automated: voice notes queued in the vault's inbox while a
/// key change is interrupted (here inside the inbox's own rewrap) are adopted
/// once the change is finished from the app.
@Suite(.serialized, .timeLimit(.minutes(10)))
@MainActor
struct KeyChangeCaptureTests {
    /// Records `count` quick voice notes into the inbox.
    static func capture(_ qc: QuickCapture, count: Int) async throws -> [UUID] {
        var ids: [UUID] = []
        for _ in 0..<count {
            try await qc.start()
            let outcome = try await qc.stop()
            #expect(outcome.error == nil)
            ids.append(outcome.id)
        }
        return ids
    }

    /// How many files a removal rewraps in a copy of the vault at `url` (to
    /// pick an interruption point inside the inbox, which is rewrapped after
    /// the notes).
    static func filesARemovalRewraps(_ url: URL, key: NativeIdentity, removing other: NativeRecipient) throws -> Int {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        var vault = try Vault.open(at: copy, identities: [key])
        return try vault.removeRecipient(other).rewrapped.count
    }

    /// c43 with the stress cases: 20 queued voice notes and one corrupt inbox
    /// file; a removal (a rotation, so the capture key changes) interrupted
    /// inside the inbox's rewrap; the app finishes it and adopts every voice
    /// note. A voice note recorded afterwards with the profile refreshed by
    /// the unlock is adopted too.
    @Test func c43VoiceNotesQueuedDuringAnInterruptedKeyChangeAreAdopted() async throws {
        let (url, keyURL, identity, qc, _) = try QuickCaptureTests.setUp(transcribe: false)
        let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        let other = try NativeIdentity.generate(.postQuantum)
        var vault = try Vault.open(at: url, identities: [identity])
        try vault.addRecipient(other.recipient, label: "Old iPad")
        // The capture profile was made before the addition: refresh it as the app does after a key change.
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        var stored = try #require(try qc.store.load())
        stored.profile = profile
        try qc.store.save(stored)

        let queued = try await Self.capture(qc, count: 20)
        let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
        let corrupt = CaptureFile.name(UUID(), .capture)
        try Data("not an age file".utf8).write(to: inbox.appendingPathComponent(corrupt))
        #expect(QuickCaptureTests.inbox(url).count == 21)

        let total = try Self.filesARemovalRewraps(url, key: identity, removing: other.recipient)
        var interrupted = try Vault.open(at: url, identities: [identity])
        #expect(throws: VaultError.self) {
            try interrupted.removeRecipient(other.recipient, policy: RewrapPolicy(), stopAfter: total - 5)
        }
        #expect(try Vault.open(at: url, identities: [identity]).pendingRewrap)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = QuickCaptureTests.temp("blobs")
        model.quickCapture = qc
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .finishingKeyChange)
        try await model.finishKeyChange()
        #expect(model.phase == .unlocked)
        #expect(await TS.waitUntil(timeout: .seconds(30)) { model.capturesAdopted == queued.count && model.inboxAdoption == nil })
        for id in queued {
            #expect(model.notes.contains { $0.id == CaptureAdoption.ids(for: id).note })
        }
        #expect(QuickCaptureTests.inbox(url).allSatisfy { $0 == corrupt }, "only the corrupt file can be left")

        // After the rotation: a new voice note, sealed with the refreshed profile, is adopted.
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            (try? qc.store.load())?.profile.recipients.count == 1
        }, "the profile follows the removal")
        let later = try await Self.capture(qc, count: 1)
        _ = await model.adoptInbox()
        let laterNote = CaptureAdoption.ids(for: later[0]).note
        #expect((try? model.vault?.reconstruct(noteId: laterNote)) != nil, "adopted after the rotation")
        model.close()
    }
}

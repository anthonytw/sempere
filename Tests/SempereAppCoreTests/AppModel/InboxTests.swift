import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Quick voice notes on the model's side (`AppModel+Inbox`, wave 5b part 3; moved from the app's
    /// `QuickCaptureTests`, which keeps what records with the app's recorder): the profile's states, turning it on
    /// and its refresh, and adopting the inbox's captures. The capture itself runs on its defaults (records nothing).
    @MainActor
    struct InboxTests {
        /// A fixture vault copy, its key's text, and a quick capture whose stored profile was made from it.
        static func setUp(transcribe: Bool = false) async throws -> (url: URL, key: String, capture: QuickCapture) {
            let (url, key) = try await ModelFixture.vault()
            let text = try await ModelFixture.keyText(key)
            let stored = try await Self.profile(url, text, transcribe: transcribe)
            let store = MemoryCaptureProfileStore()
            try store.save(stored)
            let qc = QuickCapture(store: store, root: TestTemp.root.appendingPathComponent("qc-\(UUID().uuidString)"),
                                  queueRoot: TestTemp.root.appendingPathComponent("qcq-\(UUID().uuidString)"))
            return (url, text, qc)
        }

        @concurrent static func profile(_ url: URL, _ text: String, transcribe: Bool) async throws -> StoredCaptureProfile {
            let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(text)])
            let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
            return StoredCaptureProfile(profile: profile, vaultName: "sample", bookmark: try PathBookmarks().bookmark(for: url),
                                        transcribe: transcribe)
        }

        static func inbox(_ vault: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("inbox").path)) ?? []).sorted()
        }

        /// Audio bytes to seal (adoption stores them; nothing decodes them).
        static func audio() throws -> Data { try Data(contentsOf: RecordingModelTests.tone) }

        func unlocked(_ url: URL, _ key: String, _ qc: QuickCapture) async throws -> AppModel {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
            model.quickCapture = qc
            try await model.openVault(at: url)
            try await model.unlock(identityText: key)
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.inboxAdoption == nil })
            return model
        }

        /// The model tells "no profile" from "a profile it cannot read now", as
        /// `QuickCapture` does: Settings must not show Quick Voice Notes as off
        /// while it is on (bug audit follow-up: `quickCaptureProfile` made every
        /// read error nil).
        @Test func theModelSaysWhenTheProfileCannotBeRead() async throws {
            let (_, _, qc) = try await Self.setUp()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            model.quickCapture = qc
            #expect(try model.storedQuickCaptureProfile() != nil)
            qc.store = FailingCaptureProfileStore()
            #expect(throws: QuickCaptureError.profileUnreadable) { try model.storedQuickCaptureProfile() }
            qc.store = MemoryCaptureProfileStore()
            #expect(try model.storedQuickCaptureProfile() == nil)
        }

        /// Settings' three states: off, on, and "cannot be read", which is shown
        /// as on (it is there, as far as anyone knows) and never as off; what
        /// only refreshes or syncs the profile leaves an unreadable one alone.
        @Test func settingsTellsOffFromUnreadable() async throws {
            let (_, _, qc) = try await Self.setUp()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            model.quickCapture = qc
            let stored = try #require(try qc.store.load())
            #expect(model.quickCaptureSetting == .on(stored))
            #expect(!model.quickCaptureSwitchIsOn, "on, but for a vault that is not open")
            let store = qc.store
            qc.store = FailingCaptureProfileStore()
            #expect(model.quickCaptureSetting == .unreadable)
            #expect(model.quickCaptureSwitchIsOn)
            #expect(!model.quickCaptureIsForOpenVault)
            model.refreshQuickCaptureProfile()
            qc.store = store
            #expect(try qc.store.load() == stored)
            try qc.store.delete()
            #expect(model.quickCaptureSetting == .off)
            #expect(!model.quickCaptureSwitchIsOn)
        }

        /// The profile's folder must be the open vault's (security review 2026-10 stage 4, S16).
        @Test func onlyTheProfilesOwnFolderIsTheProfilesFolder() async throws {
            let (url, _, qc) = try await Self.setUp()
            let stored = try #require(try qc.store.load())
            #expect(AppModel.isProfileFolder(stored.bookmark, url, bookmarks: PathBookmarks()))
            let lookalike = url.deletingLastPathComponent().appendingPathComponent("other.sempere")
            #expect(!AppModel.isProfileFolder(stored.bookmark, lookalike, bookmarks: PathBookmarks()))
        }

        @Test func enablingStoresAProfileWithoutTheIdentityAndRefreshFollowsKeyChanges() async throws {
            let (url, key) = try await ModelFixture.vault()
            let keyText = try await ModelFixture.keyText(key)
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let qc = model.quickCapture
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            try model.enableQuickCapture(notebook: "Voice/Inbox", transcribe: true)
            let stored = try #require(try qc.store.load())
            #expect(model.quickCaptureIsForOpenVault)
            #expect(stored.profile.notebook == "Voice/Inbox")
            let fresh = try #require(model.vault).captureProfile(device: try #require(DeviceID(stored.profile.device)))
            #expect(stored.profile.recipients == fresh.recipients, "sealed to the vault identity alone")
            #expect(stored.profile.recipients.count == 1)
            let data = try JSONEncoder().encode(stored)
            #expect(String(decoding: data, as: UTF8.self).contains("AGE-SECRET-KEY") == false, "never the identity")
            // A stale key in the profile is replaced on the next unlock.
            var old = stored
            old.profile.key = Data(repeating: 0, count: 32)
            try qc.store.save(old)
            model.refreshQuickCaptureProfile()
            #expect(try qc.store.load()?.profile.key == stored.profile.key)
            // Attributed to the key this device unlocked with (format.md §11.1, security review C2).
            let unlockedWith = try IdentityFile.parse(keyText)
            #expect(stored.profile.recipient == CaptureKey.fingerprint(of: unlockedWith.recipient.string))
            try model.disableQuickCapture()
            #expect(try qc.store.load() == nil)
        }

        /// TestFlight build 10: a voice note recorded or synced while the vault is open appeared only after the
        /// vault was closed and opened again. A delivery into the open vault's inbox (or a sync run that
        /// reports inbox files) adopts it at once, also while an earlier adoption is still running.
        @Test func aCaptureDeliveredToTheOpenVaultIsAdoptedLive() async throws {
            let (url, key, qc) = try await Self.setUp()
            let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
            let model = try await unlocked(url, key, qc)
            let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            let tone = try Self.audio()
            let vaultId = try #require(model.vault).vaultId

            // Recorded here: the delivery notification is all that tells the model.
            let local = UUID()
            try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: local), in: inbox)
            NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vaultId])
            let localNote = CaptureAdoption.ids(for: local).note
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.notes.contains { $0.id == localNote } })

            // Arrived by sync, while a run is going: the trigger is kept and looked at again.
            let synced = UUID()
            try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: synced), in: inbox)
            var changes = LocalChanges()
            changes.inbox = true
            model.startInboxAdoption()
            model.applySyncChanges(changes)
            let syncedNote = CaptureAdoption.ids(for: synced).note
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.notes.contains { $0.id == syncedNote } })
            // Counted after the note is listed (the adoption re-reads the note first): waited for, not read at once.
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.capturesAdopted == 2 })
            #expect(model.inboxProblem == nil)
        }

        /// Review of #25: a delivery posted off the main thread (the widget's intents and the recorder post from
        /// theirs) is adopted too; the observer hops to the main actor itself (no observer queue, which waits for
        /// ever on Linux).
        @Test func aCaptureDeliveredFromAnotherThreadIsAdopted() async throws {
            let (url, key, qc) = try await Self.setUp()
            let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
            let model = try await unlocked(url, key, qc)
            let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            let vaultId = try #require(model.vault).vaultId
            let id = UUID()
            try CaptureWriter.store(try writer.seal(audio: try Self.audio(), started: Date(), id: id), in: inbox)
            await Task.detached {
                NotificationCenter.default.post(name: QuickCapture.deliveredNotification, object: nil, userInfo: ["vault": vaultId])
            }.value
            let note = CaptureAdoption.ids(for: id).note
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.notes.contains { $0.id == note } })
            // The count goes up after the note is listed.
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.capturesAdopted == 1 })
            #expect(model.inboxProblem == nil)
        }

        /// iCloud Drive uploads files in any order, so a voice note's transcript
        /// can reach a device before its capture. The transcript waits and nothing
        /// is written: a transcript blob alone would make a note folder without
        /// revisions, which `requireLocal` refuses in iCloud Drive, so the capture
        /// could never be adopted there. Once the capture arrives, both are.
        @Test func aTranscriptBeforeItsCaptureWritesNothingUntilTheCaptureArrives() async throws {
            let (url, key, qc) = try await Self.setUp()
            let writer = try CaptureWriter(profile: try #require(try qc.store.load()).profile)
            let id = UUID()
            let ids = CaptureAdoption.ids(for: id)
            let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            let transcript = Transcript(recording: ids.recording, engine: "test", language: "en", created: Date(),
                                        segments: [.init(start: 0, end: 1, text: "Linear maps.")])
            let tone = try Self.audio()
            try CaptureWriter.store(try writer.seal(transcript: transcript, capture: id,
                                                    audio: BlobRef(content: tone, type: "audio/mp4")), in: inbox)

            let model = try await unlocked(url, key, qc)
            let folder = url.appendingPathComponent("notes/\(ids.note.uuidString.lowercased())")
            #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is written while the transcript waits")
            #expect(Self.inbox(url) == [CaptureFile.name(id, .transcript)])
            #expect(model.inboxProblem == nil)

            try CaptureWriter.store(try writer.seal(audio: tone, started: Date(), id: id), in: inbox)
            #expect(await model.adoptInbox() == 1)
            let state = try #require(model.vault).reconstruct(noteId: ids.note)
            #expect(state.recordings.map(\.id) == [ids.recording])
            #expect(state.recordings.first?.transcript != nil)
            #expect(Self.inbox(url).isEmpty)
            #expect(model.inboxProblem == nil)
        }

        /// A capture that does not verify stays in the inbox and is reported as a typed notice the app words
        /// (`AppModelNotice.voiceNoteNotAdded`; here its plain description, the library having no words).
        @Test func aCaptureThatDoesNotVerifyStaysAndIsReported() async throws {
            let (url, key, qc) = try await Self.setUp()
            let inbox = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let name = CaptureFile.name(UUID(), .capture)
            try Data("not a capture".utf8).write(to: inbox.appendingPathComponent(name))
            let model = try await unlocked(url, key, qc)
            let problem = try #require(model.inboxProblem)
            #expect(problem.contains("voiceNoteNotAdded"), "\(problem)")
            #expect(Self.inbox(url) == [name], "left in the inbox")
            #expect(model.capturesAdopted == 0)
        }
    }
}

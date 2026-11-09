import Age
import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// What used to be the host's steps (`AppModelHost`, wave 5b part 2) and is the core's own since step 7: a reopen,
    /// the attachment index, the editors' saved recordings (a service, `finishRecordingSave`) and what `close()` forgets.
    @MainActor
    struct HostStepTests {
        @Test func theCoreDoesWhatTheHostsStepsDid() async throws {
            let (url, key) = try await ModelFixture.vault()
            let text = try await ModelFixture.keyText(key)
            var services = AppModelServices.headless()
            var finished: [UUID] = []
            services.finishRecordingSave = { id, _ in finished.append(id) }
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: text)
            try await model.notesLoaded()   // the listing ends in the core's own automatic thinning: no host step

            // A vault opened again under its `vault.json`: no host step any more (takeovers and the device state are
            // the core's), and the views reopen their notes once.
            let identity = try IdentityFile.parse(text)
            let reopened = try await Self.open(url, identity)
            let epoch = model.keyEpoch
            model.adoptReopened(reopened)
            #expect(model.keyEpoch == epoch + 1)

            // A delta written with the model's clock reaches the attachment index (`noteWritten`).
            model.attachmentIndexDelay = .zero
            let id = try await model.createNote(title: "Written", paper: .ruled, notebook: nil)
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.attachmentIndex[id] != nil })

            // Every editor the model opens, for the library window or a note window, hands a saved recording's files
            // to the service (transcription is off here, so at once; the microphone half is the app's).
            model.selectedNoteID = ModelFixture.lecture
            try await model.openEditor(for: ModelFixture.lecture)
            await model.claimNote(id)
            let window = try await model.openWindowNote(id)
            let library = try #require(model.editor)
            #expect(!model.transcribesSavedRecordings)
            let a = Recording(id: UUID(), blob: BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: "audio/mp4"),
                              started: Date(), duration: 1)
            let b = Recording(id: UUID(), blob: a.blob, started: Date(), duration: 1)
            let folder = TestTemp.root.appendingPathComponent(UUID().uuidString)
            let savedInLibrary = try #require(library.onRecordingSaved)
            let savedInWindow = try #require(window.onRecordingSaved)
            savedInLibrary(a, folder, folder)
            savedInWindow(b, folder, folder)
            #expect(finished == [a.id, b.id])

            // `close()` forgets a drag in progress and a row's flash itself (step 6: no `willClose` step any more).
            model.beginDrag(.notes([id]))
            model.setDropTarget(.topLevel)
            model.landedDropDuration = .seconds(60)
            model.flashLandedDrop(.topLevel)
            #expect(model.landedDrop != nil)
            model.close()
            #expect(model.draggedPayload == nil && model.dropTarget == nil)
            #expect(model.landedDrop == nil, "no flash outlives the vault (step 6b)")
            await model.closingEditor?.value
        }

        @concurrent static func open(_ url: URL, _ identity: NativeIdentity) async throws -> Vault {
            try Vault.open(at: url, identities: [identity])
        }
    }
}

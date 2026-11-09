import Age
import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The seam to the extensions still in the app (`AppModelHost`, wave 5b part 2): which host steps the core runs,
    /// and when.
    @MainActor
    struct HostStepTests {
        @Test func theCoreRunsTheHostsStepsInOrder() async throws {
            let (url, key) = try await ModelFixture.vault()
            let text = try await ModelFixture.keyText(key)
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            try await model.openVault(at: url)
            try await model.unlock(identityText: text)
            try await model.notesLoaded()   // the listing ends in the core's own automatic thinning: no host step

            // A vault opened again under its `vault.json`: no host step any more (takeovers and the device state are
            // the core's), and the views reopen their notes once.
            let identity = try IdentityFile.parse(text)
            let reopened = try await Self.open(url, identity)
            let epoch = model.keyEpoch
            let steps = model.appState.steps
            model.adoptReopened(reopened)
            #expect(model.appState.steps == steps)
            #expect(model.keyEpoch == epoch + 1)

            // A delta written with the model's clock reaches the attachment index (`noteWritten`).
            model.attachmentIndexDelay = .zero
            let id = try await model.createNote(title: "Written", paper: .ruled, notebook: nil)
            #expect(await TS.waitUntil(timeout: .seconds(60)) { model.attachmentIndex[id] != nil })

            // An editor about to be shown, for the library window or a note window: the host's step (the microphone
            // half of saved recordings is the app's).
            let prepared = model.appState.steps.filter { $0 == "prepareEditor" }.count
            model.selectedNoteID = ModelFixture.lecture
            try await model.openEditor(for: ModelFixture.lecture)
            await model.claimNote(id)
            _ = try await model.openWindowNote(id)
            #expect(model.appState.steps.filter { $0 == "prepareEditor" }.count == prepared + 2)

            // `close()` forgets a drag in progress itself (step 6: no `willClose` step any more).
            model.beginDrag(.notes([id]))
            model.setDropTarget(.topLevel)
            model.close()
            #expect(model.draggedPayload == nil && model.dropTarget == nil)
            await model.closingEditor?.value
        }

        @concurrent static func open(_ url: URL, _ identity: NativeIdentity) async throws -> Vault {
            try Vault.open(at: url, identities: [identity])
        }
    }
}

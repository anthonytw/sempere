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
            #expect(!model.appState.steps.contains("didUnlock"), "no step before the unlock")
            try await model.unlock(identityText: text)
            #expect(model.appState.steps.last == "didUnlock", "\(model.appState.steps)")

            // A vault opened again under its `vault.json`: didReopen, and the views reopen their notes once.
            let identity = try IdentityFile.parse(text)
            let reopened = try await Self.open(url, identity)
            let epoch = model.keyEpoch
            model.adoptReopened(reopened)
            #expect(model.appState.steps.last == "didReopen")
            #expect(model.keyEpoch == epoch + 1)

            // A delta written with the model's clock reaches the host (the attachment index follows it).
            let id = try await model.createNote(title: "Written", paper: .ruled, notebook: nil)
            #expect(await TS.waitUntil { model.appState.written.contains(id) })

            let before = model.appState.steps.filter { $0 == "willClose" }.count
            model.close()
            #expect(model.appState.steps.filter { $0 == "willClose" }.count == before + 1)
        }

        @concurrent static func open(_ url: URL, _ identity: NativeIdentity) async throws -> Vault {
            try Vault.open(at: url, identities: [identity])
        }
    }
}

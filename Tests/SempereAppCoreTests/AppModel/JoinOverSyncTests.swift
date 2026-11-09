import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

extension AppModelSuites {
    /// A join over a sync target (design §6.2): the joining device's runs carry its request to the server and take
    /// home's approval back, keyless; it confirms with the reply words and then writes and syncs (moved from the app's
    /// `JoinOverSyncAppTests`).
    @MainActor
    struct JoinOverSyncTests {
        /// Home (the fixture's device, as the CLI would) and its copy's runs, off the main actor.
        struct Home: Sendable {
            let vault: URL
            let keys: DeviceKeys
            let state: URL
            let remote: MemoryRemote

            @concurrent func sync() async throws {
                let v = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
                _ = try SyncEngine(directory: vault, vault: v, remote: remote, stateURL: state, options: SyncOptions()).run()
            }

            /// Approves the request of `words` found in its copy; the reply words.
            @concurrent func approve(words: [String]) async throws -> [String] {
                var home = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
                let request = try #require(home.joinRequest(matching: words))
                return try home.approveDevice(request)
            }

            @concurrent func noteIDs() async throws -> [UUID] {
                try Vault.open(at: vault, identities: [keys.nativeIdentity]).noteIDs()
            }
        }

        @Test func aDeviceJoinsThroughAWebDAVTarget() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let server = EngineWebDAVRemote(store: MemoryStore(name: "server"))
            let home = Home(vault: vault, keys: try DeviceKeys.parse(try await ModelFixture.keyText(keyURL)),
                            state: vault.deletingLastPathComponent().appendingPathComponent("home-sync.json"), remote: server.remote)
            try await home.sync()
            let listing = try await WebDAVFixture.listing(of: vault, name: "Shared", url: "https://dav.example.org/shared/")
            let (model, library) = WebDAVFixture.device(server, trust: MemoryEpochTrustStore())
            _ = try await model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
            defer { model.close() }
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            #expect(model.phase == .locked)
            guard case .waiting(let words, _) = try await model.startJoin(store: keys.store) else { Issue.record("not waiting"); return }
            _ = await model.webdav?.syncNow()   // a join run: the request goes up

            // Home finds the request on the server, approves it by the words, and syncs the approval.
            try await home.sync()
            let reply = try await home.approve(words: words)
            try await home.sync()

            // The joining device's next run takes the approval; it confirms and unlocks.
            _ = await model.webdav?.syncNow()
            await model.refreshLockedManifest()
            #expect(await keys.unlockWithDeviceKey(model).outcome == .joining)
            #expect(keys.joinStage == .confirming, "\(String(describing: model.webdav?.lastReport))")
            let device = try await keys.store.keys(for: try #require(model.vault?.vaultId), reason: .unlock(vaultName: nil))
            try await model.confirmJoin(words: reply, keys: device)
            #expect(model.phase == .unlocked)
            #expect(model.joinIdentity == nil)
            let note = try await model.createNote(title: "Joined", paper: Paper(kind: .ruled), notebook: nil)
            _ = await model.webdav?.syncNow()
            try await home.sync()
            #expect(try await home.noteIDs().contains(note))
        }
    }
}

import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// P9 of docs/design/device-first-sync.md through the model (moved from the app's `VaultDetailsAppTests`): Vault
    /// Details (storage, devices per target) and Repair's adopt, export and delete, on two devices syncing through a
    /// folder. Add WebDAV Server… is `WebDAVTests.aWebDAVServerIsAddedOnceAsATarget`.
    @MainActor
    struct VaultDetailsTests {
        @Test func detailsShowTheCopyAndTheDevicesATargetHeld() async throws {
            let w = try await FolderTargetTests.world()
            defer { w.a.model.close(); w.b.model.close() }
            let details = try await w.a.model.vaultDetails(w.a.vaultID)
            #expect(details.storage.notes > 0)
            let target = try #require(details.targets.first)
            #expect(details.targets.count == 1)
            #expect(target.syncedFiles > 0)
            #expect(!target.devices.isEmpty)
            #expect(target.quarantined.isEmpty)
        }

        /// A good revision in the quarantine is adopted into the open vault and leaves it; a damaged one is
        /// refused and stays; Export copies it and Delete removes it.
        @Test func repairAdoptsExportsAndDeletes() async throws {
            let w = try await FolderTargetTests.world()
            defer { w.a.model.close(); w.b.model.close() }
            let model = w.a.model, vault = w.a.vaultID
            let target = try #require(model.openVaultTargets.first).id
            let quarantine = w.a.store.quarantine(target, of: vault)
            let notes = w.a.folder.appendingPathComponent("notes")
            let fm = FileManager.default
            let note = try #require(try fm.contentsOfDirectory(atPath: notes.path).first { !$0.hasPrefix(".") })
            let name = try #require(try fm.contentsOfDirectory(atPath: notes.appendingPathComponent(note).path).first { $0.hasSuffix(".age") })
            let local = notes.appendingPathComponent(note).appendingPathComponent(name)
            let held = quarantine.directory.appendingPathComponent("notes/\(note)/\(name)")
            try fm.createDirectory(at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: local, to: held)

            try await model.adoptQuarantined("notes/\(note)/\(name)", target: target, of: vault)
            #expect(fm.fileExists(atPath: local.path))
            #expect(quarantine.list().isEmpty)

            let bad = "notes/\(UUID().uuidString.lowercased())/17596320000990000-cccccccc-1.delta.age"
            let badURL = quarantine.directory.appendingPathComponent(bad)
            try fm.createDirectory(at: badURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("age-encryption.org/v1\n-> X25519 junk\n---\n".utf8).write(to: badURL)
            await #expect(throws: QuarantineError.self) { try await model.adoptQuarantined(bad, target: target, of: vault) }
            #expect(quarantine.list().map(\.path) == [bad])

            let out = TestTemp.root.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            let copy = try await model.exportQuarantined(bad, target: target, of: vault, to: out)
            #expect(fm.fileExists(atPath: copy.path))
            try await model.deleteQuarantined(bad, target: target, of: vault)
            #expect(quarantine.list().isEmpty)
        }
    }

    /// Re-encrypt Everything over a folder target (key-hierarchy design §7; phase KH6; moved from the app's
    /// `ReencryptAppTests`): the start through the model (claims on the vault's sync targets, the `reencrypt` epoch) and
    /// the progress sheet's steps (`advanceReencryption`) until the finish, with the vault opened again under the new key
    /// each time, on a vault copied in with a folder target (`copyIn`). A vault without targets, one step at a time and
    /// only home: `DevicesTests`.
    @MainActor
    struct ReencryptOverFolderTests {
        static func everyDeviceKept(_ model: AppModel) async throws -> Set<String> {
            Set(try await model.kitReview().compactMap(\.device.id))
        }

        @Test func aFolderTargetIsClaimedCarriedAndConfirmed() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let a = FolderTargetTests.device(nil)
            a.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)   // the start asks for the owner
            try await a.model.copyIn(picked: vault, library: a.library)
            try await a.model.unlock(identityText: key)
            defer { a.model.close() }
            try a.model.addFolderTarget(shared, scope: drive, to: a.vaultID)
            await a.model.syncAllTargetsNow()
            let notes = Set(a.model.notes.map(\.id))
            let oldFiles = FolderTargetTests.noteFiles(shared)
            #expect(!oldFiles.isEmpty)

            let newKit = try MLKEM768X25519Identity()
            _ = try await a.model.startReencryption(newKit, keep: try await Self.everyDeviceKept(a.model), remove: [], passphrase: nil)
            #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("reencrypt-journal.age").path), "claimed")
            var finished = false
            var lines: [ReencryptProgress.TargetLine] = []
            for _ in 0..<4 where !finished {
                let step = try await a.model.advanceReencryption()
                finished = step.finished
                lines = step.targets
            }
            #expect(finished)
            #expect(lines.map(\.name) == a.model.syncSessions.map(\.targetName))
            #expect(lines.allSatisfy { $0.reached && $0.confirmed && $0.current == $0.files }, "\(lines)")
            await a.model.syncAllTargetsNow()
            let sessions = a.model.syncSessions.map { "\($0.targetName): \($0.problems) \(String(describing: $0.failure))" }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !FileManager.default.fileExists(atPath: shared.appendingPathComponent("reencrypt-journal.age").path) },
                    "\(sessions)")
            let epochs = try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("epochs").path)
            #expect(!epochs.contains { $0.hasPrefix("1-") }, "earlier records deleted on the target")
            // Every note file in the target was replaced in place (same names, new bytes under the new key).
            #expect(FolderTargetTests.noteFiles(shared) == FolderTargetTests.noteFiles(a.folder))
            #expect(Set(a.model.notes.map(\.id)) == notes)
            #expect(try await !a.model.reencryptStatus().pending)
        }

        /// Review of #89, S6: a start killed between the claim and the epoch (its local journal and the target's claim
        /// left behind) does not hold the next start off: the leftovers go first.
        @Test func aStartKilledBeforeItsEpochDoesNotBlockTheNext() async throws {
            let (vault, keyURL) = try await ModelFixture.vault()
            let key = try await ModelFixture.keyText(keyURL)
            let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
            let a = FolderTargetTests.device(nil)
            a.model.ownerAuthenticator = ScriptedOwnerCheck(.pass)   // the start asks for the owner
            try await a.model.copyIn(picked: vault, library: a.library)
            try await a.model.unlock(identityText: key)
            defer { a.model.close() }
            try a.model.addFolderTarget(shared, scope: drive, to: a.vaultID)
            await a.model.syncAllTargetsNow()
            // The killed start: prepared and claimed, no epoch.
            let v = try #require(a.model.vault)
            let keep = try await Self.everyDeviceKept(a.model)
            let prep = try v.prepareReencryption(try MLKEM768X25519Identity(), keep: keep, remove: [])
            let (targets, close) = try await a.model.openReencryptTargets(requireAll: true)
            var seen: ReencryptCoordinator.ClaimSightings = [:]
            let claims = ReencryptCoordinator.claim(prep.journalFile, vault: v, on: targets, seen: &seen)
            #expect(claims.values.allSatisfy { $0.isClaimed })
            close()
            _ = try await a.model.startReencryption(try MLKEM768X25519Identity(), keep: keep, remove: [], passphrase: nil)
            #expect(a.model.vault?.isReencryptPending == true)
        }
    }
}

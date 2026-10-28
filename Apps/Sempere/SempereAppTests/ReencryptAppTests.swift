import Age
import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// Re-encrypt Everything in the app (key-hierarchy design §7; phase KH6): the start through the model (claims on
/// the vault's sync targets, the `reencrypt` epoch) and the progress sheet's steps (`advanceReencryption`) until
/// the finish, with the vault opened again under the new key each time; a vault without targets finishes at once.
@Suite(.serialized)
@MainActor
struct ReencryptAppTests {
    static func everyDeviceKept(_ model: AppModel) async throws -> Set<String> {
        Set(try await model.kitReview().compactMap(\.device.id))
    }

    @Test func aVaultWithoutTargetsFinishesInOneStep() async throws {
        let w = try DevicesAppTests.World(others: ["Phone"])
        let model = try await w.model()
        defer { model.close() }
        let titles = Set(model.notes.map(\.id))
        let before = try #require(model.vault?.manifest.epoch)
        let newKit = try MLKEM768X25519Identity()
        let started = try await model.startReencryption(newKit, keep: try await Self.everyDeviceKept(model), remove: [], passphrase: nil)
        #expect(started.report.reason == .reencrypt)
        #expect(model.vault?.manifest.epoch == before + 1)
        #expect(try await model.reencryptStatus().pending)
        let step = try await model.advanceReencryption()
        #expect(step.finished)
        #expect(step.status?.pending == false)
        #expect(step.status?.remaining == 0)
        #expect(!FileManager.default.fileExists(atPath: try #require(model.vaultURL).appendingPathComponent("reencrypt-journal.age").path))
        #expect(Set(model.notes.map(\.id)) == titles)
        #expect(model.vault?.manifest.recoveryEntry?.key == newKit.recipient.string)
        let list = try await model.loadDeviceList()
        #expect(list.history.first?.reason == .reencrypt)
    }

    @Test func aFolderTargetIsClaimedCarriedAndConfirmed() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let a = FolderTargetAppTests.device(nil)
        try await a.model.copyIn(picked: vault, library: a.library)
        try await a.model.unlock(identityText: key)
        defer { a.model.close() }
        try a.model.addFolderTarget(shared, scope: drive, to: a.vaultID)
        await a.model.syncAllTargetsNow()
        let notes = Set(a.model.notes.map(\.id))
        let oldFiles = FolderTargetAppTests.noteFiles(shared)
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
        #expect(await TS.waitUntil { !FileManager.default.fileExists(atPath: shared.appendingPathComponent("reencrypt-journal.age").path) },
                "\(sessions)")
        let epochs = try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("epochs").path)
        #expect(!epochs.contains { $0.hasPrefix("1-") }, "earlier records deleted on the target")
        // Every note file in the target was replaced in place (same names, new bytes under the new key).
        #expect(FolderTargetAppTests.noteFiles(shared) == FolderTargetAppTests.noteFiles(a.folder))
        #expect(Set(a.model.notes.map(\.id)) == notes)
        #expect(try await !a.model.reencryptStatus().pending)
    }

    /// Review of #89, S6: a start killed between the claim and the epoch (its local journal and the target's claim
    /// left behind) does not hold the next start off: the leftovers go first.
    @Test func aStartKilledBeforeItsEpochDoesNotBlockTheNext() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let a = FolderTargetAppTests.device(nil)
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

    /// Review of #89, S7: one step at a time; Stop ends it with `CancellationError`, and a later step goes on.
    @Test func oneStepAtATimeAndStopEndsIt() async throws {
        let w = try DevicesAppTests.World(others: ["Phone"])
        let model = try await w.model()
        defer { model.close() }
        _ = try await model.startReencryption(try MLKEM768X25519Identity(), keep: try await Self.everyDeviceKept(model), remove: [],
                                              passphrase: nil)
        model.isAdvancingReencryption = true
        await #expect(throws: VaultError.self, "a second step is refused while one goes") { _ = try await model.advanceReencryption() }
        model.isAdvancingReencryption = false
        let step = Task { try await model.advanceReencryption() }
        await Task.yield()
        model.cancelReencryptionStep()
        let first = await step.result
        #expect(!model.isAdvancingReencryption)
        switch first {
        case .success(let p):
            #expect(p.finished, "not stopped in time: the step ran to its end")
        case .failure(let e):
            #expect(e is CancellationError, "\(e)")
            #expect(try await model.advanceReencryption().finished, "the next step goes on and finishes")
        }
    }

    @Test func onlyHomeAdvances() async throws {
        let w = try DevicesAppTests.World(others: ["Phone"])
        let phone = try await w.model("Phone")
        defer { phone.close() }
        await #expect(throws: VaultError.self) { _ = try await phone.advanceReencryption() }
    }
}

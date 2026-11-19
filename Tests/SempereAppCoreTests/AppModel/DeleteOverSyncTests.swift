import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Notes deleted on one device stay deleted on both, through a folder target (an owner report, 2026-11-19: voice
    /// notes deleted on an iPad came back after the iPhone synced). Two devices of `FolderTargetTests`' world: A
    /// deletes in bulk (`deleteNotes`, one commit); B, which has not seen the delete, adopted the notes from its inbox,
    /// edits them, thins every note, is handed the same captures again (a watch that sends a note twice) and adopts
    /// them, and syncs; or its vault is closed and the delete arrives as staging that its unlock places.
    @MainActor
    struct DeleteOverSyncTests {
        typealias F = FolderTargetTests

        /// Two-way runs on both until `done` holds (or `rounds` runs).
        static func sync(_ w: F.World, rounds: Int = 10, until done: () -> Bool) async -> Bool {
            for _ in 0..<rounds {
                if done() { return true }
                await w.a.model.syncAllTargetsNow()
                await w.b.model.syncAllTargetsNow()
                _ = await TS.waitUntil(timeout: .seconds(2), done)
            }
            return done()
        }

        /// `rounds` two-way runs on both, each with a short settle for what a run starts after it returns (a refresh of
        /// the list): a fixed number of runs, nothing to wait for (`sync`'s two-second wait per round was idle there).
        static func sync(_ w: F.World, rounds: Int) async {
            for _ in 0..<rounds {
                await w.a.model.syncAllTargetsNow()
                await w.b.model.syncAllTargetsNow()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        static func expectDeleted(_ w: F.World, _ ids: [UUID], _ sourceLocation: SourceLocation = #_sourceLocation) throws {
            for id in ids {
                #expect(try #require(w.a.model.vault).reconstruct(noteId: id).deleted, "A's copy", sourceLocation: sourceLocation)
                #expect(try #require(w.b.model.vault).reconstruct(noteId: id).deleted, "B's copy", sourceLocation: sourceLocation)
                #expect(w.a.model.notes.first { $0.id == id }?.deleted == true, "A's list", sourceLocation: sourceLocation)
                #expect(w.b.model.notes.first { $0.id == id }?.deleted == true, "B's list", sourceLocation: sourceLocation)
            }
        }

        @Test func aBulkDeleteSurvivesAStaleDevicesEditsThinningAndReadoption() async throws {
            let w = try await F.world()
            defer { w.a.model.close(); w.b.model.close() }
            var ids: [UUID] = []
            for i in 0..<2 { ids.append(try await w.a.model.createNote(title: "N\(i)", paper: .ruled, notebook: nil)) }
            // Voice notes B adopted from its inbox (the phone takes the watch's notes).
            let vb = try #require(w.b.model.vault)
            let profile = try vb.captureProfile(device: DeviceID("0badf00d")!)
            var captures: [SealedCapture] = []
            for _ in 0..<3 {
                let sealed = try CaptureWriter(profile: profile).seal(audio: try InboxTests.audio(), started: Date(), id: UUID())
                try CaptureWriter.store(sealed, in: vb.inboxURL)
                captures.append(sealed)
                ids.append(CaptureAdoption.ids(for: try #require(CaptureFile.parse(name: sealed.name)?.id)).note)
            }
            await w.b.model.adoptInbox()
            #expect(await Self.sync(w) { ids.allSatisfy { id in w.a.model.notes.contains { $0.id == id } && w.b.model.notes.contains { $0.id == id } } })

            #expect(Set(try await w.a.model.deleteNotes(ids)) == Set(ids))
            await w.a.model.syncAllTargetsNow()
            // B has not run since: it renames one, favorites another, thins everything and adopts the same captures again.
            try await w.b.model.renameNote(ids[2], to: "Renamed on B")
            try await w.b.model.setFavorite(true, for: ids[3])
            _ = try await w.b.model.thinVault(rule: .allButCheckpoints, dryRun: false)
            for c in captures { try? CaptureWriter.store(c, in: vb.inboxURL) }
            await w.b.model.adoptInbox()
            #expect(await Self.sync(w) {
                ids.allSatisfy { id in w.b.model.notes.first { $0.id == id }?.deleted == true && w.a.model.notes.first { $0.id == id }?.deleted == true }
            }, "B: \(w.b.model.notes.filter { ids.contains($0.id) }.map { "\($0.title) \($0.deleted)" })")
            // Once more after the delete arrived: the captures again, and A thins too.
            for c in captures { try? CaptureWriter.store(c, in: vb.inboxURL) }
            await w.b.model.adoptInbox()
            _ = try await w.a.model.thinVault(rule: .allButCheckpoints, dryRun: false)
            await Self.sync(w, rounds: 3)
            try Self.expectDeleted(w, ids)
            #expect(try #require(w.a.model.vault).reconstruct(noteId: ids[2]).meta.title == "Renamed on B", "B's edit is kept")
        }

        @Test func aDeleteStagedWhileTheVaultIsClosedIsPlacedAndStays() async throws {
            let w = try await F.world()
            defer { w.a.model.close(); w.b.model.close() }
            var ids: [UUID] = []
            for i in 0..<3 { ids.append(try await w.a.model.createNote(title: "N\(i)", paper: .ruled, notebook: nil)) }
            #expect(await Self.sync(w) { ids.allSatisfy { id in w.b.model.notes.contains { $0.id == id } } })
            let bID = w.b.vaultID
            let coordinator = w.b.model.syncCoordinator
            coordinator.start()   // every vault syncs, as in the app
            defer { for id in coordinator.sessions.keys { _ = coordinator.stop(id) } }
            w.b.model.close()
            await w.b.model.closingEditor?.value

            _ = try await w.a.model.deleteNotes(ids)
            await w.a.model.syncAllTargetsNow()
            let session = try #require(coordinator.sessions(of: bID).first)
            _ = await session.runInBackground(maxDuration: 30, cancel: SyncRunCancel())   // stages the delete
            let entry = try #require(w.b.store.entry(id: bID))
            try await w.b.model.openStored(entry, library: w.b.library)
            try await w.b.model.unlock(identityText: w.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { ids.allSatisfy { id in w.b.model.notes.first { $0.id == id }?.deleted == true } })
            try await w.b.model.renameNote(ids[0], to: "Renamed after")
            await Self.sync(w, rounds: 3)
            try Self.expectDeleted(w, ids)
        }

        static func make(_ w: F.World) async throws -> [UUID] {
            var ids: [UUID] = []
            for i in 0..<3 { ids.append(try await w.a.model.createNote(title: "N\(i)", paper: .ruled, notebook: nil)) }
            #expect(await Self.sync(w) { ids.allSatisfy { id in w.b.model.notes.contains { $0.id == id } } })
            return ids
        }

        static func reopenA(_ w: F.World, id: UUID) async throws {
            w.a.model.close()
            await w.a.model.closingEditor?.value
            let entry = try #require(w.a.store.entry(id: id))
            try await w.a.model.openStored(entry, library: w.a.library)
            try await w.a.model.unlock(identityText: w.key)
        }

        /// The owner's flow (1.2 deleted, the app closed before a run, 1.3 opened it): A deletes and closes before any
        /// run; B, which never saw the delete, edits and syncs; A opens the vault again and syncs.
        @Test func aDeleteNeverPushedBeforeTheAppClosedIsPushedWhenItOpensAgain() async throws {
            let w = try await F.world()
            defer { w.a.model.close(); w.b.model.close() }
            let ids = try await Self.make(w)
            let vid = w.a.vaultID
            for id in ids { try await w.a.model.deleteNote(id) }
            w.a.model.close()
            await w.a.model.closingEditor?.value
            try await w.b.model.renameNote(ids[0], to: "B")
            await w.b.model.syncAllTargetsNow()
            try await Self.reopenA(w, id: vid)
            await Self.sync(w, rounds: 4)
            try Self.expectDeleted(w, ids)
        }

        /// The delete reached the folder, then the folder lost those files (the provider never uploaded them, or put an
        /// older copy of the note folder back): A puts them back, B takes them.
        @Test func aDeleteTheFolderLostIsPutBack() async throws {
            let w = try await F.world()
            defer { w.a.model.close(); w.b.model.close() }
            let ids = try await Self.make(w)
            let vid = w.a.vaultID
            let before = F.noteFiles(w.shared)
            for id in ids { try await w.a.model.deleteNote(id) }
            await w.a.model.syncAllTargetsNow()
            for f in F.noteFiles(w.shared).subtracting(before) {
                try FileManager.default.removeItem(at: w.shared.appendingPathComponent("notes").appendingPathComponent(f))
            }
            await w.b.model.syncAllTargetsNow()
            try await Self.reopenA(w, id: vid)
            await Self.sync(w, rounds: 4)
            try Self.expectDeleted(w, ids)
        }

        /// The delete reached the folder; the note folders then list empty for A's next run (a provider's fresh listing):
        /// nothing is deleted or taken for deleted.
        @Test func aFolderThatListsEmptyDeletesNothing() async throws {
            let w = try await F.world()
            defer { w.a.model.close(); w.b.model.close() }
            let ids = try await Self.make(w)
            let vid = w.a.vaultID
            for id in ids { try await w.a.model.deleteNote(id) }
            await w.a.model.syncAllTargetsNow()
            for id in ids { try w.provider.unlist("notes/\(id.uuidString.lowercased())") }
            try await Self.reopenA(w, id: vid)
            await w.a.model.syncAllTargetsNow()
            await w.b.model.syncAllTargetsNow()
            await Self.sync(w, rounds: 4)
            try Self.expectDeleted(w, ids)
        }
    }
}

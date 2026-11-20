import Foundation
import Observation
import Sempere
@testable import SempereAppCore
import SempereSync
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Idle sync runs publish nothing the welcome list's "On This Device" section and the note list are built from
    /// (owner, TestFlight 1.3.0 build 111: a vault row's swipe and its Delete confirmation closed by themselves within
    /// moments). Every vault's target runs while the vault is closed (upload-only), and folder targets re-ask their
    /// provider between runs; each run changes its session's status (`isSyncing`, `lastSuccess`, the provider's
    /// count). The section built its rows from those statuses, so every run redrew them, and the alert hanging off the
    /// section was dismissed when the list re-hosted its cells. The section now reads only the inputs below, each
    /// row's status line observes its sessions by itself (`StoredVaultStatus` in the app), and the confirmations hang
    /// off the welcome list itself (`WelcomeRemovalDialogs`).
    @MainActor
    struct IdleSyncListTests {
        /// Counts the changes observed in what `read` reads; `arm` again after each change.
        @MainActor
        final class Watch {
            var changes = 0
            let read: @MainActor () -> Void
            init(_ read: @escaping @MainActor () -> Void) { self.read = read; arm() }
            func arm() {
                withObservationTracking { read() } onChange: { [weak self] in
                    Task { @MainActor in self?.changes += 1; self?.arm() }
                }
            }
        }

        @Test func idleRunsOfAClosedVaultChangeNothingTheVaultListReads() async throws {
            let w = try await FolderTargetTests.world(withB: false)
            let model = w.a.model, library = w.a.library, id = w.a.vaultID
            defer { model.close() }
            model.syncCoordinator.start()   // every vault's targets run, as in the app (`SempereApp`)
            model.close()
            let session = try #require(model.syncCoordinator.sessions(of: id).first)
            // A run after the close, so the runs counted are the idle ones.
            _ = await session.syncNow()

            let section = Watch {
                _ = library.storedVaultsByUse
                _ = library.recents
                _ = model.webdavLocations.locations
                _ = model.syncCoordinator.sessions(of: id).map(\.locationID)
            }
            let status = Watch { _ = session.status }
            for _ in 0..<5 {
                _ = await session.syncNow()
                await session.recheckProvider()
            }
            await library.refreshStoredVaults(log: NoPerfSink())
            await Task.yield()
            #expect(status.changes > 0, "the runs went (their status changed)")
            #expect(section.changes == 0, "nothing the section is built from changed")
        }

        @Test func idleRunsOfTheOpenVaultChangeNothingTheNoteListReads() async throws {
            let w = try await FolderTargetTests.world(withB: false)
            let model = w.a.model
            defer { model.close() }
            let session = try #require(model.syncSessions.first)
            _ = await session.syncNow()

            let list = Watch {
                _ = model.visibleNotes
                _ = model.isVaultReadOnly
                _ = model.syncSessions
                _ = model.loading
                _ = model.placeholderNoteIDs
                _ = model.pendingNoteIDs
                _ = model.emptyListReason
                _ = model.notesNeedingRecognition
                for note in model.notes { _ = model.displayTitle(note) }
            }
            let status = Watch { _ = session.status }
            for _ in 0..<5 {
                _ = await session.syncNow()
                await session.recheckProvider()
            }
            await Task.yield()
            #expect(status.changes > 0, "the runs went (their status changed)")
            #expect(list.changes == 0, "nothing the note list is built from changed")
        }
    }
}

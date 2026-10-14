import Foundation
import SempereRender
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// iCloud Drive as iPadOS 26 presents it (dataless files under their real
/// names, folders listed before their contents), the sync progress model,
/// and the guarantees that a note is never shown or written from a partial
/// log.
@MainActor
struct CloudSyncTests {
    static let lecture = ProgressiveLoadTests.lecture
    static let other = ProgressiveLoadTests.other

    static func model(_ cloud: FakeCloud, stall: Duration = .seconds(5)) -> AppModel {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        model.cloudStallTimeout = stall
        return model
    }

    static func revisionCount(_ vault: URL, _ id: UUID) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("notes/\(id.uuidString.lowercased())").path)
            .filter { $0.hasSuffix(".age") && !$0.hasPrefix(".") }.count
    }

    // MARK: - Root causes

    /// A note folder that lists no file is a note iCloud has not listed yet,
    /// never an empty note: it is pending and its folder is requested.
    @Test func anUnlistedNoteFolderIsPendingNotAnEmptyNote() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.other)
        let pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.ready == [Self.lecture])
        #expect(pass.pending == [Self.other])
        #expect(pass.unlisted == [Self.other])
        #expect(cloud.requestedFolders == [Self.other.uuidString.lowercased()])
        #expect(pass.files == pass.localFiles)
        #expect(pass.files > 0)
    }

    /// Dataless files keep their real names (no `.icloud` stand-in): they
    /// count as missing, and are not local.
    @Test func datalessRealNameFilesArePendingAndCounted() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        let pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.pending == [Self.lecture])
        #expect(pass.unlisted.isEmpty)
        let lectureFiles = try Self.revisionCount(url, Self.lecture)
        #expect(pass.localFiles == pass.files - lectureFiles)
        #expect(cloud.requestedNotes == [Self.lecture.uuidString.lowercased()])
    }

    @Test func requireLocalRefusesDatalessAndUnlistedNotes() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try CloudVault.requireLocal(note: Self.lecture, vault: url, hooks: cloud.hooks)
        try cloud.evictDataless(Self.lecture)
        let n = try Self.revisionCount(url, Self.lecture)
        #expect(throws: CloudVault.CloudError.noteNotLocal(missing: n, total: n)) {
            try CloudVault.requireLocal(note: Self.lecture, vault: url, hooks: cloud.hooks)
        }
        try cloud.unlist(Self.other)
        #expect(throws: CloudVault.CloudError.noteNotLocal(missing: 0, total: 0)) {
            try CloudVault.requireLocal(note: Self.other, vault: url, hooks: cloud.hooks)
        }
        #expect(CloudVault.CloudError.noteNotLocal(missing: 0, total: 0).description.contains("not listed"))
    }

    /// The device bug: a note opened while iCloud had not listed its files
    /// came up as an empty, editable page. Now the canvas waits for them and
    /// shows the ink.
    @Test func openingAnUnlistedNoteWaitsForItsFilesAndShowsTheInk() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.lecture)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.placeholderNoteIDs.contains(Self.lecture))
        model.selectedNoteID = Self.lecture
        let showing = Task { await model.showSelectedNote() }
        #expect(await TS.waitUntil { cloud.requestedFolders.contains(Self.lecture.uuidString.lowercased()) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.editor == nil)                 // not opened as an empty note
        try cloud.deliver(Self.lecture)
        await showing.value
        let editor = try #require(model.editor)
        #expect(editor.pages.count == 2)
        #expect(editor.pages.flatMap(\.strokes).count > 0)
        #expect(model.editorFailure == nil)
        model.close()
    }

    /// Dataless real-name files are downloaded before the canvas reads them.
    @Test func openingADatalessNoteDownloadsItFirst() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        let showing = Task { await model.showSelectedNote() }
        #expect(await TS.waitUntil { model.noteDownload?.id == Self.lecture })
        #expect(model.noteDownload?.progress.total == (try Self.revisionCount(url, Self.lecture)))
        try cloud.deliver(Self.lecture)
        await showing.value
        #expect(model.editor?.pages.count == 2)
        #expect(model.editor?.isReadOnly == false)
        #expect(model.noteDownload == nil)
        model.close()
    }

    /// When the files never come, the detail pane says so (no blank canvas,
    /// no alert to miss) and nothing is written into the note.
    @Test func aNoteThatNeverArrivesShowsAFailureAndWritesNothing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.lecture)
        let model = Self.model(cloud, stall: .milliseconds(150))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        #expect(model.editor == nil)
        let failure = try #require(model.editorFailure)
        #expect(failure.id == Self.lecture)
        #expect(!failure.message.isEmpty)
        #expect(try Self.revisionCount(url, Self.lecture) == 0)
        // Retrying once the files are there opens it.
        try cloud.deliver(Self.lecture)
        await model.showSelectedNote()
        #expect(model.editorFailure == nil)
        #expect(model.editor?.pages.count == 2)
        model.close()
    }

    /// A file that goes missing between the download and the read (iCloud
    /// evicts it, another device adds one) is caught inside the editor's
    /// read (`verify`), which refuses to load the note; `openEditor` then
    /// downloads it again.
    @Test func theEditorReadRefusesAFileThatWentMissing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let clock = try model.deviceClockForWriting()
        let vault = try #require(try? Vault.open(at: url, identities: [IdentityFile.parse(String(contentsOf: key, encoding: .utf8))]))
        try cloud.evictDataless(Self.lecture)
        let hooks = cloud.hooks
        let id = Self.lecture
        await #expect(throws: CloudVault.CloudError.self) {
            _ = try await NoteEditor.open(vault: vault, noteID: id, clock: clock, coordinated: false,
                                          verify: { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) })
        }
        model.close()
    }

    /// The browser's append re-checks inside its read: a note evicted since
    /// `downloadNote` (or never downloaded, as in a notebook rename, which
    /// relies on the last pass) gets no delta, whose seq and clock would come
    /// from a partial log.
    @Test func noteWriterAppendRefusesANoteThatIsNotLocal() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let text = try String(contentsOf: key, encoding: .utf8)
        let vault = try Vault.open(at: url, identities: [IdentityFile.parse(text)])
        let clock = try DeviceClock(url: TS.deviceStateURL())
        try cloud.evictDataless(Self.lecture)
        let before = try Self.revisionCount(url, Self.lecture)
        let hooks = cloud.hooks
        let id = Self.lecture
        await #expect(throws: CloudVault.CloudError.self) {
            try await NoteWriter.append([.setMeta(.title("X"))], to: id, vault: vault, clock: clock,
                                        verify: { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) })
        }
        #expect(try Self.revisionCount(url, Self.lecture) == before)
    }

    /// A new note in an iCloud vault has no files yet: creating it must not
    /// run the "every file is local" check, which refuses an empty folder
    /// (TestFlight build 4: "has not listed this note's files yet (0 missing)").
    @Test func creatingANoteInAnICloudVaultWritesIt() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud, stall: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.isCloudVault)
        let id = try await model.createNote(title: "New in iCloud", paper: .blank, notebook: nil)
        #expect(try Self.revisionCount(url, id) == 1)
        #expect(model.notes.contains { $0.id == id && $0.title == "New in iCloud" })
        let filed = try await model.createNote(title: "Filed", paper: .blank, notebook: "School/Math")
        #expect(model.notes.first { $0.id == filed }?.notebook == "School/Math")
        // Later edits of the new note still run the check, and pass: its file is local.
        try await model.renameNote(id, to: "Renamed")
        #expect(model.notes.first { $0.id == id }?.title == "Renamed")
        model.close()
    }

    /// The creation exemption never lets an existing note through: an id
    /// whose folder lists revisions is checked even when passed as new, so
    /// nothing is written into it while one of them is evicted.
    @Test func theCreationExemptionNeverCoversAnExistingNote() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud, stall: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.pauseCloudSync()
        try cloud.evictDataless(Self.lecture)
        let before = try Self.revisionCount(url, Self.lecture)
        let lecture = Self.lecture
        await #expect(throws: CloudVault.CloudError.self) {
            try await model.commit(ids: [lecture], creating: [lecture]) { vault, clock, cloud, verifier in
                try await NoteWriter.append([.setMeta(.title("X"))], to: lecture, vault: vault, clock: clock,
                                            coordinated: cloud, verify: verifier(lecture))
            }
        }
        #expect(try Self.revisionCount(url, Self.lecture) == before)
        model.close()
    }

    @Test func aNotebookRenameWritesNothingIntoANoteEvictedSinceTheLastPass() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud, stall: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try await model.moveNote(Self.lecture, toNotebook: "Old")
        model.pauseCloudSync()                      // the loop has not seen the eviction yet
        try cloud.evictDataless(Self.lecture)
        #expect(model.pendingNoteIDs.isEmpty)
        let before = try Self.revisionCount(url, Self.lecture)
        await #expect(throws: (any Error).self) { try await model.renameNotebook("Old", to: "New") }
        #expect(try Self.revisionCount(url, Self.lecture) == before)
        model.close()
    }

    /// A replaced loop's sleep is ended when the new loop starts sleeping
    /// before the old one's cancellation was handled: its task returns.
    @Test func aNewSleepEndsAReplacedLoopsSleep() async throws {
        final class Flag: @unchecked Sendable { var done = false }
        let wakeup = SyncWakeup()
        let flag = Flag()
        let old = Task { @MainActor in
            try? await wakeup.sleep(for: .seconds(60))
            flag.done = true
        }
        try await Task.sleep(for: .milliseconds(50))   // the old loop is asleep
        old.cancel()                                   // its resume is queued on the main actor
        Task { @MainActor in wakeup.wake() }           // queued after it: ends the new sleep
        try await wakeup.sleep(for: .seconds(60))      // installs its waiter before either runs
        #expect(await TS.waitUntil(timeout: .seconds(2)) { flag.done }, "the replaced loop's task returned")
    }

    /// A note whose read failed (a revision unreadable for a moment) is read
    /// again by the next pass of the sync loop, not shown with its problem
    /// until the next full reload.
    @Test func aNoteWithAProblemIsReadAgainByTheNextPass() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let dir = url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".age") && !$0.hasPrefix(".") }.sorted().first)
        let fileURL = dir.appendingPathComponent(file)
        let original = try Data(contentsOf: fileURL)
        try Data("not an age file".utf8).write(to: fileURL)
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        model.cloudMaxIdleInterval = .milliseconds(40)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { model.notes.first { $0.id == Self.lecture }?.problem != nil })
        try original.write(to: fileURL)              // same name: only a re-read can tell
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            model.notes.first { $0.id == Self.lecture }.map { $0.problem == nil } ?? false
        })
        model.close()
    }

    /// A rename over several notes, one of them evicted (shown from the index,
    /// so not pending): nothing is written while it cannot be downloaded, and
    /// every note is renamed once it can. Never half a notebook.
    @Test func aNotebookRenameDownloadsEvictedNotesFirstAndNeverStopsHalfway() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud, stall: .milliseconds(200))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try await model.moveNote(Self.lecture, toNotebook: "Old")
        try await model.moveNote(Self.other, toNotebook: "Old")   // deleted notes move with their notebook too
        model.pauseCloudSync()
        try cloud.evictDataless(Self.other)
        let before = (try Self.revisionCount(url, Self.lecture), try Self.revisionCount(url, Self.other))
        await #expect(throws: (any Error).self) { try await model.renameNotebook("Old", to: "New") }
        #expect(try Self.revisionCount(url, Self.lecture) == before.0, "the local note was not renamed alone")
        #expect(try Self.revisionCount(url, Self.other) == before.1)

        cloud.autoDeliver = true
        try await model.renameNotebook("Old", to: "New")
        #expect(try Self.revisionCount(url, Self.lecture) == before.0 + 1)
        #expect(try Self.revisionCount(url, Self.other) == before.1 + 1)
        #expect(model.notes.filter { [Self.lecture, Self.other].contains($0.id) }.allSatisfy { $0.notebook == "New" })
        model.close()
    }

    /// A pass of a loop that was replaced or paused meanwhile publishes
    /// nothing (it could overwrite a newer pass's pending set).
    @Test func aCancelledPassPublishesNothing() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var armed = false
            weak var model: AppModel?
        }
        let box = Box()
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: {
            guard box.lock.withLock({ box.armed }) else { return }
            await MainActor.run { box.model?.cloudSyncTask?.cancel() }
        })
        box.model = model
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        try await model.openVault(at: url)
        #expect(await TS.waitUntil { model.cloudSync != nil })
        model.pauseCloudSync()
        model.cloudSync = nil
        box.lock.withLock { box.armed = true }
        model.startCloudSync()
        let task = try #require(model.cloudSyncTask)
        await task.value
        #expect(model.cloudSync == nil)
        box.lock.withLock { box.armed = false }
        model.close()
    }

    /// In the background the loop stops (no polling, no battery); its status
    /// stays, and becoming active resumes it.
    @Test func pausingTheLoopKeepsItsStatusAndStartResumesIt() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { model.cloudSync?.readyNotes == 2 })
        let task = try #require(model.cloudSyncTask)
        model.pauseCloudSync()
        await task.value                             // the loop ended
        #expect(model.cloudSyncTask == nil)
        #expect(model.cloudSync?.readyNotes == 2)
        try TS.writeAsAnotherDevice([.setMeta(.title("Changed elsewhere"))], to: Self.other, vault: url, key: key)
        try cloud.evictDataless(Self.other)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.pendingNoteIDs.isEmpty)        // nobody looked
        model.startCloudSync()
        #expect(await TS.waitUntil { model.pendingNoteIDs == [Self.other] })
        model.close()
    }

    /// Settled and unchanged, the loop slows from the idle pace to at most
    /// `cloudMaxIdleInterval`.
    @Test func theIdlePaceBacksOffWhileNothingChanges() {
        let base = Duration.seconds(15), max = Duration.seconds(60)
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: 0) == .seconds(15))
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: 1) == .seconds(30))
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: 2) == .seconds(60))
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: 3) == .seconds(60))
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: 1_000_000) == .seconds(60))
        #expect(AppModel.idleInterval(base: base, max: max, idlePasses: -1) == .seconds(15))
        #expect(AppModel(deviceStateURL: TS.deviceStateURL()).cloudMaxIdleInterval == .seconds(60))
    }

    // MARK: - Starting automatically

    /// Downloads start as soon as the vault is opened, before the key is
    /// entered, and the list fills after unlocking without a pull to refresh.
    @Test func syncStartsWhenTheVaultOpensAndFillsTheListWithoutARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        try cloud.evictDataless(Self.other)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        #expect(model.phase == .locked)
        #expect(await TS.waitUntil { model.cloudSync?.notes == 2 })
        #expect(model.cloudSync?.readyNotes == 0)
        #expect(model.cloudSync?.isDownloading == true)
        #expect(Set(cloud.requestedNotes) == Set([Self.lecture, Self.other].map { $0.uuidString.lowercased() }))
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.placeholderNoteIDs.count == 2)
        try cloud.deliver(Self.lecture)
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.placeholderNoteIDs.isEmpty && model.cloudSync?.isDownloading == false })
        #expect(model.notes.allSatisfy { !$0.title.isEmpty })
        model.close()
    }

    /// The loop never stops while the vault is open: a revision another
    /// device writes later arrives on its own.
    @Test func laterChangesArriveWithoutARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try await Task.sleep(for: .milliseconds(200))           // settled, idling
        try TS.writeAsAnotherDevice([.setMeta(.title("Renamed on the Mac"))], to: Self.lecture, vault: url, key: key)
        try cloud.evictDataless(Self.lecture)                   // listed, not downloaded yet
        #expect(await TS.waitUntil { model.pendingNoteIDs.contains(Self.lecture) })
        #expect(model.cloudSync?.isDownloading == true)
        try cloud.deliver(Self.lecture)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Renamed on the Mac")
        model.close()
    }

    /// A note evicted by iCloud (same revision names) is not downloaded again
    /// by the loop: its summary is current.
    @Test func anEvictedNoteIsNotDownloadedForTheList() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try await Task.sleep(for: .milliseconds(100))
        try cloud.evictDataless(Self.lecture)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.pendingNoteIDs.isEmpty)
        #expect(cloud.requestedNotes.isEmpty)
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Fixture lecture")
        model.close()
    }

    /// Reopening a vault (from recents, or later) syncs again by itself.
    /// The wait is generous (it ends as soon as the note is read): it timed
    /// out at 5 s once on a loaded CI runner. Not the background
    /// validation's skipping of settled notes (P59): `close` forgets them,
    /// the first validation of a session asks about every file, and pending
    /// notes come from the sync loop's passes, which never skip.
    @Test func reopeningAVaultSyncsAgainByItself() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        let text = try String(contentsOf: key, encoding: .utf8)
        try await model.openVault(at: url, identities: [IdentityFile.parse(text)])
        model.close()
        #expect(model.cloudSync == nil)
        try cloud.evictDataless(Self.other)
        try await model.openVault(at: url, identities: [IdentityFile.parse(text)])
        #expect(model.pendingNoteIDs == [Self.other])
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil(timeout: .seconds(30)) { model.pendingNoteIDs.isEmpty && model.placeholderNoteIDs.isEmpty })
        #expect(model.notes.first { $0.id == Self.other }?.deleted == true)
        model.close()
    }

    // MARK: - Progress model

    @Test func syncStatusDescribesNotesAndFiles() {
        var s = CloudSyncStatus(notes: 128, readyNotes: 37, files: 277, localFiles: 80, unlistedNotes: 2)
        #expect(s.isDownloading)
        #expect(s.pendingNotes == 91)
        #expect(s.headline == "Downloading from iCloud: 37 of 128 notes")
        #expect(s.detail == "80 of 277 files, 2 note folders not listed yet")
        #expect(abs(s.fractionCompleted - 37.0 / 128) < 1e-9)
        s.readyNotes = 128
        #expect(!s.isDownloading)
        #expect(CloudSyncStatus().fractionCompleted == 1)
        #expect(CloudSyncStatus(notes: 1, readyNotes: 0, files: 1, localFiles: 0).headline == "Downloading from iCloud: 0 of 1 note")
        #expect(CloudSyncStatus(notes: 1, files: 1).detail == "0 of 1 file")
    }

    @Test func syncStatusFromAPass() {
        var pass = ProgressiveLoad.Pass()
        pass.all = [Self.lecture, Self.other]
        pass.ready = [Self.lecture]
        pass.pending = [Self.other]
        pass.unlisted = [Self.other]
        pass.files = 3
        pass.localFiles = 3
        let s = CloudSyncStatus(pass: pass)
        #expect(s == CloudSyncStatus(notes: 2, readyNotes: 1, files: 3, localFiles: 3, unlistedNotes: 1))
    }
}

/// How far a page scrolls, and when the screen stays on.
@MainActor
struct PageExtentTests {
    let infinite = PageSize(width: 612, height: 3473, infinite: true, breakHeight: 803.25)

    @Test func anInfinitePageScrollsAScreenBelowTheInk() {
        // Ink right at the stored bottom (an imported note): still a screen to go.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 3473, viewportHeight: 700) == 3473 + 700)
        // Ink below the stored height (just drawn, not yet grown).
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 4000, viewportHeight: 700) == 4700)
        // No ink: the page plus a screen.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: nil, viewportHeight: 700) == 4173)
        // Bad values cannot shrink it.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: .nan, viewportHeight: .infinity) == 3473)
    }

    @Test func anInfinitePageGrowsAsTheUserWrites() {
        var size = infinite
        let before = PageExtent.scrollHeight(pageSize: size, inkMaxY: 3473, viewportHeight: 700)
        size.height = 3473 + NoteEditor.growStep
        let after = PageExtent.scrollHeight(pageSize: size, inkMaxY: 3473 + 100, viewportHeight: 700)
        #expect(after > before)
        #expect(after - (3473 + 100) >= 700)
    }

    @Test func aFinitePageEndsWithRoomForItsFooter() {
        let letter = PageSize.letter
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: 700, viewportHeight: 500, footerHeight: 100)
                == letter.height + 100)
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 500) == letter.height)
        // Never less than a screen.
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 2000, footerHeight: 100) == 2000)
    }

    /// The canvas: a finite page shows its footer button below the page and
    /// scrolls far enough to reach it; an infinite one scrolls a screen past its ink.
    @Test func theCanvasHostUsesTheExtent() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        defer { window.isHidden = true }
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: .letter)
        host.footer = .addPage
        host.layoutIfNeeded()
        let z = host.canvas.zoomScale
        #expect(!host.footerButton.isHidden)
        #expect(host.footerButton.configuration?.title == "Add Page")
        #expect(host.footerButton.frame.minY >= CGFloat(PageSize.letter.height) * z)
        #expect(host.canvas.contentSize.height >= host.footerButton.frame.maxY)
        var tapped = false
        host.footerAction = { tapped = true }
        host.footerButton.sendActions(for: .primaryActionTriggered)
        #expect(tapped)
        host.footer = .nextPage
        #expect(host.footerButton.configuration?.title == "Next Page")

        host.footer = .none
        host.canvas.drawing = PKDrawing(strokes: [StrokeConversion.pkStroke(TS.stroke(y: 1_900))])
        host.apply(paper: .blank, pageSize: PageSize(width: 612, height: 2_000, infinite: true, breakHeight: nil))
        host.inkDidChange()
        #expect(host.footerButton.isHidden)
        let ink = try #require(host.inkMaxY)
        let screen = Double(host.bounds.height / host.canvas.zoomScale)
        #expect(abs(Double(host.canvas.contentSize.height / host.canvas.zoomScale) - (max(2_000, ink) + screen)) < 1)
    }

    /// Ink or a page far out of range (a corrupt or hostile file) cannot
    /// make the content size absurd: every term stops at `RenderLimits.maxExtent`.
    @Test func hugeInkOrPagesAreClamped() {
        let screen = 700.0
        let maxE = RenderLimits.maxExtent
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 1e30, viewportHeight: screen) == maxE + screen)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: -1e30, viewportHeight: screen) == 3473 + screen)
        let hugeInfinite = PageSize(width: 612, height: 1e300, infinite: true, breakHeight: nil)
        #expect(PageExtent.scrollHeight(pageSize: hugeInfinite, inkMaxY: nil, viewportHeight: 1e300) == 2 * maxE)
        let hugeFinite = PageSize(width: 612, height: 1e300, infinite: false, breakHeight: nil)
        #expect(PageExtent.scrollHeight(pageSize: hugeFinite, inkMaxY: nil, viewportHeight: screen, footerHeight: 1e300)
                == 2 * maxE)
    }

    @Test func keepScreenOnOnlyWhileANoteIsOpenAndTheAppIsActive() {
        typealias K = KeepScreenOn
        #expect(K.idleTimerDisabled(enabled: true, noteOpen: true, active: true))
        #expect(!K.idleTimerDisabled(enabled: false, noteOpen: true, active: true))      // default off
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: false, active: true))      // note or vault closed
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: true, active: false))      // background
        #expect(K.idleTimerDisabled(enabled: false, noteOpen: false, active: true, debugLaunch: true))
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: true, active: false, debugLaunch: true))
    }
}

import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Vault creation, bookmarks, recents and the sidebar's edits.
@MainActor
struct BrowserTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model on a private copy of the fixture vault, unlocked.
    static func unlockedFixtureModel() async throws -> AppModel {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return model
    }

    static func library() throws -> VaultLibrary {
        VaultLibrary(storeURL: try tempDir().appendingPathComponent("recents.json"))
    }

    // MARK: - Creating

    @Test func folderNamesAreValidated() throws {
        #expect(try VaultLibrary.folderName(for: " Notes ") == "Notes.sempere")
        for bad in ["", "  ", ".hidden", "a/b", "a:b", "x.sempere"] {
            #expect(throws: VaultLibrary.LibraryError.invalidName) { try VaultLibrary.folderName(for: bad) }
        }
    }

    @Test func createsGeneratedKeyVaultAndOpensUnlocked() async throws {
        let parent = try Self.tempDir()
        let library = try Self.library()
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let created = try await model.createVault(NewVaultRequest(name: "Fresh", keySource: .generate, passphrase: nil), library: library)
        #expect(created.url.lastPathComponent == "Fresh.sempere")
        // Generated keys are post-quantum (docs/post-quantum.md).
        #expect(created.secretKey?.hasPrefix("AGE-SECRET-KEY-PQ-1") == true)
        #expect(model.phase == .unlocked)
        #expect(model.notes.isEmpty)
        #expect(library.recents.map(\.name) == ["Fresh"])
        // No passphrase: nothing is stored in keys/.
        #expect(try Vault.open(at: created.url).identityFiles().isEmpty)
    }

    @Test func passphraseWrapsTheKeyIntoKeys() async throws {
        let parent = try Self.tempDir()
        let created = try VaultLibrary.createVault(
            NewVaultRequest(name: "Wrapped", keySource: .generate, passphrase: "hunter2"),
            folder: "Wrapped.sempere", in: parent)
        let locked = try Vault.open(at: created.url)
        let recipients = try locked.identityFiles()
        #expect(recipients.count == 1)
        let identity = try locked.readIdentityFile(recipient: recipients[0], passphrase: "hunter2", maxWorkFactor: 18)
        #expect(identity.string == created.secretKey)

        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: created.url)
        try await model.unlock(passphrase: "hunter2")
        #expect(model.phase == .unlocked)
    }

    @Test func classicRecipientIsRefused() async throws {
        let parent = try Self.tempDir()
        let classic = X25519Identity().recipient.string
        #expect(throws: VaultLibrary.LibraryError.classicRecipient) {
            try VaultLibrary.createVault(NewVaultRequest(name: "Old", keySource: .recipient(classic), passphrase: nil),
                                         folder: "Old.sempere", in: parent)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Old.sempere").path))
    }

    @Test func postQuantumRecipientOnlyVaultUnlocksWithPastedKey() async throws {
        let parent = try Self.tempDir()
        let identity = try NativeIdentity.generate(.postQuantum)
        let library = try Self.library()
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let created = try await model.createVault(
            NewVaultRequest(name: "PQ", keySource: .recipient(identity.recipient.string), passphrase: nil), library: library)
        #expect(try Vault.open(at: created.url).recipients.map(\.key) == [identity.recipient.string])
        #expect(model.phase == .locked)
        await #expect(throws: VaultError.classicIdentity) {
            try await model.unlock(identityText: IdentityFile.render(.x25519(X25519Identity()), created: Date()))
        }
        try await model.unlock(identityText: identity.string)
        #expect(model.phase == .unlocked)
    }

    @Test func rejectsBadRecipientsAndExistingVaults() async throws {
        let parent = try Self.tempDir()
        #expect(throws: VaultLibrary.LibraryError.invalidRecipient) {
            try VaultLibrary.createVault(NewVaultRequest(name: "A", keySource: .recipient("age1nope"), passphrase: nil),
                                         folder: "A.sempere", in: parent)
        }
        let ok = NewVaultRequest(name: "B", keySource: .generate, passphrase: nil)
        _ = try VaultLibrary.createVault(ok, folder: "B.sempere", in: parent)
        #expect(throws: VaultError.self) { try VaultLibrary.createVault(ok, folder: "B.sempere", in: parent) }
    }

    @Test func listsVaultsInAFolder() throws {
        let parent = try Self.tempDir()
        for name in ["b.sempere", "a.sempere"] {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("other"), withIntermediateDirectories: true)
        try Data().write(to: parent.appendingPathComponent("file.sempere"))
        #expect(VaultLibrary.vaults(in: parent).map(\.lastPathComponent) == ["a.sempere", "b.sempere"])
    }

    // MARK: - Bookmarks and recents

    @Test func bookmarkRoundTrips() throws {
        let dir = try Self.tempDir()
        let resolved = try VaultBookmark.resolve(try VaultBookmark.make(for: dir))
        #expect(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
                == dir.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func recentsPersistDedupeAndCap() async throws {
        let dir = try Self.tempDir()
        let store = dir.appendingPathComponent("recents.json")
        let library = VaultLibrary(storeURL: store)
        var urls: [URL] = []
        for i in 0..<(VaultLibrary.maxRecents + 2) {
            let url = dir.appendingPathComponent("v\(i).sempere")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
            try library.remember(url)
        }
        #expect(library.recents.count == VaultLibrary.maxRecents)
        #expect(library.recents.first?.name == "v\(VaultLibrary.maxRecents + 1)")
        try library.remember(urls[5])   // moves to the front, no duplicate
        #expect(library.recents.first?.name == "v5")
        #expect(library.recents.count == VaultLibrary.maxRecents)
        #expect(Set(library.recents.map(\.name)).count == VaultLibrary.maxRecents)

        let reloaded = VaultLibrary(storeURL: store)
        #expect(reloaded.recents == library.recents)
        let url = try reloaded.resolve(reloaded.recents[0])
        #expect(url.lastPathComponent == "v5.sempere")
    }

    /// A bookmark that does not resolve (iCloud Drive not ready after a restart, or a deleted folder)
    /// gives a clear error and the entry stays: it is the user who removes it (RecentVaultWaitTests).
    @Test func deadBookmarkIsKeptWithAClearError() throws {
        let store = try Self.tempDir().appendingPathComponent("recents.json")
        let dead = RecentVault(id: UUID(), name: "Gone", bookmark: Data([1, 2, 3]), lastOpened: Date())
        try JSONEncoder().encode([dead]).write(to: store)
        let library = VaultLibrary(storeURL: store)
        #expect(library.recents == [dead])
        #expect(throws: VaultLibrary.LibraryError.cannotResolve(name: "Gone")) { try library.resolve(dead) }
        #expect(library.recents == [dead])
        #expect(VaultLibrary(storeURL: store).recents == [dead])
        library.forget(dead)
        #expect(VaultLibrary(storeURL: store).recents.isEmpty)
    }

    @Test func newVaultReopensByItsOwnIdNotAnotherWithTheSameName() async throws {
        let library = try Self.library()
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let first = try await model.createVault(NewVaultRequest(name: "Notes", keySource: .generate, passphrase: nil), library: library)
        let second = try await model.createVault(NewVaultRequest(name: "Notes", keySource: .generate, passphrase: nil), library: library)
        #expect(first.recentID != nil && second.recentID != nil && first.recentID != second.recentID)
        #expect(model.vaultURL?.standardizedFileURL.path == second.url.standardizedFileURL.path)
        #expect(model.phase == .unlocked)
        #expect(library.recents.map(\.name) == ["Notes", "Notes"])
    }

    @Test func reopensARecentStoreVaultByItsId() async throws {
        let parent = try Self.tempDir()
        let library = try Self.library()
        let first = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let created = try await first.createVault(NewVaultRequest(name: "Again", keySource: .generate, passphrase: nil), library: library)
        first.close()
        let second = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        try await second.open(recent: try #require(library.recents.first), library: library)
        #expect(second.phase == .locked)
        #expect(second.vaultName == "Again")
        try await second.unlock(identityText: try #require(created.secretKey))
        #expect(second.phase == .unlocked)
    }

    // MARK: - Edits

    @Test func newNoteIsSelectedAndSurvivesReload() async throws {
        let model = try await Self.unlockedFixtureModel()
        let id = try await model.createNote(title: "  Chem  ", paper: Paper(kind: .grid), notebook: " Uni ")
        #expect(model.selectedNoteID == id)
        #expect(model.sidebarSelection == .allNotes)
        let live = try #require(model.notes.first { $0.id == id })
        #expect(live.title == "Chem")
        #expect(live.notebook == "Uni")
        #expect(live.pages == 1)
        let before = model.notes
        try await model.reload()
        #expect(model.notes == before)
        #expect(model.notebooks == ["Uni"])
    }

    /// A new note with no title typed is named after its date and time
    /// (TestFlight build 6), in the format Settings → New Notes picks.
    @Test func aNewNoteWithoutATitleGetsTheDateAndTime() async throws {
        let model = try await Self.unlockedFixtureModel()
        var asked: [Date] = []
        model.defaultTitle = { asked.append($0); return "Note of \($0.timeIntervalSince1970 > 0)" }
        let id = try await model.createNote(title: "   ", paper: .ruled, notebook: nil)
        #expect(model.notes.first { $0.id == id }?.title == "Note of true")
        #expect(asked.count == 1)
        // A typed title is kept as typed.
        let typed = try await model.createNote(title: " Lab ", paper: .ruled, notebook: nil)
        #expect(model.notes.first { $0.id == typed }?.title == "Lab")
        #expect(asked.count == 1)
    }

    /// The Settings choice is the one the model uses: Blank leaves the note
    /// untitled (`createNote` never puts a date over it).
    @Test func theDefaultTitleFollowsTheNewNotesSetting() async throws {
        let model = try await Self.unlockedFixtureModel()
        model.defaultTitle = { NewNoteSettings.title(.blank, now: $0) }
        let id = try await model.createNote(title: NewNoteSettings.title(.blank), paper: .ruled, notebook: nil)
        #expect(model.notes.first { $0.id == id }?.title == "")
        let d = try #require(UserDefaults(suiteName: "TitleFormat-\(UUID().uuidString)"))
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: " ", defaults: d) == NewNoteSettings.title(.dateOnly))
    }

    @Test func tagsAddRemoveAndDeduplicate() async throws {
        let model = try await Self.unlockedFixtureModel()
        try await model.addTag(" math ", to: Self.lecture)
        try await model.addTag("math", to: Self.lecture)
        try await model.addTag("   ", to: Self.lecture)
        #expect(model.notes.first { $0.id == Self.lecture }?.tags == ["fixture", "math"])
        try await model.removeTag("fixture", from: Self.lecture)
        try await model.reload()
        #expect(model.notes.first { $0.id == Self.lecture }?.tags == ["math"])
        #expect(model.tags == ["math"])
    }

    @Test func movesNotesAndRenamesNotebooks() async throws {
        let model = try await Self.unlockedFixtureModel()
        try await model.moveNote(Self.lecture, toNotebook: "Old")
        try await model.moveNote(Self.deleted, toNotebook: "Old")   // a deleted note moves with it
        model.sidebarSelection = .notebook("Old")
        try await model.renameNotebook("Old", to: "New")
        #expect(model.sidebarSelection == .notebook("New"))
        try await model.reload()
        #expect(model.notes.map(\.notebook) == ["New", "New"])
        #expect(model.notebooks == ["New"])
        #expect(model.visibleNotes.map(\.id) == [Self.lecture])

        try await model.moveNote(Self.lecture, toNotebook: nil)
        #expect(model.notes.first { $0.id == Self.lecture }?.notebook == nil)
        try await model.renameNotebook("New", to: "")
        #expect(model.notes.allSatisfy { $0.notebook == nil })
    }

    @Test func deleteAndRestore() async throws {
        let model = try await Self.unlockedFixtureModel()
        try await model.deleteNote(Self.lecture)
        #expect(model.visibleNotes.isEmpty)
        model.sidebarSelection = .deleted
        #expect(Set(model.visibleNotes.map(\.id)) == [Self.lecture, Self.deleted])
        try await model.restoreNote(Self.deleted)
        try await model.reload()
        model.sidebarSelection = .allNotes
        #expect(model.visibleNotes.map(\.id) == [Self.deleted])
        await #expect(throws: AppModel.ModelError.noteNotFound) { try await model.deleteNote(UUID()) }
    }

    /// A note none of whose revisions can be read (another key, damage) is
    /// still listed, and can still be renamed, moved, deleted and restored:
    /// those ops do not depend on the note's state.
    @Test func unreadableNoteCanStillBeEditedAndDeleted() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let id = UUID()
        let dir = url.appendingPathComponent("notes/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not age".utf8).write(to: dir.appendingPathComponent("17000000000000000-deadbeef-1.delta.age"))
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.notes.first { $0.id == id }?.problem != nil)

        try await model.renameNote(id, to: "Broken")
        try await model.moveNote(id, toNotebook: "Lost")
        try await model.deleteNote(id)
        var note = try #require(model.notes.first { $0.id == id })
        #expect(note.title == "Broken")
        #expect(note.notebook == "Lost")
        #expect(note.deleted)
        try await model.restoreNote(id)
        note = try #require(model.notes.first { $0.id == id })
        #expect(!note.deleted)
        let vault = try #require(model.vault)
        #expect(try vault.revisionNames(of: id).count == 5)   // the unreadable one, then one delta per edit
    }

    @Test func editsLeaveExistingRevisionsUntouchedAndAddDeltas() async throws {
        let model = try await Self.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let dir = vault.url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())")
        func files() throws -> [String: Data] {
            var out: [String: Data] = [:]
            // Revision files (the note also has an `att/` folder of blobs).
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".age") {
                out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
            }
            return out
        }
        let before = try files()
        try await model.addTag("x", to: Self.lecture)
        let after = try files()
        #expect(after.count == before.count + 1)
        for (name, bytes) in before { #expect(after[name] == bytes, "\(name) changed") }   // write-once
        let added = try #require(Set(after.keys).subtracting(before.keys).first)
        #expect(added.hasSuffix(".delta.age"))
        #expect(vault.verify().isHealthy)
    }

    @Test func concurrentEditsAreSerialisedAndAllLand() async throws {
        let model = try await Self.unlockedFixtureModel()
        async let a: Void = model.addTag("one", to: Self.lecture)
        async let b: Void = model.moveNote(Self.lecture, toNotebook: "Two")
        async let c: Void = model.addTag("three", to: Self.deleted)
        _ = try await (a, b, c)
        #expect(!model.isEditing)
        try await model.reload()
        let lecture = try #require(model.notes.first { $0.id == Self.lecture })
        #expect(lecture.tags.contains("one"))
        #expect(lecture.notebook == "Two")
        #expect(model.notes.first { $0.id == Self.deleted }?.tags.contains("three") == true)
        let vault = try #require(model.vault)
        // One delta each, with this device's sequence numbers 1 and 2.
        let device = try DeviceState.loadOrCreate(at: model.deviceStateURL).device
        let mine = try vault.revisionNames(of: Self.lecture).filter { $0.device == device }
        #expect(mine.map(\.seq).sorted() == [1, 2])
        #expect(vault.verify().isHealthy)
    }

    @Test func editQueuedBeforeCloseIsNotWrittenAfterIt() async throws {
        let model = try await Self.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let before = try vault.revisionNames(of: Self.lecture)
        await model.editGate.acquire()            // an edit in flight
        let queued = Task { try await model.addTag("late", to: Self.lecture) }
        while model.editGate.waiting == 0 { await Task.yield() }
        model.close()
        model.editGate.release()
        await #expect(throws: AppModel.ModelError.noVaultOpen) { try await queued.value }
        #expect(try vault.revisionNames(of: Self.lecture) == before)
    }

    @Test func lockedModelCannotEdit() async throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        await #expect(throws: VaultError.self) { try await model.createNote(title: "x", paper: .ruled, notebook: nil) }
    }

    // MARK: - Search and sort

    @Test func searchesTitlesAndSorts() async throws {
        let model = try await Self.unlockedFixtureModel()
        let a = try await model.createNote(title: "alpha", paper: .ruled, notebook: nil)
        let b = try await model.createNote(title: "Beta", paper: .ruled, notebook: nil)
        model.sortOrder = .title
        #expect(model.visibleNotes.map(\.id) == [a, b, Self.lecture])
        model.sortOrder = .modified
        #expect(Set(model.visibleNotes.map(\.id)) == [a, b, Self.lecture])
        model.searchText = "ET"
        #expect(model.visibleNotes.map(\.id) == [b])
        model.searchText = "zzz"
        #expect(model.visibleNotes.isEmpty)
    }

    @Test func sortsByModifiedNewestFirstWithUnknownLast() {
        func note(_ n: Int, _ modified: Date?) -> NoteSummary {
            NoteSummary(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(n)")!, title: "t\(n)", tags: [],
                        notebook: nil, deleted: false, pages: 1, strokes: 0, modified: modified, problem: nil)
        }
        let list = [note(1, Date(timeIntervalSince1970: 10)), note(2, nil), note(3, Date(timeIntervalSince1970: 20))]
        #expect(AppModel.sorted(list, by: .modified).map(\.title) == ["t3", "t1", "t2"])
        #expect(AppModel.sorted(list, by: .title).map(\.title) == ["t1", "t2", "t3"])
    }

    /// Date Created (newest first) and "Favorites at Top" under every order (`NoteOrder`, shared with the CLI).
    @Test func sortsByCreationAndPutsFavoritesFirstUnderAnyOrder() async throws {
        let model = try await Self.unlockedFixtureModel()
        let a = try await model.createNote(title: "alpha", paper: .ruled, notebook: nil)
        try await Task.sleep(for: .milliseconds(20))
        let b = try await model.createNote(title: "Beta", paper: .ruled, notebook: nil)
        // `a` changes last: newest by modification, older by creation.
        try await model.renameNote(a, to: "alpha 2")
        model.sortOrder = .created
        #expect(model.visibleNotes.map(\.id).prefix(2) == [b, a])
        model.sortOrder = .modified
        #expect(model.visibleNotes.map(\.id).prefix(2) == [a, b])

        try await model.setFavorite(true, for: Self.lecture)
        model.favoritesFirst = true
        for order in NoteSort.allCases {
            model.sortOrder = order
            #expect(model.visibleNotes.first?.id == Self.lecture, "\(order)")
        }
        model.sortOrder = .created
        #expect(model.visibleNotes.map(\.id) == [Self.lecture, b, a])
        model.favoritesFirst = false
        #expect(model.visibleNotes.map(\.id).prefix(2) == [b, a])
    }
}

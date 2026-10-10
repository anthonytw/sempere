import Foundation
import Sempere
import PencilKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import SempereApp

/// A one-way flag set from another task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A vault folder whose files can be evicted and delivered like iCloud's
/// placeholders (`.<name>.icloud` stand-ins), with the iCloud calls faked.
final class FakeCloud: @unchecked Sendable {
    let vault: URL
    private let lock = NSLock()
    private var held: [URL: Data] = [:]
    private var log: [String] = []
    private var folderLog: [String] = []
    private var dataless: Set<String> = []
    /// Deliver a file the moment it is requested (like a fast connection).
    var autoDeliver = false

    init(vault: URL) { self.vault = vault }

    private func noteURL(_ id: UUID) -> URL {
        vault.appendingPathComponent("notes/\(id.uuidString.lowercased())")
    }

    /// Turns every revision file of the note into a placeholder.
    func evict(_ id: UUID) throws {
        let dir = noteURL(id)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".age") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            lock.withLock { held[url] = try? Data(contentsOf: url) }
            try FileManager.default.removeItem(at: url)
            try Data().write(to: CloudPlaceholder.placeholderURL(for: url))
        }
    }

    /// iPadOS 26 style: every revision file of the note stays under its real
    /// name but is dataless (empty here, status "not downloaded").
    func evictDataless(_ id: UUID) throws {
        let dir = noteURL(id)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".age") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            lock.withLock {
                held[url] = try? Data(contentsOf: url)
                dataless.insert(url.standardizedFileURL.path)
            }
            try Data().write(to: url)
        }
    }

    /// The note's folder is there but iCloud has not listed what is in it.
    func unlist(_ id: UUID) throws {
        let dir = noteURL(id)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".age") && !name.hasPrefix(".") { lock.withLock { held[url] = try? Data(contentsOf: url) } }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Folders asked for (`startDownloadingUbiquitousItem` on a note folder).
    var requestedFolders: [String] {
        lock.withLock { folderLog }
    }

    /// The real-name state of a file: dataless ones are missing.
    func state(_ item: CloudScan.Item) -> CloudItemState {
        if lock.withLock({ dataless.contains(item.url.standardizedFileURL.path) }) { return .missing }
        return CloudVault.state(of: item)
    }

    /// The note's files arrive.
    func deliver(_ id: UUID) throws {
        let dir = noteURL(id).standardizedFileURL.path
        let files = lock.withLock { held.filter { $0.key.deletingLastPathComponent().standardizedFileURL.path == dir } }
        for (url, data) in files {
            try data.write(to: url)
            try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: url))
            lock.withLock {
                held[url] = nil
                dataless.remove(url.standardizedFileURL.path)
            }
        }
    }

    /// Note directory names in the order their files were first requested.
    var requestedNotes: [String] {
        lock.withLock { log.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    }

    var hooks: CloudVault.Hooks {
        CloudVault.Hooks(isUbiquitous: { _ in true },
                         state: { [self] in state($0) },
                         request: { [self] item in
            if item.url.deletingLastPathComponent().lastPathComponent == "notes" {
                let note = item.url.lastPathComponent
                lock.withLock { folderLog.append(note) }
                if autoDeliver, let id = UUID(uuidString: note) { try? deliver(id) }
                return
            }
            let note = item.url.deletingLastPathComponent().lastPathComponent
            if item.url.path.contains("/notes/") { lock.withLock { log.append(note) } }
            if autoDeliver, let id = UUID(uuidString: note) { try? deliver(id) }
        })
    }
}

/// The note folders `hooks.state` was asked about.
final class AskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var value: [String] { lock.withLock { names } }
    func add(_ name: String) { lock.withLock { names.append(name) } }
    func clear() { lock.withLock { names = [] } }
}

@MainActor
struct ProgressiveLoadTests {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @Test func passSortsNotesIntoReadyAndPendingAndRequestsOnlyPendingFiles() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.other)
        let pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.all == [Self.lecture, Self.other])
        #expect(pass.ready == [Self.lecture])
        #expect(pass.pending == [Self.other])
        #expect(pass.failures.isEmpty)
        #expect(cloud.requestedNotes == [Self.other.uuidString.lowercased()])
    }

    @Test func settledNotesAreNotAskedAboutWhileTheirListingIsTheSame() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let asked = AskLog()
        var hooks = cloud.hooks
        hooks.state = { item in
            asked.add(item.url.deletingLastPathComponent().lastPathComponent)
            return cloud.state(item)
        }
        let first = try ProgressiveLoad.pass(vault: url, requestMissing: false, hooks: hooks)
        #expect(Set(first.settled.keys) == [Self.lecture, Self.other])
        let total = asked.value.count
        #expect(total == first.files)

        asked.clear()
        let second = try ProgressiveLoad.pass(vault: url, requestMissing: false, settled: first.settled, hooks: hooks)
        #expect(asked.value.isEmpty)
        #expect(second.ready == first.ready && second.files == first.files && second.localFiles == first.localFiles)
        #expect(second.settled == first.settled)

        // A new file in one note: only that note is asked about again.
        let dir = url.appendingPathComponent("notes/\(Self.other.uuidString.lowercased())")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix(".age") })
        try Data(contentsOf: dir.appendingPathComponent(name))
            .write(to: dir.appendingPathComponent("99999999999999999-cccccccc-1.delta.age"))
        asked.clear()
        let third = try ProgressiveLoad.pass(vault: url, requestMissing: false, settled: second.settled, hooks: hooks)
        #expect(Set(asked.value) == [Self.other.uuidString.lowercased()])
        #expect(third.files == first.files + 1)

        // Evicted to placeholders: the listing changes, so it is asked about and pending.
        try cloud.evict(Self.lecture)
        asked.clear()
        let fourth = try ProgressiveLoad.pass(vault: url, requestMissing: false, settled: third.settled, hooks: hooks)
        #expect(asked.value.contains(Self.lecture.uuidString.lowercased()))
        #expect(fourth.pending == [Self.lecture])
        #expect(fourth.settled[Self.lecture] == nil)

        // A file that is not current is never settled.
        var stale = cloud.hooks
        stale.state = { _ in .stale }
        #expect(try ProgressiveLoad.pass(vault: url, requestMissing: false, hooks: stale).settled.isEmpty)
    }

    @Test func theOpenedNoteIsRequestedFirstAndRequestsAreWindowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ids = (0..<5).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            let dir = root.appendingPathComponent("notes/\(id.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(".1-a-1.delta.age.icloud"))
        }
        let cloud = FakeCloud(vault: root)
        let pass = try ProgressiveLoad.pass(vault: root, priority: ids[3], window: 2, hooks: cloud.hooks)
        #expect(pass.pending.count == 5)
        #expect(pass.ready.isEmpty)
        #expect(cloud.requestedNotes == [ids[3], ids[0]].map { $0.uuidString.lowercased() })
        // Without a priority: listing order.
        let plain = FakeCloud(vault: root)
        _ = try ProgressiveLoad.pass(vault: root, window: 3, hooks: plain.hooks)
        #expect(plain.requestedNotes == ids.prefix(3).map { $0.uuidString.lowercased() })
    }

    @Test func downloadErrorsAreReportedPerNote() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.lecture)
        var hooks = cloud.hooks
        hooks.state = { item in item.url.path.contains("1111") ? .failed("quota") : CloudVault.state(of: item) }
        let pass = try ProgressiveLoad.pass(vault: url, hooks: hooks)
        #expect(pass.failures == [Self.lecture: "quota"])
        #expect(pass.pending == [Self.lecture])
        #expect(pass.ready == [Self.other])
    }

    @Test func notesWithADownloadErrorDoNotHoldTheWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ids = (0..<3).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            let dir = root.appendingPathComponent("notes/\(id.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(".1-a-1.delta.age.icloud"))
        }
        let cloud = FakeCloud(vault: root)
        var hooks = cloud.hooks
        let failing = ids[0].uuidString.lowercased()
        hooks.state = { item in item.url.path.contains(failing) ? .failed("quota") : CloudVault.state(of: item) }
        let pass = try ProgressiveLoad.pass(vault: root, window: 1, hooks: hooks)
        #expect(pass.failures.keys.sorted { $0.uuidString < $1.uuidString } == [ids[0]])
        #expect(cloud.requestedNotes == [ids[1].uuidString.lowercased()])
    }

    @Test func essentialsAreTheManifestAndKeysOnly() throws {
        let root = try CloudTests.evictedVault()
        let essentials = try CloudScan.essentialItems(inVault: root).map { $0.url.lastPathComponent }
        #expect(essentials == ["vault.json", "age1abc.key.age"])
        let groups = try CloudScan.noteGroups(inVault: root)
        #expect(groups.map(\.directory) == ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        #expect(groups.map(\.items.count) == [2, 2])
    }

    // MARK: - The model

    @MainActor
    static func cloudModel(_ cloud: FakeCloud, key: URL) async throws -> AppModel {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        try await model.openVault(at: cloud.vault)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return model
    }

    @MainActor
    @Test func notesAppearAsTheirFilesArriveAndTheListFillsWithoutARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.other)
        let model = try await Self.cloudModel(cloud, key: key)
        #expect(model.isCloudVault)
        // The unlocked vault lists the local note at once; the other is a placeholder.
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        let local = try #require(model.notes.first { $0.id == Self.lecture })
        #expect(!local.title.isEmpty)
        #expect(model.placeholderNoteIDs == [Self.other])
        #expect(model.pendingNoteIDs == [Self.other])
        #expect(Set(model.visibleNotes.map(\.id)) == [Self.lecture, Self.other])   // the placeholder row is listed

        try cloud.deliver(Self.other)
        // No pull-to-refresh: the sync loop picks it up.
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        let arrived = try #require(model.notes.first { $0.id == Self.other })
        #expect(arrived.deleted)
        #expect(model.placeholderNoteIDs.isEmpty)
        // Once nothing is pending the progress bar goes away; the loop keeps
        // watching at the idle pace while the vault is open.
        #expect(model.cloudSync?.isDownloading == false)
        #expect(model.cloudSync?.readyNotes == 2)
        let sync = try #require(model.cloudSyncTask)
        model.close()
        let ended = Flag()
        Task { await sync.value; ended.set() }
        #expect(await TS.waitUntil { ended.isSet })
    }

    @MainActor
    @Test func openingAPendingNoteDownloadsItFirstThenOpensIt() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.lecture)
        try cloud.evict(Self.other)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudWindow = 1
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.placeholderNoteIDs == [Self.lecture, Self.other])
        #expect(cloud.requestedNotes == [Self.lecture.uuidString.lowercased()])   // window of one: the first only

        // The user opens the second note: it is requested ahead of the rest.
        model.selectedNoteID = Self.other
        let opening = Task { try await model.openEditor(for: Self.other) }
        #expect(await TS.waitUntil { cloud.requestedNotes.contains(Self.other.uuidString.lowercased()) })
        #expect(model.editor == nil)
        try cloud.deliver(Self.other)
        try await opening.value
        #expect(model.editor?.noteID == Self.other)
        #expect(!model.pendingNoteIDs.contains(Self.other))
        #expect(model.notes.first { $0.id == Self.other }?.deleted == true)
        // The rest still arrives later.
        try cloud.deliver(Self.lecture)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        #expect(model.placeholderNoteIDs.isEmpty)
        model.close()
        #expect(model.pendingNoteIDs.isEmpty)
    }

    /// `pendingNoteIDs` is only as fresh as the last pass: a note whose files
    /// became placeholders since (another device wrote a revision, iCloud
    /// evicted it) must still be downloaded before the canvas opens on it.
    @MainActor
    @Test func openingANoteWaitsForFilesThatWentMissingSinceTheLastPass() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = try await Self.cloudModel(cloud, key: key)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        model.stopCloudSync()                       // no pass will notice the change
        try cloud.evict(Self.lecture)
        #expect(!model.pendingNoteIDs.contains(Self.lecture))

        model.selectedNoteID = Self.lecture
        let opening = Task { try await model.openEditor(for: Self.lecture) }
        #expect(await TS.waitUntil { cloud.requestedNotes.contains(Self.lecture.uuidString.lowercased()) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.editor == nil)                // not opened on a partial log
        try cloud.deliver(Self.lecture)
        try await opening.value
        let editor = try #require(model.editor)
        #expect(editor.noteID == Self.lecture)
        #expect(editor.pages.count == 2)
        model.close()
    }

    /// A browser edit of a note still downloading is computed from the real
    /// summary, not the placeholder's empty one: adding a tag keeps the tags
    /// the note already has.
    @MainActor
    @Test func editingAPlaceholderDownloadsItFirstAndKeepsItsTags() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.lecture)
        let model = try await Self.cloudModel(cloud, key: key)
        #expect(model.placeholderNoteIDs.contains(Self.lecture))
        #expect(model.notes.first { $0.id == Self.lecture }?.tags == [])

        let tagging = Task { try await model.addTag("new", to: Self.lecture) }
        try await Task.sleep(for: .milliseconds(100))
        let dir = url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())")
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") && $0 != "att" }   // `att/` (blobs) is not evicted with the revisions
        #expect(before.isEmpty)                     // nothing written while the note is missing
        try cloud.deliver(Self.lecture)
        try await tagging.value
        #expect(model.notes.first { $0.id == Self.lecture }?.tags == ["fixture", "new"])
        #expect(!model.placeholderNoteIDs.contains(Self.lecture))
        model.close()
    }

    @MainActor
    @Test func renamingANotebookWaitsForPendingNotes() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.other)
        let model = try await Self.cloudModel(cloud, key: key)
        try await model.moveNote(Self.lecture, toNotebook: "School")
        await #expect(throws: AppModel.ModelError.notesStillDownloading) {
            try await model.renameNotebook("School", to: "Work")
        }
        model.close()
    }

    @MainActor
    @Test func aStalledDownloadShowsAProblemAndKeepsTrying() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.other)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudStallTimeout = .milliseconds(100)
        model.cloudIdleInterval = .milliseconds(20)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { model.cloudSync?.problem != nil })
        let problem = model.cloudSync?.problem ?? ""
        #expect(problem.contains("1 note "), "\(problem)")
        #expect(model.errorMessage == nil)                   // shown in the list's bar, not an alert
        #expect(model.placeholderNoteIDs == [Self.other])   // still listed
        #expect(model.cloudSync?.isDownloading == true)
        // The loop keeps trying: when the files come, the problem clears by itself.
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty && model.cloudSync?.problem == nil })
        #expect(model.cloudSync?.isDownloading == false)
        model.close()
    }

    @MainActor
    @Test func aNoteDeletedRemotelyLeavesTheList() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.other)
        let model = try await Self.cloudModel(cloud, key: key)
        try FileManager.default.removeItem(at: url.appendingPathComponent("notes/\(Self.other.uuidString.lowercased())"))
        #expect(await TS.waitUntil { model.notes.count == 1 })
        #expect(model.pendingNoteIDs.isEmpty)
    }
}

/// Opening a vault from whatever the picker returned.
struct VaultLocatorTests {
    static func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardizedFileURL
    }

    static func makeVault(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("notes/n"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("vault.json"))
        try Data("x".utf8).write(to: url.appendingPathComponent("notes/n/1-a-1.delta.age"))
    }

    @Test func aVaultFolderResolvesToItself() throws {
        let vault = try Self.temp().appendingPathComponent("A.sempere")
        try Self.makeVault(vault)
        #expect(try VaultLocator.resolve(vault) == vault)
        let plain = try Self.temp().appendingPathComponent("Old")   // an older vault without the extension
        try Self.makeVault(plain)
        #expect(try VaultLocator.resolve(plain) == plain)
    }

    /// The picker's access covers the picked item and what is below it, not
    /// its parents: a pick inside a vault cannot open the vault, so it names it.
    @Test func aPickInsideAVaultIsAnErrorNamingTheVault() throws {
        let vault = try Self.temp().appendingPathComponent("A.sempere")
        try Self.makeVault(vault)
        for inner in ["vault.json", "notes", "notes/n", "notes/n/1-a-1.delta.age"] {
            #expect(throws: VaultLocator.LocatorError.insideVault("A.sempere")) {
                try VaultLocator.resolve(vault.appendingPathComponent(inner))
            }
        }
    }

    @Test func aFolderHoldingOneVaultResolvesToIt() throws {
        let parent = try Self.temp()
        let vault = parent.appendingPathComponent("A.sempere")
        try Self.makeVault(vault)
        try Data("x".utf8).write(to: parent.appendingPathComponent("readme.txt"))
        #expect(try VaultLocator.resolve(parent).path == vault.path)
    }

    @Test func severalVaultsAreAnErrorAndNoVaultIsLeftAlone() throws {
        let parent = try Self.temp()
        try Self.makeVault(parent.appendingPathComponent("A.sempere"))
        try Self.makeVault(parent.appendingPathComponent("B.sempere"))
        #expect(throws: VaultLocator.LocatorError.severalVaults(["A.sempere", "B.sempere"])) {
            try VaultLocator.resolve(parent)
        }
        let empty = try Self.temp()
        #expect(try VaultLocator.resolve(empty) == empty)
        let missing = empty.appendingPathComponent("nope")
        #expect(try VaultLocator.resolve(missing) == missing)
    }

    @Test func newVaultsGetTheExtensionAndThePickerAcceptsPackagesAndFolders() throws {
        #expect(try VaultLibrary.folderName(for: " Notes ") == "Notes.sempere")
        #expect(UTType.vaultPickerTypes.contains(.sempere))
        #expect(UTType.vaultPickerTypes.contains(.folder))
        #expect(UTType.sempere.conforms(to: .package))
        #expect(UTType.sempere.conforms(to: .directory))
    }
}

@MainActor
struct LayoutAndPaletteTests {
    @Test func columnLayoutRoundTripsAndToggles() {
        for v in [NavigationSplitViewVisibility.all, .doubleColumn, .detailOnly] {
            #expect(ColumnLayout.visibility(from: ColumnLayout.stored(v)) == v)
        }
        #expect(ColumnLayout.visibility(from: "garbage") == .all)
        #expect(ColumnLayout.toggled("all") == "detailOnly")
        #expect(ColumnLayout.toggled("doubleColumn") == "detailOnly")
        #expect(ColumnLayout.toggled("detailOnly") == "doubleColumn")
    }

    @Test func compactPaletteKeepsPenMarkerEraserLasso() {
        let full = EraserPreference.makeToolPicker().toolItems
        let compact = ToolPalette.compactItems(from: full)
        #expect(compact.count < full.count)
        #expect(compact.contains { $0 is PKToolPickerEraserItem })
        #expect(compact.contains { $0 is PKToolPickerLassoItem })
        let inks = compact.compactMap { ($0 as? PKToolPickerInkingItem)?.inkingTool.inkType }
        #expect(Set(inks) == [.pen, .marker])
        #expect(ToolPalette.compactItems(from: []).isEmpty)
        let picker = ToolPalette.makePicker(compact: true)
        #expect(picker.toolItems.count == compact.count)
        #expect(!picker.showsDrawingPolicyControls)
        #expect(ToolPalette.makePicker(compact: false).toolItems.count == full.count)
    }

    @Test func paletteDefaultsToShownAndFull() {
        let d = UserDefaults(suiteName: "sempere-palette-tests")!
        d.removePersistentDomain(forName: "sempere-palette-tests")
        #expect(ToolPalette.isVisible(in: d))
        #expect(!ToolPalette.isCompact(in: d))
        d.set(false, forKey: ToolPalette.visibleKey)
        d.set(true, forKey: ToolPalette.compactKey)
        #expect(!ToolPalette.isVisible(in: d))
        #expect(ToolPalette.isCompact(in: d))
    }

    @Test func hostSwapsPickersWithoutLosingTheCanvasObserver() {
        let host = PageCanvasHost()
        let full = host.toolPicker.toolItems.count
        host.paletteCompact = true
        #expect(host.toolPicker.toolItems.count < full)
        host.paletteCompact = false
        #expect(host.toolPicker.toolItems.count == full)
        host.paletteVisible = false   // no window: nothing to show or hide, must not crash
    }
}

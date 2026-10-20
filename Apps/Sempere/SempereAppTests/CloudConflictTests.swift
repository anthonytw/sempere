import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The TestFlight 1.0.0 report (2026-10): a vault created on the Mac while a
/// large Notability import ran there; the iPad opened it, stayed on
/// "Downloading" through refresh and relaunch, and the one note written on the
/// iPad was gone once the Mac's version of the vault won iCloud's "choose a
/// version" prompt. These tests fake iCloud (`FakeCloud`): conflict versions,
/// folders an import left without a revision, and a second device listing
/// notes from published summaries before they arrive.
@MainActor
struct CloudConflictTests {
    static let lecture = ProgressiveLoadTests.lecture
    static let other = ProgressiveLoadTests.other
    static let ipadNote = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    static func identity(_ key: URL) throws -> NativeIdentity {
        try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
    }

    /// A copy of the vault next to it, as iCloud keeps another device's version.
    static func version(of url: URL, _ name: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// A note folder an import on another device created and has not written a revision into
    /// yet (blobs go first): only `att/`.
    static func importInProgress(_ url: URL) throws -> UUID {
        let id = UUID()
        let att = url.appendingPathComponent("notes/\(id.uuidString.lowercased())/att")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        try Data("sealed blob".utf8).write(to: att.appendingPathComponent(String(repeating: "a", count: 64) + ".pdf.age"))
        return id
    }

    // MARK: - The owner's report, end to end

    /// The iPad's note is in the version iCloud did not keep. The app merges that version in
    /// (a union of write-once files), resolves the conflict and lists the note; the import's
    /// note folders without a revision do not keep the list "downloading".
    @Test func theNoteOnlyTheLosingVersionHeldIsListedAndNothingStaysDownloading() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        // The iPad's version of the vault: one note more, written there.
        let ipad = try Self.version(of: url, "sample.sempere")
        try TS.writeAsAnotherDevice([.setMeta(.title("Written on the iPad"))], to: Self.ipadNote, vault: ipad, key: key)
        // The Mac's version (kept): its import is still going (a note folder holding only att/).
        let importing = try Self.importInProgress(url)
        let cloud = FakeCloud(vault: url)
        cloud.addConflict(of: url, version: ipad)
        let model = CloudSyncTests.model(cloud)
        try await model.openVault(at: url)
        _ = try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))

        #expect(await TS.waitUntil { model.notes.contains { $0.id == Self.ipadNote && $0.title == "Written on the iPad" } })
        #expect(cloud.resolved.contains("."))
        #expect(cloud.unresolved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("notes/\(Self.ipadNote.uuidString.lowercased())").path))
        // The import's folder is not a note yet and is not "downloading".
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty && model.cloudSync?.isDownloading == false })
        #expect(!model.notes.contains { $0.id == importing })
        #expect(model.emptyNoteFolders.contains(importing))
        let vault = try Vault.open(at: url, identities: [try Self.identity(key)])
        // The merged revisions are the iPad's, intact (the import's stand-in blob aside, nothing else is unhealthy).
        #expect(try vault.summary(of: Self.ipadNote).title == "Written on the iPad")
        let bad = vault.verify().files.filter {
            ![.ok, .unknownFile, .unreferenced, .notChecked].contains($0.status) && !$0.path.contains(importing.uuidString.lowercased())
        }
        #expect(bad.isEmpty, "\(bad.map { "\($0.path) \($0.status) \($0.detail ?? "")" })")
        model.close()
    }

    // MARK: - Mutable files

    @Test func settingsMergePerKeyAndALabelOnlyManifestConflictResolves() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try Self.identity(key)
        let vault = try Vault.open(at: url, identities: [identity])
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try vault.updateSharedSettings { try $0.set(SettingSlotKey("editor.a"), to: .number(1), type: nil, now: t0) }
        let theirs = try Self.version(of: url, "sample.sempere")
        var other = try Vault.open(at: theirs, identities: [identity])
        try other.updateSharedSettings { try $0.set(SettingSlotKey("editor.b"), to: .number(2), type: nil, now: t0) }
        try other.setLabel("Renamed on the iPad")
        let cloud = FakeCloud(vault: url)
        cloud.addConflict(of: url.appendingPathComponent("settings.age"), version: theirs.appendingPathComponent("settings.age"))
        cloud.addConflict(of: url.appendingPathComponent("vault.json"), version: theirs.appendingPathComponent("vault.json"))

        let locked = try CloudConflicts.resolve(vault: try Vault.open(at: url), hooks: cloud.hooks)
        #expect(locked.waitingForKey == ["settings.age"], "merging settings needs the key")
        #expect(locked.resolved == ["vault.json"])
        #expect(cloud.unresolved == ["settings.age"])

        let out = try CloudConflicts.resolve(vault: vault, hooks: cloud.hooks)
        #expect(out.resolved == ["settings.age"])
        #expect(out.settingsChanged)
        #expect(cloud.unresolved.isEmpty)
        let merged = try #require(try vault.readSharedSettings())
        #expect(merged.value(SettingSlotKey("editor.a")) == .number(1))
        #expect(merged.value(SettingSlotKey("editor.b")) == .number(2))
    }

    @Test func aKeyChangeOnOneSideIsNeverGuessedAndShowsInTheBar() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        // Another vault's manifest stands in for "the keys differ".
        let stranger = TestTemp.root.appendingPathComponent(UUID().uuidString + ".sempere")
        try TS.makeVault(at: stranger, device: try TS.fixtureDevice(key))
        let cloud = FakeCloud(vault: url)
        cloud.addConflict(of: url.appendingPathComponent("vault.json"), version: stranger.appendingPathComponent("vault.json"))
        let model = CloudSyncTests.model(cloud)
        try await model.openVault(at: url)
        _ = try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil { model.lastConflictOutcome?.unresolved["vault.json"] != nil })
        #expect(cloud.unresolved == ["vault.json"])
        #expect(await TS.waitUntil { model.cloudSync?.problem?.contains("vault.json") == true })
        model.close()
    }

    // MARK: - "Downloading" never waits forever

    /// A folder that lists nothing at all is "not listed yet" for a while, then set aside: the
    /// bar stops saying "Downloading", and the note is read as soon as its files are listed.
    @Test func aFolderThatNeverListsAnythingIsSetAsideThenReadWhenItArrives() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.other)
        let model = CloudSyncTests.model(cloud)
        model.cloudUnlistedTimeout = .milliseconds(300)
        try await model.openVault(at: url)
        _ = try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.pendingNoteIDs.contains(Self.other))
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty && model.cloudSync?.isDownloading == false })
        #expect(model.emptyNoteFolders.contains(Self.other))
        #expect(!model.notes.contains { $0.id == Self.other })
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.notes.contains { $0.id == Self.other && !$0.title.isEmpty } })
        #expect(!model.emptyNoteFolders.contains(Self.other))
        model.close()
    }

    // MARK: - Index-first

    /// A device that has none of the notes yet lists them from the other devices' published
    /// summaries (titles, not "Downloading…" rows), and each device publishes its own file once
    /// its listing is complete.
    @Test func aSecondDeviceListsTitlesBeforeTheNotesArrive() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try Self.identity(key)
        // Device A (the Mac) publishes; its listing is complete.
        let cloudA = FakeCloud(vault: url)
        let a = CloudSyncTests.model(cloudA)
        a.publishSummariesInterval = .zero
        try await a.openVault(at: url)
        _ = try await a.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let device = try a.deviceClockForWriting().device
        let published = try Vault.open(at: url, identities: [identity]).devicePublishedSummariesURL(device)
        #expect(await TS.waitUntil { FileManager.default.fileExists(atPath: published.path) })
        let titles = Dictionary(uniqueKeysWithValues: a.notes.map { ($0.id, $0.title) })
        #expect(titles.values.allSatisfy { !$0.isEmpty })
        a.close()

        // Device B: nothing listed yet but the folders (and A's summaries file).
        let cloudB = FakeCloud(vault: url)
        try cloudB.unlist(Self.lecture)
        try cloudB.unlist(Self.other)
        let b = CloudSyncTests.model(cloudB)
        b.cloudUnlistedTimeout = .seconds(60)
        try await b.openVault(at: url)
        _ = try await b.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(await TS.waitUntil {
            titles.allSatisfy { id, title in b.notes.contains { $0.id == id && $0.title == title } }
        })
        #expect(b.pendingNoteIDs == [Self.lecture, Self.other], "listed, still arriving")
        // Once they arrive they are read as usual.
        try cloudB.deliver(Self.lecture)
        try cloudB.deliver(Self.other)
        #expect(await TS.waitUntil { b.pendingNoteIDs.isEmpty })
        #expect(b.notes.count == titles.count)
        b.close()
    }

    @Test func theBestPublishedEntryMatchesTheListingElseHasTheMostRevisions() {
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(_ revs: [String], _ title: String) -> PublishedSummaries.Entry {
            PublishedSummaries.Entry(revisions: revs, title: title, tags: [], notebook: nil, favorite: false, deleted: false,
                                     created: t, modified: t, pages: 1, pageTexts: [])
        }
        let old = entry(["1-aaaaaaaa-1.delta.age"], "old")
        let new = entry(["1-aaaaaaaa-1.delta.age", "2-bbbbbbbb-1.delta.age"], "new")
        #expect(PublishedSummaries.best(of: [[id: old], [id: new]])[id]?.title == "new")
        #expect(PublishedSummaries.best(of: [[id: new], [id: old]])[id]?.title == "new")
        #expect(PublishedSummaries.best(of: [[id: new], [id: old]], listing: [id: ["1-aaaaaaaa-1.delta.age"]])[id]?.title == "old")
    }
}

import Age
import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Vault creation (`VaultCreation`, the app's New Vault and the CLI's `vault init` / `store create`), the recents,
/// and what a picked folder resolves to. The app's side (opening the new vault, the sheet, bookmarks): `BrowserTests`,
/// `NewVaultKeyTests`, `VaultStoreAppTests` (SempereAppTests).
@MainActor
struct VaultLibraryTests {
    static func tempDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func library() throws -> VaultLibrary {
        VaultLibrary(storeURL: try tempDir().appendingPathComponent("recents.json"))
    }

    static func request(_ name: String, passphrase: String? = nil, key: NewVaultRequest.KeySource = .generate) -> NewVaultRequest {
        var request = NewVaultRequest(name: name, keySource: key, passphrase: passphrase)
        request.workFactor = 10
        return request
    }

    // MARK: - Creating

    /// The store vault the app makes: in the store, this device its home, a generated post-quantum recovery key
    /// handed back once, and remembered.
    @Test func createsAGeneratedKeyVaultInTheStore() async throws {
        let library = try Self.library()
        let created = try await library.create(Self.request("Fresh"))
        #expect(created.url.lastPathComponent == "Fresh.sempere")
        #expect(library.vaultStore.entry(id: created.vaultID)?.url.standardizedFileURL == created.url.standardizedFileURL)
        #expect(created.secretKey?.hasPrefix("AGE-SECRET-KEY-PQ-1") == true)
        #expect(created.generatedRecovery?.string == created.secretKey)
        #expect(library.recents.map(\.name) == ["Fresh"])
        #expect(created.recentID == library.recents.first?.id)
        let vault = try Vault.open(at: created.url)
        #expect(vault.devices.map(\.key) == [created.device.key])
        #expect(vault.devices.first?.kind == "ipad")
        #expect(vault.manifest.recoveryEntry?.key == created.generatedRecovery?.recipient.string)
        #expect(vault.passphraseCopyNames().isEmpty, "no passphrase: no copy")
        #expect(created.kitVault.root == vault.root)
    }

    /// The id is chosen before the vault exists (the app stores this device's keys under it first).
    @Test func theVaultGetsTheRequestsId() throws {
        var request = Self.request("Chosen")
        let id = UUID()
        request.vaultId = id
        let created = try VaultLibrary.createVault(request, folder: "Chosen.sempere", in: try Self.tempDir())
        #expect(created.vaultID == id)
        #expect(try Vault.open(at: created.url).vaultId == id)
    }

    @Test func anExistingKeyBecomesTheRecoveryKeyAndIsNotHandedBack() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let created = try VaultLibrary.createVault(Self.request("Reused", key: .identity(identity)), folder: "Reused.sempere",
                                                   in: try Self.tempDir())
        #expect(created.secretKey == nil && created.generatedRecovery == nil)
        #expect(try Vault.open(at: created.url).manifest.recoveryEntry?.key == identity.recipient.string)
    }

    @Test func aClassicRecoveryKeyIsRefusedBeforeAnythingIsWritten() throws {
        let classic = try NativeIdentity.generate(.x25519)
        let parent = try Self.tempDir()
        #expect(throws: VaultCreation.CreationError.classicRecoveryKey) {
            try VaultLibrary.createVault(Self.request("Old", key: .identity(classic)), folder: "Old.sempere", in: parent)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Old.sempere").path))
    }

    /// The store's name rule is the one rule (`VaultStore.folderName`): nothing is made for a name it refuses.
    @Test func aNameTheStoreRefusesMakesNothing() async throws {
        let library = try Self.library()
        for bad in ["", ".hidden", "a/b", "x.sempere", "line\u{2028}break"] {
            await #expect(throws: VaultStoreError.invalidName(bad)) { _ = try await library.create(Self.request(bad)) }
        }
        #expect(library.vaultStore.list().isEmpty && library.recents.isEmpty)
    }

    /// The passphrase copy of the recovery key (format.md §15.11) opens to the same key.
    @Test func aPassphraseKeepsACopyOfTheRecoveryKey() throws {
        let created = try VaultLibrary.createVault(Self.request("Wrapped", passphrase: "vuspot-Bekfu4-qobqag"),
                                                   folder: "Wrapped.sempere", in: try Self.tempDir())
        let vault = try Vault.open(at: created.url)
        #expect(vault.passphraseCopyNames().count == 1)
        let copy = try vault.openPassphraseCopy(passphrase: "vuspot-Bekfu4-qobqag")
        #expect(NativeIdentity.mlkem768x25519(copy.identity).string == created.secretKey)
    }

    /// Any passphrase is taken for the copy, a one-letter one too: Sempere offers words, it does not require them.
    @Test func aWeakPassphraseIsAccepted() throws {
        let created = try VaultLibrary.createVault(Self.request("Weak", passphrase: "a"), folder: "Weak.sempere",
                                                   in: try Self.tempDir())
        let vault = try Vault.open(at: created.url)
        #expect(vault.passphraseCopyNames().count == 1)
        #expect(try vault.openPassphraseCopy(passphrase: "a").root == vault.root)
    }

    /// Nothing is trimmed or judged: a whitespace-only passphrase is taken as typed; the form's empty one means none.
    @Test func aWhitespaceOnlyPassphraseIsTakenAsTypedAndAnEmptyOneMeansNone() throws {
        let parent = try Self.tempDir()
        let blank = try VaultLibrary.createVault(Self.request("Blank", passphrase: "  "), folder: "Blank.sempere", in: parent)
        let vault = try Vault.open(at: blank.url)
        #expect(try vault.openPassphraseCopy(passphrase: "  ").root == vault.root)
        #expect(throws: (any Error).self) { try vault.openPassphraseCopy(passphrase: "") }
        let empty = try VaultLibrary.createVault(Self.request("Empty", passphrase: ""), folder: "Empty.sempere", in: parent)
        #expect(try Vault.open(at: empty.url).passphraseCopyNames().isEmpty)
    }

    @Test func rejectsExistingVaults() throws {
        let parent = try Self.tempDir()
        _ = try VaultLibrary.createVault(Self.request("B"), folder: "B.sempere", in: parent)
        #expect(throws: VaultError.self) { try VaultLibrary.createVault(Self.request("B"), folder: "B.sempere", in: parent) }
    }

    /// `VaultCreation` itself, as the CLI calls it: its label and device kind are written, and a store build appears
    /// only complete (`store create`).
    @Test func vaultCreationInAStoreWritesTheGivenOptions() throws {
        let store = VaultStore(root: try Self.tempDir().appendingPathComponent("Vaults"))
        let keys = try VaultCreation.Keys(recovery: .generate)
        let (entry, vault) = try VaultCreation.create(in: store, name: "Work", keys: keys,
                                                      options: .init(deviceName: "sempere CLI", deviceKind: "cli",
                                                                     workFactor: 10, label: "Office"))
        #expect(entry.vaultId == keys.vaultId && vault.vaultId == keys.vaultId)
        let opened = try Vault.open(at: entry.url)
        #expect(opened.label == "Office")
        #expect(opened.devices.first?.kind == "cli")
        #expect(store.list().map(\.name) == ["Work"])
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

    // MARK: - Recents

    @Test func recentsPersistDedupeAndCap() throws {
        let store = try Self.tempDir().appendingPathComponent("recents.json")
        let library = VaultLibrary(storeURL: store)
        var locations: [UUID] = []
        for i in 0..<(VaultLibrary.maxRecents + 2) {
            let location = UUID()
            locations.append(location)
            library.rememberWebDAV(location, name: "v\(i)")
        }
        #expect(library.recents.count == VaultLibrary.maxRecents)
        #expect(library.recents.first?.name == "v\(VaultLibrary.maxRecents + 1)")
        library.rememberWebDAV(locations[5], name: "v5")   // moves to the front, no duplicate
        #expect(library.recents.first?.name == "v5")
        #expect(library.recents.count == VaultLibrary.maxRecents)
        #expect(Set(library.recents.map(\.name)).count == VaultLibrary.maxRecents)
        #expect(VaultLibrary(storeURL: store).recents == library.recents)
    }

    /// A folder outside the store (a debug launch) is not recorded.
    @Test func aFolderOutsideTheStoreIsNotRemembered() throws {
        let library = try Self.library()
        let outside = try Self.tempDir().appendingPathComponent("loose.sempere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(library.remember(outside) == nil)
        #expect(library.recents.isEmpty)
    }

    /// A store vault that is gone from the store gives a clear error and the entry stays: the user removes it.
    @Test func aGoneStoreVaultIsKeptWithAClearError() throws {
        let store = try Self.tempDir().appendingPathComponent("recents.json")
        let gone = RecentVault(id: UUID(), name: "Gone", lastOpened: Date(), storeID: UUID())
        try JSONEncoder().encode([gone]).write(to: store)
        let library = VaultLibrary(storeURL: store)
        #expect(library.recents == [gone])
        #expect(throws: VaultLibrary.LibraryError.cannotResolve(name: "Gone")) { try library.resolve(gone) }
        let webdav = library.rememberWebDAV(UUID(), name: "Remote")
        #expect(throws: VaultLibrary.LibraryError.cannotResolve(name: "Remote")) { try library.resolve(webdav) }
        library.forget(gone)
        #expect(VaultLibrary(storeURL: store).recents == [webdav])
    }

    /// The `recents.json` of 1.0.0: every entry carries `bookmark` (empty for a store or WebDAV vault) and `path`.
    /// Both are ignored; an entry that is neither a store nor a WebDAV vault (never written by 1.0.0) is dropped.
    @Test func aRecentsFileOf1_0_0StillDecodes() throws {
        let store = try Self.tempDir().appendingPathComponent("recents.json")
        let storeID = UUID(), location = UUID()
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Notes","bookmark":"","lastOpened":800000000,
          "path":"/var/mobile/Vaults/x/Notes.sempere","storeID":"\(storeID.uuidString)"},
         {"id":"\(UUID().uuidString)","name":"Remote","bookmark":"","lastOpened":800000001,"webdav":"\(location.uuidString)"},
         {"id":"\(UUID().uuidString)","name":"Loose","bookmark":"AQID","lastOpened":800000002,"path":"/tmp/Loose.sempere"}]
        """
        try Data(json.utf8).write(to: store)
        let library = VaultLibrary(storeURL: store)
        #expect(library.recents.map(\.name) == ["Notes", "Remote"])
        #expect(library.recents[0].storeID == storeID)
        #expect(library.recents[1].webdav == location)
    }

    /// A store vault that is gone is forgotten with its recents.
    @Test func forgettingAStoredVaultDropsItsRecents() async throws {
        let library = try Self.library()
        let created = try await library.create(Self.request("Here"))
        library.forgetStored(created.vaultID)
        #expect(library.recents.isEmpty && library.storedVaults.isEmpty)
    }

    // MARK: - What a pick resolves to

    @Test func aPickResolvesToTheVaultFolder() throws {
        let parent = try Self.tempDir()
        let vault = try VaultLibrary.createVault(Self.request("Notes"), folder: "Notes.sempere", in: parent).url
        #expect(try VaultLocator.resolve(vault).path == vault.path)
        #expect(try VaultLocator.resolve(parent).lastPathComponent == "Notes.sempere", "the one vault in the pick")
        let missing = parent.appendingPathComponent("missing")
        #expect(try VaultLocator.resolve(missing) == missing, "left to opening it")
        // Inside a vault: its scope would not reach the vault.
        #expect(throws: VaultLocator.LocatorError.insideVault("Notes.sempere")) {
            _ = try VaultLocator.resolve(vault.appendingPathComponent("vault.json"))
        }
        _ = try VaultLibrary.createVault(Self.request("Other"), folder: "Other.sempere", in: parent)
        #expect(throws: VaultLocator.LocatorError.severalVaults(["Notes.sempere", "Other.sempere"])) {
            _ = try VaultLocator.resolve(parent)
        }
    }

    // MARK: - Folder access

    @Test func permissionErrorsAreRecognisedWhereverTheyAreNested() {
        #expect(FolderAccess.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        #expect(FolderAccess.isPermissionDenied(CocoaError(.fileWriteNoPermission)))
        #expect(FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FolderAccess.isPermissionDenied(nested))
        #expect(!FolderAccess.isPermissionDenied(CocoaError(.fileNoSuchFile)))
        #expect(!FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    @Test func aReadableOrMissingFolderPasses() throws {
        let dir = try Self.tempDir()
        try FolderAccess.check(dir, scoped: false)
        try FolderAccess.check(dir, scoped: true)
        try FolderAccess.check(dir.appendingPathComponent("missing"), scoped: false)
    }

    @Test func aFolderTheSystemRefusesIsReportedByName() throws {
        let dir = try Self.tempDir().appendingPathComponent("Locked.sempere")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard geteuid() != 0 else { return }   // root ignores permissions
        #expect(throws: FolderAccess.Problem.noAccess(name: "Locked", scoped: false)) {
            try FolderAccess.check(dir, scoped: false)
        }
    }
}

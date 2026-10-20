import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// AppModel against the committed fixture vault (`Tests/SempereTests/Fixtures`,
/// copied into this bundle as a folder reference). See its README for contents.
@MainActor
struct AppModelTests {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A private copy of the fixture, so no test can touch the bundled one.
    static func fixtureVault() throws -> (vault: URL, key: URL) {
        let bundle = Bundle(for: BundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sample.sempere"), to: vault)
        return (vault, fixtures.appendingPathComponent("sample.key"))
    }

    @Test func opensLockedThenUnlocksWithKeyFile() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        #expect(model.phase == .locked)
        #expect(model.vaultName == "sample")
        #expect(model.notes.isEmpty)

        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.phase == .unlocked)
        #expect(model.notes.map(\.id) == [Self.deleted, Self.lecture])   // sorted by title
        let lecture = try #require(model.notes.first { $0.id == Self.lecture })
        #expect(lecture.title == "Fixture lecture")
        #expect(lecture.tags == ["fixture"])
        #expect(lecture.pages == 2)
        #expect(lecture.strokes == 4)
        #expect(lecture.problem == nil)
    }

    @Test func sidebarFiltersLiveAndDeletedNotes() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))

        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        #expect(model.tags == ["fixture"])
        #expect(model.notebooks.isEmpty)
        model.sidebarSelection = .tag("fixture")
        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        model.sidebarSelection = .tag("nope")
        #expect(model.visibleNotes.isEmpty)
        model.sidebarSelection = .deleted
        #expect(model.visibleNotes.map(\.id) == [Self.deleted])
        model.selectedNoteID = Self.lecture
        #expect(model.selectedNote?.title == "Fixture lecture")
    }

    /// The recovery key's passphrase copy (format.md §15.11) opens the vault
    /// read-only (design §4.3 step 4), checked against the root it carries.
    @Test func unlocksReadOnlyWithTheRecoveryPassphraseCopy() async throws {
        let (url, _) = try Self.fixtureVault()
        let model = AppModel(trust: MemoryEpochTrustStore())
        try await model.openVault(at: url)
        await #expect(throws: AppModel.ModelError.passphraseMatchesNoKey) {
            try await model.unlock(passphrase: "wrong")
        }
        #expect(model.phase == .locked)
        try await model.unlock(passphrase: "sempere-test")
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(model.isRecoveryOpen)
        #expect(model.isVaultReadOnly)
        #expect(model.listAlert == nil, "the copy's root confirms the list")
        #expect(model.readOnlyBanner == AppModel.recoveryReadOnlyText)
        #expect(throws: VaultError.recoveryKeyReadOnly) { try model.requireWritableVault() }
        await #expect(throws: (any Error).self) {
            try await model.createNote(title: "No", paper: Paper(kind: .ruled), notebook: nil)
        }
        #expect(model.notes.count == 2)
    }

    /// The recovery key itself, pasted: read-only too, and never offered to remember.
    @Test func thePastedRecoveryKeyOpensReadOnly() async throws {
        let (url, key) = try Self.fixtureVault()
        let recovery = key.deletingLastPathComponent().appendingPathComponent("sample-recovery.key")
        let model = AppModel()
        try await model.openVault(at: url)
        let device = try await model.unlock(identityText: try String(contentsOf: recovery, encoding: .utf8))
        #expect(device == nil)
        #expect(model.isRecoveryOpen)
        #expect(model.isVaultReadOnly)
        #expect(model.heldDeviceKey == nil)
    }

    /// The fixture's device key file unlocks with its signing keys: this device is listed (home).
    @Test func theDeviceKeyFileUnlocksAsAListedDevice() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        let device = try #require(try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8)))
        #expect(!model.isRecoveryOpen)
        #expect(!model.isVaultReadOnly)
        #expect(model.heldDeviceKey == device.key)
        #expect(model.unlockKeys.signing != nil)
        #expect(model.vaultDevices.contains { $0.isThisDevice && $0.deviceID == device.id })
        #expect(model.vaultDevices.filter(\.isRecovery).count == 1)
    }

    @Test func rejectsGarbageAndForeignKeys() async throws {
        let (url, _) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        await #expect(throws: AppModel.ModelError.notAnIdentity) {
            try await model.unlock(identityText: "not a key")
        }
        let stranger = IdentityFile.render(try NativeIdentity.generate(.postQuantum), created: Date())
        await #expect(throws: AppModel.ModelError.notJoined) {
            try await model.unlock(identityText: stranger)
        }
        // Another device's key file: "this device has not joined the vault".
        let other = try DeviceKeys.generate().fileText(created: Date())
        await #expect(throws: AppModel.ModelError.notJoined) {
            try await model.unlock(identityText: other)
        }
        #expect(model.phase == .locked)
    }

    @Test func closeForgetsEverything() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.close()
        #expect(model.phase == .noVault)
        #expect(model.notes.isEmpty)
        #expect(model.vaultURL == nil)
        await #expect(throws: AppModel.ModelError.noVaultOpen) { try await model.reload() }
    }

    @Test func openingAFolderThatIsNotAVaultFails() async throws {
        let model = AppModel()
        await #expect(throws: VaultError.self) {
            try await model.openVault(at: TestTemp.root)
        }
        #expect(model.phase == .noVault)
    }

    // MARK: - Late results after close (generation token)

    @Test func closeDuringUnlockDoesNotResurrectTheVault() async throws {
        let (url, key) = try Self.fixtureVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        let keyText = try String(contentsOf: key, encoding: .utf8)
        await gate.close()
        let before = await gate.arrivals
        let unlock = Task { try await model.unlock(identityText: keyText) }
        await gate.waitForArrivals(before + 1)   // the vault is decrypted; the result is in flight
        model.close()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await unlock.value }
        #expect(model.phase == .noVault)
        #expect(model.vaultURL == nil)
        #expect(model.notes.isEmpty)
    }

    @Test func openingAnotherVaultDuringReloadKeepsTheNewOne() async throws {
        let (first, key) = try Self.fixtureVault()
        let (second, _) = try Self.fixtureVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: first)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        await gate.close()
        let before = await gate.arrivals
        let reload = Task { try await model.reload() }
        await gate.waitForArrivals(before + 1)
        let open = Task { try await model.openVault(at: second) }
        await gate.waitForArrivals(before + 2)
        await gate.open()
        try await open.value
        await #expect(throws: CancellationError.self) { try await reload.value }
        #expect(model.vaultURL == second)
        #expect(model.phase == .locked)
        #expect(model.notes.isEmpty)
    }

    @Test func closeDuringEditorOpenLeavesNoEditor() async throws {
        let (url, key) = try Self.fixtureVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        await gate.close()
        let before = await gate.arrivals
        let open = Task { try await model.openEditor(for: Self.lecture) }
        await gate.waitForArrivals(before + 1)
        model.close()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await open.value }
        #expect(model.editor == nil)
    }

    @Test func closeSavesTheOpenNote() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        model.close()
        #expect(model.editor == nil)
        #expect(await TS.waitUntil { editor.deltasWritten == 1 })
    }

    @Test func reopeningANoteRightAfterCloseReadsItsLastSave() async throws {
        // Regression: close() saved the open note in a detached task, so the
        // same note reopened at once could be read before that delta landed
        // and show strokes whose removal was already on its way to disk.
        let (url, key) = try Self.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        let erased = try #require(editor.liveStrokes(of: page.id).first)
        drawing.strokes.removeFirst()
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        model.close()
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let reopened = try #require(model.editor)
        #expect(editor.deltasWritten == 1)
        #expect(!reopened.liveStrokes(of: page.id).contains { $0.id == erased.id })
    }
}

private final class BundleToken {}

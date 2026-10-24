import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The app's side of the device list check (design §4.3, format.md §15.3):
/// the blocking "device list was changed without its key" alert, no writes
/// and no capture profile for a list that does not check.
@Suite(.serialized)
@MainActor
struct ListAlertTests {
    /// The fixture copy and its device key file, with `trust` holding this
    /// device's record of the fixture's list (as after a join or a creation).
    static func trustedFixture(_ trust: MemoryEpochTrustStore) throws -> (url: URL, keyText: String) {
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        let device = try DeviceKeys.parse(keyText)
        let root = try Vault.open(at: url).root
        let vault = try Vault.open(at: url, identities: [device.nativeIdentity], signing: device.signing, trust: trust, root: root)
        try vault.requireWritable()   // a writer keeps the record
        #expect(try trust.record(for: vault.vaultId) != nil)
        return (url, keyText)
    }

    /// Edits `vault.json` as someone without the key would: a device's name.
    static func tamper(_ url: URL) throws {
        let file = url.appendingPathComponent("vault.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var keys = try #require(json["keys"] as? [[String: Any]])
        keys[0]["name"] = "Evil iPad"
        json["keys"] = keys
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }

    @Test func aCheckedListRaisesNothing() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try Self.trustedFixture(trust)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.listAlert == nil)
        #expect(model.vault?.listStatus == .verified(.unchanged))
        _ = try await model.createNote(title: "Fine", paper: Paper(kind: .ruled), notebook: nil)
    }

    @Test func aTamperedListRaisesTheAlertAndBlocksWrites() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try Self.trustedFixture(trust)
        try Self.tamper(url)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .unlocked, "still readable")
        #expect(model.notes.count == 2)
        let alert = try #require(model.listAlert)
        #expect(alert.problem.reason == .listTag)
        #expect(alert.displayTitle == ListAlert.title)
        #expect(alert.message.contains("Nothing is written"))
        await #expect(throws: VaultError.self) {
            _ = try await model.createNote(title: "No", paper: Paper(kind: .ruled), notebook: nil)
        }
        model.dismissListAlert()
        #expect(model.listAlert == nil)
        await #expect(throws: VaultError.self, "dismissing changes nothing") {
            _ = try await model.createNote(title: "No", paper: Paper(kind: .ruled), notebook: nil)
        }
        #expect(throws: VaultError.self) { try model.vault?.captureProfile(device: DeviceID("0badf00d")!) }
    }

    /// A trust store without a record of the vault, and no root to check it
    /// against: this device has not confirmed the vault (a join's reply code,
    /// KH5 in the app), so it reads and does not write.
    @Test func noRecordAndNoRootIsUnconfirmed() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: MemoryEpochTrustStore())
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.listAlert?.problem.reason == .rootUnconfirmed)
        #expect(model.notes.count == 2)
    }

    /// A new vault saves this device's record: unlocking it again checks.
    @Test func aCreatedVaultChecksAgainstItsRecord() async throws {
        let trust = MemoryEpochTrustStore()
        let parent = TestTemp.root.appendingPathComponent("List-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let created = try VaultLibrary.createVault(NewVaultRequest(name: "Mine", keySource: .generate, passphrase: nil),
                                                   folder: "Mine.sempere", in: parent, trust: trust)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        try await model.openVault(at: created.url)
        try await model.unlock(device: created.device)
        #expect(model.listAlert == nil)
        #expect(model.vault?.isHome == true)
    }

    /// A recovery read with no root (the pasted key) shows no alert: the banner says it is read-only.
    @Test func aPastedRecoveryKeyRaisesNoAlert() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let recovery = key.deletingLastPathComponent().appendingPathComponent("sample-recovery.key")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: MemoryEpochTrustStore())
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: recovery, encoding: .utf8))
        #expect(model.isRecoveryOpen)
        #expect(model.listAlert == nil)
        #expect(model.readOnlyBanner == AppModel.recoveryReadOnlyText)
    }

    @Test func markersProblemsHaveTheirOwnTitle() {
        let markers = ListAlert(problem: ListProblem(.markersTag, "x"))
        #expect(markers.displayTitle == ListAlert.markersTitle)
        #expect(ListAlert(problem: ListProblem(.markersRolledBack, "x")).displayTitle == ListAlert.markersTitle)
        for reason: ListProblem.Reason in [.listTag, .authorSig, .addSig, .epochSig, .introducesDevice, .entriesChanged,
                                           .rootMismatch, .otherEpoch, .recordUnreadable, .rootUnconfirmed] {
            let alert = ListAlert(problem: ListProblem(reason, "x"))
            #expect(alert.displayTitle == ListAlert.title)
            #expect(!alert.message.isEmpty)
        }
    }

    /// Who captured a voice note, in its recording menu (format.md §8.3.1): the listed device's name.
    @Test func capturedByNamesTheDevice() throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let device = try DeviceKeys.parse(try String(contentsOf: key, encoding: .utf8))
        let manifest = try Vault.open(at: url).manifest
        let name = try #require(manifest.devices.first { $0.key == device.key }).name
        var r = Recording(blob: BlobRef(content: Data([1]), type: "audio/mp4"), started: Date())
        #expect(RecordingsMenu.capturedBy(r, manifest: manifest) == nil)
        r.captured = CaptureAttribution(device: "0b0b0b0b", recipient: CaptureKey.fingerprint(of: device.key))
        #expect(RecordingsMenu.capturedBy(r, manifest: manifest) == "Voice note from \(name)")
        r.captured = CaptureAttribution(device: "0b0b0b0b", recipient: CaptureKey.fingerprint(of: "age1pq1gone"))
        #expect(RecordingsMenu.capturedBy(r, manifest: manifest) == "Voice note from a device no longer in this vault")
    }
}

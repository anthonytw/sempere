import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The device list's words in the app (key-hierarchy design §5.5, §6.3 to §6.5; phase KH5): what the sheets, the
/// history and the banners say. The model's half is `SempereAppCoreTests` (`DevicesTests`, `UnlistedOverSyncTests`,
/// `JoinTakeoverTests`).
@Suite(.serialized)
@MainActor
struct DevicesAppTests {
    /// TestFlight 1.0.0 (9): Add Device says where the new device finds the vault (the sync folder's name and place,
    /// or the WebDAV server), from the vault's real targets; with none, that one is needed first.
    @Test func addDeviceNamesTheRealPlace() {
        let icloud = SyncTarget.folder(URL(fileURLWithPath:
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Sempere/Whoopie.sempere"))
        let line = AddDeviceText.instructions(targets: [icloud]) ?? ""
        #expect(line.contains("Open Vault…") && line.contains("“Whoopie.sempere”") && line.contains("iCloud Drive ▸ Sempere")
                && line.contains("Join This Device"), "\(line)")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/Mobile Documents/iCloud~io~github~anthonytw~sempere/Documents/Whoopie.sempere")
                == "iCloud Drive ▸ Sempere")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/CloudStorage/Dropbox-Personal/Notes/Whoopie.sempere")
                == "Dropbox ▸ Notes")
        #expect(AddDeviceText.place(ofFolder: "/Volumes/USB/Sync/Whoopie.sempere") == "USB ▸ Sync")
        let dav = SyncTarget.webdav("https://nas.example/dav/Whoopie/", user: "me", name: "nas")
        let both = AddDeviceText.instructions(targets: [icloud, dav]) ?? ""
        #expect(both.contains("Open from WebDAV…") && both.contains("https://nas.example/dav/Whoopie"), "\(both)")
        #expect(both.components(separatedBy: "\n").count == 2)
        #expect(AddDeviceText.instructions(targets: []) == nil)
        #expect(AddDeviceText.noTarget.contains("Add one first"))
    }

    /// Review of #109: place names for "On My iPad" and Google Drive, and no join instructions for a folder no other
    /// device reaches.
    @Test func addDeviceNamesLocalAndProviderPlaces() {
        let device = AddDeviceText.onMyDevice
        let local = "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D-0000-4000-8000-000000000001/File Provider Storage/Notes/Wompa.sempere"
        // Files' local storage and other File Provider extensions share this kind of path: a neutral name, and the
        // join steps stay (review of #113).
        #expect(AddDeviceText.place(ofFolder: local) == "Notes")
        let other = "/private/var/mobile/Containers/Data/Application/0A1B2C3D-0000-4000-8000-000000000002/Documents/Sync/Wompa.sempere"
        #expect(AddDeviceText.place(ofFolder: other, container: "/elsewhere") == "\(device) ▸ Sync")
        #expect(AddDeviceText.place(ofFolder: "/home/app/Documents/Wompa.sempere", container: "/home/app") == "\(device) ▸ Sempere")
        #expect(AddDeviceText.place(ofFolder: "/Users/me/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Wompa.sempere")
                == "Google Drive ▸ My Drive")
        #expect(!AddDeviceText.isOnlyOnThisDevice(local) && AddDeviceText.isOnlyOnThisDevice(other))
        #expect(!AddDeviceText.isOnlyOnThisDevice("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Wompa.sempere"))
        #expect(!AddDeviceText.isOnlyOnThisDevice("/Volumes/USB/Wompa.sempere"))
        let line = AddDeviceText.instructions(targets: [.folder(URL(fileURLWithPath: other))]) ?? ""
        #expect(line.contains("only on this device") && !line.contains("Join This Device"), "\(line)")
        let shared = AddDeviceText.instructions(targets: [.folder(URL(fileURLWithPath: local))]) ?? ""
        #expect(shared.contains("Join This Device"), "\(shared)")
    }

    /// The history's lines name the devices (`DeviceChangeText.history`): a removal, a handoff, the creation, a
    /// takeover with what it removed, and a device no list here names. The names come from the model
    /// (`DevicesTests.aRemovalStartsANewEpochReopensTheVaultAndShowsInTheHistory`).
    @Test func theHistoryLinesNameTheDevices() {
        let pad = DeviceRef(fingerprint: Data(repeating: 1, count: 32), name: "Home iPad")
        let oldMac = DeviceRef(fingerprint: Data(repeating: 2, count: 32), name: "Old Mac")
        let mac = DeviceRef(fingerprint: Data(repeating: 3, count: 32), name: "Mac")
        let unnamed = DeviceRef(fingerprint: Data(repeating: 0xAB, count: 32), name: nil)
        func event(_ reason: EpochReason, newHome: DeviceRef? = nil, removed: [DeviceRef] = []) -> DeviceHistoryEvent {
            DeviceHistoryEvent(epoch: 2, epochId: Data(count: 32), reason: reason, date: nil, author: pad, newHome: newHome,
                               removed: removed)
        }
        #expect(DeviceChangeText.history(event(.create)) == "Vault created on Home iPad")
        #expect(DeviceChangeText.history(event(.remove, removed: [oldMac])) == "Old Mac removed by Home iPad")
        #expect(DeviceChangeText.history(event(.handoff, newHome: mac)) == "Home iPad made Mac manage devices")
        let takeover = DeviceChangeText.history(event(.takeover, removed: [unnamed]))
        #expect(takeover.hasPrefix("Home iPad took over with the recovery kit"), "\(takeover)")
        #expect(takeover.contains("abababab"), "a device no list names is named by its id: \(takeover)")
    }

    /// After a change, the sheet names each target the run before it could not reach (design §5.2 step 2; the model's
    /// half is `UnlistedOverSyncTests.aChangeWhoseTargetCannotBeReachedNamesIt`).
    @Test func theDoneLineNamesTheUnreachableTargets() {
        let report = EpochChangeReport(epoch: 2, epochId: Data(count: 32), reason: .remove, removed: [], home: Data(count: 32),
                                       sealed: 0)
        #expect(DeviceChangeText.done(DeviceChangeOutcome(report: report), action: "Removed.") == "Removed.")
        let line = DeviceChangeText.done(DeviceChangeOutcome(report: report, unreachable: [.init(name: "nas", lastSuccess: nil)]),
                                         action: "Removed.")
        #expect(line.hasPrefix("Removed.") && line.contains("nas was not reachable"), "\(line)")
    }

    /// The unlock sheet's words for its model's typed outcomes (`RememberedKeys`, SempereAppCore).
    @Test func theUnlockSheetWordsTheKeyProblemsAndFailures() {
        #expect(DeviceKeyProblem.unreadable.text.contains("can no longer be read"))
        #expect(DeviceKeyProblem.expired.text.contains("has expired"))
        #expect(DeviceKeyProblem.stray.text.contains("not on its device list"))
        #expect(DeviceUnlockFailure.keysNotRead(DeviceKeyStoreError.authenticationFailed).text
                == DeviceKeyStoreError.authenticationFailed.description)
        let didNot = DeviceUnlockFailure.keysDidNotUnlock(AppModel.KeyError.vaultChanged).text
        #expect(didNot.hasPrefix("This device's key did not unlock the vault: ") && didNot.contains("Another vault"), "\(didNot)")
    }

    /// The takeover banner names the device and says what to do (`TakeoverAlert.message`).
    @Test func theTakeoverAlertNamesTheDevice() {
        let alert = TakeoverAlert(vaultID: UUID(), epochIds: [Data(count: 32)], vaultName: "Mine", by: "New iPad", date: Date())
        #expect(alert.message.contains("New iPad"))
        #expect(alert.message.contains("Mine"))
        #expect(alert.message.contains("replace the recovery kit"))
        #expect(!TakeoverAlert(vaultID: UUID(), epochIds: [], vaultName: "Mine", by: nil, date: nil).message.isEmpty)
    }

    /// The sheets' messages for the library's typed errors (`DeviceChangeText.message`): the re-encryption's refusals
    /// say which target and why, as before they were typed.
    @Test func theTypedRefusalsHaveTheirWords() {
        let refused = DeviceChangeText.message(ReencryptRefusal.targetUnreachable(name: "nas", error: AppModel.KeyError.notUnlocked))
        #expect(refused.contains("“nas” cannot be reached (") && refused.contains("Unlock the vault first."), "\(refused)")
        #expect(refused.contains("every sync target must be, to start"))
        #expect(DeviceChangeText.message(ReencryptRefusal.targetCannotBeOpened) == "This target cannot be opened for re-encryption.")
        #expect(DeviceChangeText.message(KeyProblem.recoveryKeyNeeded).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(DeviceChangeText.message(DeviceJoinError.rootNeeded).contains("root fingerprint"))
        #expect(AppModel.KeyError.vaultChanged.description.contains("Another vault"))
        #expect(DeviceKeyReason.unlock(vaultName: "Mine").text.contains("Mine"))
        #expect(DeviceKeyReason.withdrawJoin.text.isEmpty)
        #expect(OwnerCheckReason.approveDevice.text == "Let a new device into the vault")
    }

    /// The sheet's "Lost or Stolen" removes the device and the ones it approved; its storage advice names the servers.
    @Test func theRemovalSheetAddsTheApprovedDevicesAndNamesTheServers() {
        #expect(Set(RemoveDeviceSheet.ids(removing: "aaaaaaaa", approved: ["bbbbbbbb"])) == ["aaaaaaaa", "bbbbbbbb"])
        #expect(RemoveDeviceSheet.storageAdvice(servers: [], hasFolder: false).contains("no sync targets"))
        #expect(RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("nas"))
        #expect(!RemoveDeviceSheet.storageAdvice(servers: ["nas"], hasFolder: false).contains("iCloud"))
    }

    /// Review of #87, M2: the line typed back is never the fixed prefix line.
    @Test func theKitCheckNeverAsksForThePrefixLine() throws {
        let kit = try MLKEM768X25519Identity()
        let lines = PaperKey.identityLines(kit.string)
        #expect(lines.first.map { PaperKey.identityPrefixes.contains($0.text) } == true, "line 1 is the prefix")
        for pick in [{ (r: ClosedRange<Int>) in r.lowerBound }, { (r: ClosedRange<Int>) in r.upperBound }] {
            let n = ReplaceKitSheet.checkLine(of: kit.string, random: pick)
            #expect(n >= 2 && n <= lines.count)
            #expect(!PaperKey.identityPrefixes.contains(lines[n - 1].text))
        }
        for _ in 0..<50 { #expect(ReplaceKitSheet.checkLine(of: kit.string) != 1) }
        #expect(!ReplaceKitSheet.lineMatches("AGE-SECRET-KEY-PQ-1", line: 2, of: kit.string))
    }

    @Test func theKitLineCheckTakesAnyCaseAndSpacesButOnlyThatLine() throws {
        let kit = try MLKEM768X25519Identity()
        let lines = PaperKey.identityLines(kit.string)
        let line2 = lines[1]
        #expect(ReplaceKitSheet.lineMatches(line2.groups.joined(separator: " ").lowercased(), line: 2, of: kit.string))
        #expect(ReplaceKitSheet.lineMatches(line2.text, line: 2, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches(line2.text, line: 3, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches("", line: 2, of: kit.string))
        #expect(!ReplaceKitSheet.lineMatches(line2.text, line: lines.count + 1, of: kit.string))
    }

    @Test func theNoticesHaveTheirWords() {
        for notice in [DeviceNotice.unlisted, .heldBack(since: Date()), .homeConflict] {
            #expect(!notice.text.isEmpty)
            #expect(!notice.symbol.isEmpty)
        }
        let home = DeviceRow(id: "aaaaaaaa", fingerprint: Data(count: 32), name: "Home iPad", kind: "ipad", added: nil,
                             addedBy: .creation, isHome: true, isThisDevice: true, lastSynced: nil)
        #expect(home.symbol == "ipad")
    }
}

import Age
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// A new vault's recovery key on its way out (the receipt's Save to Files,
/// Share and kit), and the share sheet's staged file.
@MainActor
struct KeyExportTests {
    /// Security review 2026-10 stage 4, S14 and P2: the share sheet of a secret key (its text on the new-vault
    /// screen, its key file in Save Key… and New Key…) has no Copy, which would put the key on
    /// the general pasteboard with no expiry and hand it to Universal Clipboard.
    @Test func secretShareSheetsLeaveCopyOut() {
        let controller = SecretSharing.controller(items: ["AGE-SECRET-KEY-PQ-1EXAMPLE"])
        #expect(controller.excludedActivityTypes?.contains(.copyToPasteboard) == true)
        let sheet = ShareSheet(items: ["AGE-SECRET-KEY-PQ-1EXAMPLE"], secret: true) {}
        #expect(sheet.secret)
        #expect(ShareSheet(items: [URL(fileURLWithPath: "/tmp/x.pdf")]) {}.secret == false, "exports keep Copy")
    }

    /// The Mac's share menu (macOS 27) lists Copy despite `excludedActivityTypes`, and its Copy put the
    /// staged key file's URL and path on the pasteboard (KeyShareMacUITests): every secret item is a
    /// `SecretItem`, which hands a copy activity nothing and any other activity the item.
    @Test func secretItemsGiveCopyNothing() {
        let controller = SecretSharing.controller(items: ["AGE-SECRET-KEY-PQ-1EXAMPLE"])
        let source = SecretItem("AGE-SECRET-KEY-PQ-1EXAMPLE")
        #expect(source.activityViewControllerPlaceholderItem(controller) as? String == "AGE-SECRET-KEY-PQ-1EXAMPLE")
        for type: UIActivity.ActivityType in [.copyToPasteboard, UIActivity.ActivityType("com.apple.share.Copy"),
                                              UIActivity.ActivityType("com.apple.NSSharingService.copy")] {
            #expect(source.activityViewController(controller, itemForActivityType: type) == nil, "\(type.rawValue)")
        }
        for type: UIActivity.ActivityType? in [.mail, .airDrop, .message, nil] {
            #expect(source.activityViewController(controller, itemForActivityType: type) as? String == "AGE-SECRET-KEY-PQ-1EXAMPLE")
        }
    }

    /// Biometrics when enrolled, never the passcode after a lockout (anyone who
    /// knows it could fail Face ID on purpose); the passcode only without biometrics.
    @Test func ownerCheckNeverFallsBackToThePasscodeAfterALockout() {
        #expect(OwnerCheck.choose(biometricsUsable: true, biometricsLockedOut: false) == .biometrics)
        #expect(OwnerCheck.choose(biometricsUsable: false, biometricsLockedOut: true) == .lockedOut)
        #expect(OwnerCheck.choose(biometricsUsable: false, biometricsLockedOut: false) == .passcode)
    }

    /// The receipt of a new vault: its generated recovery key as a key file
    /// (the CLI's identity file format), which opens the vault read-only, and
    /// its kit, printed for that vault.
    @Test func aNewVaultsRecoveryKeyIsAFileAndAKit() async throws {
        let parent = TestTemp.root.appendingPathComponent("Kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let created = try VaultLibrary.createVault(NewVaultRequest(name: "Kit", keySource: .generate, passphrase: nil),
                                                   folder: "Kit.sempere", in: parent)
        let file = try #require(created.recoveryKey)
        #expect(file.secret == created.secretKey)
        #expect(file.fileName.hasPrefix("Sempere key - "))
        let identity = try IdentityFile.parse(file.text)
        #expect(identity.recipient.string == file.recipient)
        let vault = try Vault.open(at: created.url, identities: [identity])
        #expect(vault.isRecoveryOpen)
        #expect(created.kitVault.root == vault.root)
        let kit = try AppModel.recoveryKitPDF(for: file, vault: created.kitVault)
        #expect(kit.starts(with: Data("%PDF-".utf8)))
        let a4 = try AppModel.recoveryKitPDF(for: file, vault: created.kitVault, a4: true)
        #expect(a4.starts(with: Data("%PDF-".utf8)))
    }

    @Test func theSharedFileIsPrivateAndPurged() throws {
        let root = TestTemp.root.appendingPathComponent("KeyShare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = KeyFile(identity: try NativeIdentity.generate(.postQuantum), label: "Mac")
        let first = try KeyShareFile.stage(key, in: root)
        #expect(first.lastPathComponent == "Sempere key - Mac.txt")
        #expect(first.path.hasPrefix(root.path))
        #expect(try String(contentsOf: first, encoding: .utf8) == key.text)
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let second = try KeyShareFile.stage(key, in: root)
        #expect(!FileManager.default.fileExists(atPath: first.path), "staging again removes the earlier file")
        KeyShareFile.purge(in: root)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

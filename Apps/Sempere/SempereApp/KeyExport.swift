import Age
import Foundation
import LocalAuthentication
import Sempere
import SempereRender

/// A secret key on its way out of the app (a new vault's recovery key, shown
/// once): the `age-keygen` style text `sempere vault init --recovery-out`
/// writes (`IdentityFile.render`), the name to suggest, and what the recovery
/// kit needs. It lives in a view's state while the sheet is up and nowhere else.
struct KeyFile: Sendable, Equatable {
    /// The `AGE-SECRET-KEY-PQ-1…` line.
    var secret: String
    /// The `age1pq1…` recipient.
    var recipient: String
    /// What the key is, for file names ("Recovery key of Notes").
    var label: String
    /// The file's text: `# created`, `# public key`, the secret line.
    var text: String

    init(identity: NativeIdentity, label: String, created: Date = Date()) {
        secret = identity.string
        recipient = identity.recipient.string
        self.label = label
        text = IdentityFile.render(identity, created: created)
    }

    /// `Sempere key - <label>.txt`.
    var fileName: String { IdentityFile.exportFileName(label: label) }
}

/// Asks the device owner to prove they are there before a secret key leaves
/// the app, or a list change that needs the owner at the device (Replace Recovery Kit, key-hierarchy design
/// §6.5; `AppModel.ownerAuthenticator`). Tests inject a fake.
protocol OwnerAuthenticator: Sendable {
    func authenticate(reason: String) async throws
}

/// Which check `SystemOwnerAuthenticator` asks for.
enum OwnerCheck: Equatable {
    case biometrics
    case passcode
    /// Biometrics are enrolled but locked out (too many failed attempts).
    case lockedOut

    /// Biometrics whenever they are enrolled; the passcode only on a device
    /// without them. A lockout is not "without": falling back to the passcode
    /// then would let anyone who knows it fail Face ID on purpose and save the key.
    static func choose(biometricsUsable: Bool, biometricsLockedOut: Bool) -> OwnerCheck {
        biometricsUsable ? .biometrics : biometricsLockedOut ? .lockedOut : .passcode
    }
}

/// Face ID or Touch ID when enrolled, with no passcode fallback (as for
/// device-only remembered keys, `RememberedKeys.deviceOnlyFooter`), not even
/// after a lockout; the passcode (or the Mac's password) only on a device
/// without biometrics.
struct SystemOwnerAuthenticator: OwnerAuthenticator {
    func authenticate(reason: String) async throws {
        #if DEBUG
        // UI tests: a scripted answer instead of Touch ID, which XCTest cannot give (`DebugLaunch`).
        if let answer = DebugLaunch.ownerCheck {
            switch answer {
            case .pass: return
            case .fail: throw AppModel.KeyExportError.notAuthenticated
            case .cancel: throw CancellationError()
            }
        }
        #endif
        let context = LAContext()
        var biometricsError: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricsError)
        let lockedOut = biometricsError.map { $0.domain == LAErrorDomain && $0.code == LAError.Code.biometryLockout.rawValue }
            ?? false
        let policy: LAPolicy
        switch OwnerCheck.choose(biometricsUsable: usable, biometricsLockedOut: lockedOut) {
        case .biometrics: policy = .deviceOwnerAuthenticationWithBiometrics
        case .passcode: policy = .deviceOwnerAuthentication
        case .lockedOut: throw AppModel.KeyExportError.biometryLockedOut
        }
        guard context.canEvaluatePolicy(policy, error: nil) else { throw AppModel.KeyExportError.noDeviceLock }
        do {
            _ = try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            throw CancellationError()
        } catch {
            throw AppModel.KeyExportError.notAuthenticated
        }
    }
}

/// A plaintext key file handed to the share sheet: the share sheet takes
/// files by URL, so this is the one place a key is written by the app. It goes
/// to `<tmp>/SempereKeyShare/<uuid>/<name>` (file protection complete, mode
/// 0600) and is deleted when the share sheet closes, when the sheet that
/// staged it goes away, and at launch. "Save to Files" needs no file: it
/// writes the text straight to the folder the user picks.
enum KeyShareFile {
    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereKeyShare", isDirectory: true)
    }

    /// Writes `key` for the share sheet, after removing any earlier one.
    static func stage(_ key: KeyFile, in root: URL = KeyShareFile.root) throws -> URL {
        purge(in: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(key.fileName)
        #if os(iOS)
        try Data(key.text.utf8).write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        #else
        try Data(key.text.utf8).write(to: url, options: [.withoutOverwriting])
        #endif
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Deletes every staged key file.
    nonisolated static func purge(in root: URL = KeyShareFile.root) {
        try? FileManager.default.removeItem(at: root)
    }
}

extension AppModel {
    enum KeyExportError: Error, Equatable, CustomStringConvertible {
        case notAuthenticated
        case noDeviceLock
        case biometryLockedOut

        var description: String {
            switch self {
            case .notAuthenticated: return String(localized: "Sempere could not confirm it is you, so the key was not shown.")
            case .noDeviceLock: return String(localized: "Set a passcode (or Face ID or Touch ID) on this device to save its key.")
            case .biometryLockedOut:
                return String(localized: "Face ID or Touch ID is locked after too many attempts. Lock the device and unlock it with its passcode, then try again.")
            }
        }
    }

    /// The key of this device in the open vault's list (`age1pq1…`), when it
    /// was unlocked as a listed device; nil when locked or opened with the
    /// recovery key.
    var heldDeviceKey: String? { vault?.deviceEntry?.key }

    /// The recovery kit PDF (format.md §15.13) of a new recovery key: a new vault's, or a replacement's
    /// (Replace Recovery Kit). No device keeps the recovery key, so a kit is printed only then.
    nonisolated static func recoveryKitPDF(for key: KeyFile, vault: RecoveryKit.VaultInfo, a4: Bool = false) throws -> Data {
        var kit = RecoveryKit(secret: .identity(key.secret), recipient: key.recipient, vault: vault, printed: Date())
        if a4 { kit.useA4() }
        return try kit.pdf()
    }
}

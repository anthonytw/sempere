import Foundation
import Sempere
import SempereSync
#if canImport(SempereCloudKit)
import SempereCloudKit
#endif

/// The CloudKit side of the store commands (docs/design/1.4-cloudkit.md §6.5). The adapter (`SempereCloudKit`) is linked
/// on macOS only, and works only in a build signed for the iCloud container: a Homebrew install carries the signed bundle
/// `sempere.app`; a source build (`swift build`) has no provisioning profile and says so here, before CloudKit is touched
/// (which would raise an exception in an unsigned process).
enum CloudKitCLI {
    /// Why CloudKit cannot be used here, in words for the person running the command; nil when it can.
    static var unavailable: String? {
        #if canImport(SempereCloudKit)
        if CloudKitDatabase.availability() != .available {
            return "iCloud (CloudKit) is not available in this build of sempere: it is not signed for the iCloud container "
                + "(a source build has no provisioning profile). Use the released sempere (the Homebrew install carries "
                + "the signed sempere.app), or sync this vault through a folder or WebDAV target."
        }
        return nil
        #else
        return "iCloud (CloudKit) is only available in sempere for macOS (the released, signed build); this build has no CloudKit."
        #endif
    }

    /// The signed-in account, for a new target: its hash, or a sentence saying what to do.
    static func accountHash() throws -> String? {
        if let unavailable { throw CLIError.failure(unavailable) }
        #if canImport(SempereCloudKit)
        let account = try CloudKitDatabase().account()
        switch account.status {
        case .available: return account.userHash
        case .noAccount: throw CLIError.failure("Sign in to iCloud in System Settings first, then add the target.")
        case .restricted, .managedAccountRestricted:
            throw CLIError.failure("iCloud is restricted on this Mac (Screen Time or device management).")
        case .temporarilyUnavailable, .couldNotDetermine:
            throw CLIError.failure("iCloud is not answering right now. Try again in a moment.")
        }
        #else
        return nil
        #endif
    }

    /// The remote of a CloudKit target: the vault's zone, the mirror in the target's state folder.
    static func remote(_ t: SyncTarget, vaultId: UUID, stateDirectory: URL) throws -> CloudRecordRemote {
        if let unavailable { throw CLIError.failure(unavailable) }
        #if canImport(SempereCloudKit)
        return CloudTargetRun.remote(store: CloudKitDatabase(), vaultId: vaultId, stateURL: stateDirectory.appendingPathComponent("sync-state.json"),
                                     expectedUser: t.cloudUser)
        #else
        throw CLIError.failure(unavailable ?? "iCloud (CloudKit) is not available")
        #endif
    }
}

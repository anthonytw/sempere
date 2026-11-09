import Foundation
import Sempere
import SempereAppCore

/// The words for what a folder pick or a save breaks (`PickedFolderRules`, in `SempereAppCore`, holds the rules).
extension PickedFolderRules {
    /// Why a pick that is no plain folder is refused.
    static var notAFolder: String {
        String(localized: "Choose a folder.", comment: "Mac folder panel: a file was chosen")
    }

    /// `violation` in words for the user.
    static func message(_ violation: Violation, isMac: Bool = Platform.isMac) -> String {
        switch violation {
        case .insideHolder(let name, let holderName, let opening):
            if opening {
                return isMac
                    ? String(localized: "“\(name)” is inside “\(holderName)”. To open the vault, select “\(holderName)” itself and click Open, without going into it.",
                             comment: "Open Vault on a Mac: the chosen folder is inside a vault or backup; first %@ is the chosen folder, the others the vault's folder")
                    : String(localized: "“\(name)” is inside “\(holderName)”. To open the vault, go back to “\(holderName)” and tap Open there.",
                             comment: "Open Vault on iPhone and iPad: the chosen folder is inside a vault or backup; first %@ is the chosen folder, the others the vault's folder")
            }
            return String(localized: "“\(name)” is inside “\(holderName)”, a vault or a backup. Choose a folder outside it.",
                          comment: "Folder picker: the chosen folder is inside a vault or backup folder; first %@ is the chosen folder, the second that vault's folder")
        case .backupAsSyncFolder(let name):
            return String(localized: "“\(name)” is a backup. A sync would write into it, so it is never a sync folder. Choose another folder.",
                          comment: "Folder picker: a backup folder chosen as a sync folder; %@ is its name")
        case .vaultAsBackupFolder(let name):
            return String(localized: "“\(name)” is a vault. A backup goes next to it, never into it: choose the folder that holds it, or another folder.",
                          comment: "Folder picker: a vault folder chosen as the backup folder; %@ is its name")
        case .holderAsExportFolder(let name):
            return String(localized: "“\(name)” is a vault or a backup. Exported files are not encrypted, so they never go into one. Choose another folder.",
                          comment: "Folder picker: a vault or backup folder chosen for exported files; %@ is its name")
        }
    }

    /// Why an export cannot save a file at `url`, in words for the user; nil when it can.
    static func saveProblem(_ url: URL) -> String? {
        saveViolation(of: url).map { message($0) }
    }

    /// Why `url` cannot be chosen for `purpose`, in words for the user; nil when it can.
    static func problem(_ url: URL, for purpose: Purpose, isMac: Bool = Platform.isMac) -> String? {
        violation(of: url, for: purpose).map { message($0, isMac: isMac) }
    }
}

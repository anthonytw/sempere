import Foundation
import Sempere
import SempereSync
import UIKit

/// What Add Device tells the user to do on the new device, built from the vault's real sync targets (TestFlight
/// 1.0.0 (9): "open the vault" did not say where, and an owner opened a backup instead of the sync folder).
enum AddDeviceText {
    /// One sentence per target: where the new device opens the vault and what it chooses then; nil without a
    /// target (a new device can only join through one: `noTarget`).
    static func instructions(targets: [SyncTarget]) -> String? {
        let lines = targets.compactMap(line(for:))
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Why Add Device cannot go on without a sync target.
    static let noTarget = String(localized: "A new device joins through a sync target: a folder (for example in iCloud Drive) or a WebDAV server that both devices reach. This vault has none yet. Add one first, then open it on the new device.",
                                 comment: "Add Device without any sync target")

    /// A waiting request's second line: its id and when it asked ("id 3f2a1b9c · asked Oct 27, 9:41").
    static func requestDetail(_ request: JoinRequest) -> String {
        let id = String(request.fileName.prefix(8))
        guard let asked = RFC3339.parse(request.created) else {
            return String(localized: "id \(id)", comment: "Add Device: a join request's id (8 hex digits)")
        }
        let when = asked.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "id \(id) · asked \(when)", comment: "Add Device: a join request's id and when it was made")
    }

    /// While no request is in the copy: whether Add Device has looked yet, and whether one is on its way.
    static func looking(_ lookout: JoinRequestLookout?) -> String {
        guard let lookout else { return String(localized: "Looking for devices that asked to join…") }
        if lookout.arriving {
            return String(localized: "A request is on its way: the sync target's storage (such as iCloud Drive) has listed it but not delivered it yet. Still looking…")
        }
        return String(localized: "No device has asked to join yet. A request comes through the sync target, and iCloud Drive can take a minute or two to deliver it. Still looking…")
    }

    static func line(for target: SyncTarget) -> String? {
        switch target.kind {
        case .folder:
            guard let path = target.path else { return nil }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if isOnlyOnThisDevice(path) {
                // No other device reaches it: join instructions would send the user nowhere (review of #109).
                return String(localized: "“\(name)” is only on this device (\(place(ofFolder: path))), so no other device can open it. To add a device, add a sync target both devices reach first: a folder in iCloud Drive, or a WebDAV server.",
                              comment: "Add Device; %1$@ is the sync folder's name, %2$@ where it is (On My iPad ▸ Notes)")
            }
            return String(localized: "On the new device: choose Open Vault… on the welcome screen, pick “\(name)” in \(place(ofFolder: path)), then choose Join This Device.",
                          comment: "Add Device; %1$@ is the sync folder's name (Whoopie.sempere), %2$@ where it is (iCloud Drive ▸ Sempere)")
        case .webdav:
            guard let address = target.url else { return nil }
            return String(localized: "On the new device: choose Open from WebDAV… on the welcome screen, connect to \(address), then choose Join This Device.",
                          comment: "Add Device; %@ is the WebDAV server's address")
        default:
            return nil
        }
    }

    /// Where the folder at `path` is, as Files names it: "iCloud Drive ▸ Sempere" for
    /// `…/Mobile Documents/com~apple~CloudDocs/Sempere/Whoopie.sempere`, an app's own iCloud folder by the app's
    /// name, a Mac provider (`~/Library/CloudStorage/Dropbox-…`) by its name, anything else by its last two folders.
    static func place(ofFolder path: String, container: String = NSHomeDirectory()) -> String {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().pathComponents
            .filter { $0 != "/" }
        let separator = " ▸ "
        if let i = parts.firstIndex(of: "File Provider Storage"), i + 1 < parts.count {
            // Files' On My iPad or another app's File Provider storage (they share this kind of path): only the folders
            // inside it, which Files shows under either, with no claim about which.
            return parts[(i + 1)...].joined(separator: separator)
        }
        if let rest = appContainerRest(parts, container: container) {
            // An app's own folder under "On My iPad" (`…/Application/<UUID>/Documents/…`): this app's is Sempere's;
            // another app's name is not in its path.
            let own = URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(
                URL(fileURLWithPath: container).standardizedFileURL.path + "/")
            return ([onMyDevice] + (own ? ["Sempere"] : []) + rest).joined(separator: separator)
        }
        if let i = parts.firstIndex(of: "Mobile Documents"), i + 1 < parts.count {
            var head = [String(localized: "iCloud Drive", comment: "Where a sync folder is: the iCloud Drive root")]
            var rest = Array(parts[(i + 2)...])
            let container = parts[i + 1]
            if container != "com~apple~CloudDocs" {
                // An app's iCloud folder (`iCloud~io~github~anthonytw~sempere/Documents`): Files shows it under the
                // app's name.
                if let last = container.split(separator: "~").last {
                    head.append(last.prefix(1).uppercased() + last.dropFirst())
                }
                if rest.first == "Documents" { rest.removeFirst() }
            }
            return (head + rest).joined(separator: separator)
        }
        if let i = parts.firstIndex(of: "CloudStorage"), i > 0, parts[i - 1] == "Library", i + 1 < parts.count {
            let provider = parts[i + 1].split(separator: "-", maxSplits: 1).first.map(String.init) ?? parts[i + 1]
            return ([providerName(provider)] + parts[(i + 2)...]).joined(separator: separator)
        }
        return parts.suffix(2).joined(separator: separator)
    }

    /// True when only this device reaches the folder at `path`: an app's own container (`…/Application/<UUID>/…`).
    /// A drive, a share or a provider's folder may be reached elsewhere, so they keep their instructions. Files' "On My
    /// iPad" storage (`…/Shared/AppGroup/<UUID>/File Provider Storage/…`) is not told apart: other File Provider
    /// extensions (Nextcloud, Working Copy…) keep their files under the same kind of path (review of #113), so it
    /// keeps its instructions and a neutral place name.
    static func isOnlyOnThisDevice(_ path: String, container: String = NSHomeDirectory()) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
        return appContainerRest(parts, container: container) != nil
    }

    /// "On My iPad", "On My iPhone" or "On My Mac", as Files and Finder say it.
    static var onMyDevice: String {
        if Platform.isMac { return String(localized: "On My Mac", comment: "Where a sync folder is: the Mac's own storage") }
        return UIDevice.current.userInterfaceIdiom == .pad
            ? String(localized: "On My iPad", comment: "Where a sync folder is: Files' On My iPad")
            : String(localized: "On My iPhone", comment: "Where a sync folder is: Files' On My iPhone")
    }

    /// A provider's folder name as people know it: `GoogleDrive` is Google Drive, `OneDrive` stays.
    static func providerName(_ folder: String) -> String {
        switch folder {
        case "GoogleDrive": return "Google Drive"
        case "pCloudDrive": return "pCloud Drive"
        default: return folder
        }
    }


    /// The folders below an app's Documents (`…/Containers/Data/Application/<UUID>/Documents/…`, or this app's own
    /// home `container`), nil when `parts` is not in one.
    private static func appContainerRest(_ parts: [String], container: String) -> [String]? {
        if let i = parts.firstIndex(of: "Application"), i >= 2, parts[i - 1] == "Data", parts[i - 2] == "Containers",
           i + 1 < parts.count, UUID(uuidString: parts[i + 1]) != nil {
            let rest = Array(parts[(i + 2)...])
            return rest.first == "Documents" ? Array(rest.dropFirst()) : rest
        }
        let home = URL(fileURLWithPath: container).standardizedFileURL.pathComponents.filter { $0 != "/" }
        if !home.isEmpty, parts.count > home.count, Array(parts.prefix(home.count)) == home {
            let rest = Array(parts[home.count...])
            return rest.first == "Documents" ? Array(rest.dropFirst()) : rest
        }
        return nil
    }
}

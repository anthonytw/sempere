import Sempere
import UIKit

/// How this device names itself in a vault's device list (format.md §15.3):
/// the entry's `name` and `kind` when it creates a vault (and, in KH5, when it
/// asks to join one). Home renames any device afterwards (Devices ▸ ⋯ ▸ Rename…).
enum ThisDevice {
    /// `mac`, `iphone` or `ipad`.
    @MainActor static var kind: String {
        kind(isMac: Platform.isMac, isPhone: Platform.isPhone)
    }

    nonisolated static func kind(isMac: Bool, isPhone: Bool) -> String {
        isMac ? "mac" : isPhone ? "iphone" : "ipad"
    }

    /// The name this device gives itself, told apart from the user's other devices (build 12: "When the Mac syncs, it
    /// shows up as iPad"): its model and four hex digits of this app's per-device id ("MacBook Pro 3F2A", "iPad 9C1D").
    /// Never the computer's or the user's name: names are stored unencrypted in `vault.json` on every target, a WebDAV
    /// server included, and a computer name usually holds the owner's name (review of #124). A name the user gave the
    /// device that the system hands over (iOS, with the user-assigned-name entitlement) stands as it is.
    @MainActor static var name: String {
        name(kind: kind, systemName: UIDevice.current.name, hardwareModel: kind == "mac" ? hardwareModel() : "",
             vendorID: UIDevice.current.identifierForVendor)
    }

    nonisolated static func name(kind: String, systemName: String, hardwareModel: String, vendorID: UUID?) -> String {
        let base: String
        switch kind {
        case "mac":
            // `UIDevice.name` is "iPad" on Mac Catalyst: the model family comes from `hw.model`.
            base = macFamily(hardwareModel)
        default:
            let system = DeviceName.clean(systemName)
            if !system.isEmpty, !genericNames.contains(system) { return system }
            base = system.isEmpty ? (kind == "iphone" ? "iPhone" : "iPad") : system
        }
        guard let vendorID else { return base }
        return DeviceName.clean("\(base) \(vendorID.uuidString.prefix(4))")
    }

    /// What `UIDevice.name` says without the user-assigned-name entitlement.
    nonisolated static let genericNames: Set<String> = ["iPad", "iPhone", "iPod touch", "Mac"]

    /// The marketing family of a Mac model identifier (`hw.model`: "MacBookPro18,3" is "MacBook Pro"); "Mac" for the
    /// identifiers Apple silicon Macs share ("Mac14,2") and anything unknown.
    nonisolated static func macFamily(_ model: String) -> String {
        let prefix = String(model.prefix { $0.isLetter })
        let families: [String: String] = [
            "MacBookPro": "MacBook Pro", "MacBookAir": "MacBook Air", "MacBook": "MacBook",
            "iMacPro": "iMac Pro", "iMac": "iMac", "Macmini": "Mac mini", "MacPro": "Mac Pro",
        ]
        return families[prefix] ?? "Mac"
    }

    /// `sysctl hw.model` ("MacBookPro18,3"); empty when it cannot be read.
    nonisolated static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

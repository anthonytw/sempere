import Foundation
import Sempere
import SempereAppCore
import UIKit

/// What the system tells this device about itself, for `ThisDevice`'s rules (`SempereAppCore`): `UIDevice` and `hw.model`.
extension ThisDevice {
    /// `mac`, `iphone` or `ipad`.
    @MainActor static var kind: String {
        kind(isMac: Platform.isMac, isPhone: Platform.isPhone)
    }

    /// This device's name in a vault's list (`name(kind:systemName:hardwareModel:vendorID:)`).
    @MainActor static var name: String {
        name(kind: kind, systemName: UIDevice.current.name, hardwareModel: kind == "mac" ? hardwareModel() : "",
             vendorID: UIDevice.current.identifierForVendor)
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

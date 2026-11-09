import Foundation
import SempereAppCore

/// Add Device's approving on this app's model (`AddDeviceApprovalCore`, in `SempereAppCore`); the failure in words.
typealias AddDeviceApproval = AddDeviceApprovalCore<AppHost>

extension AddDeviceApprovalCore where Host == AppHost {
    /// What the last approval, decline or look failed with, in words for the sheet.
    var failure: String? { failedWith.map(DeviceChangeText.message) }
}

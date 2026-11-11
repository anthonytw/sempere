import Foundation
import Sempere
import SempereAppCore

// The words of the device list, the device notices, joins and takeovers (the logic is SempereAppCore's: `AppModel+Devices`,
// `+DeviceNotices`, `+JoinDevice`, `+Keys`). The device-change sheets' messages are `DeviceChangeText` (DevicesView.swift).

extension DeviceRow {
    /// The SF Symbol for its kind.
    var symbol: String {
        switch kind {
        case "ipad": return "ipad"
        case "iphone": return "iphone"
        case "mac": return "laptopcomputer"
        case "cli": return "terminal"
        default: return "desktopcomputer"
        }
    }
}

/// "<name> took over managing devices of <vault> with the recovery kit" (design §6.3): a banner that stays
/// until it is dismissed, and a notification.
extension TakeoverAlert {
    static let title = String(localized: "Takeover with the recovery kit", comment: "Notification and banner title")

    var message: String {
        let who = by ?? String(localized: "A device", comment: "Takeover alert: the device is not named on any list here")
        let when = date.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? String(localized: "recently", comment: "Takeover alert: when, if unknown")
        return String(localized: "\(who) took over managing devices of “\(vaultName)” with the recovery kit, \(when). If this was not you, replace the recovery kit on a device that still manages devices.",
                      comment: "Takeover alert; the values are a device name, the vault name and a date")
    }
}

extension DeviceNotice {
    /// The banner's line.
    var text: String {
        switch self {
        case .unlisted:
            return String(localized: "This device is not on the vault's newest device list. Nothing is written or synced.",
                          comment: "Banner: this device was removed from the vault")
        case .heldBack(let since):
            // The date is when this device first met the change it waits for (its sighting), not its last sync
            // (offline audit P10).
            return String(localized: "Since \(since.formatted(date: .abbreviated, time: .omitted)), this device has been waiting for a device change from the device that manages devices. Until it arrives, nothing new is uploaded.",
                          comment: "Banner: sync held back; the value is the date the wait began")
        case .homeConflict:
            return String(localized: "The vault has two conflicting device lists. This device keeps its own until a takeover settles it.",
                          comment: "Banner: a home conflict")
        case .removalsUndone(let names, let home):
            let list = ListFormatter.localizedString(byJoining: names)
            return home
                ? String(localized: "A takeover undid this device's removal of \(list). They are on the device list again: remove them again if they should not be.",
                         comment: "Banner on the device that manages devices; the value lists device names")
                : String(localized: "A takeover undid this device's removal of \(list). They are on the device list again: ask the device that manages devices to remove them again if they should not be.",
                         comment: "Banner; the value lists device names")
        }
    }

    var symbol: String {
        switch self {
        case .unlisted: return "person.crop.circle.badge.xmark"
        case .heldBack: return "pause.circle"
        case .homeConflict: return "exclamationmark.triangle"
        case .removalsUndone: return "person.crop.circle.badge.exclamationmark"
        }
    }
}

extension AppModelKeyError {
    var text: String {
        switch self {
        case .notUnlocked: return String(localized: "Unlock the vault first.")
        case .vaultChanged: return String(localized: "Another vault was opened meanwhile. Nothing was changed.")
        }
    }
}

extension KeyProblem {
    var text: String {
        switch self {
        case .recoveryKeyNeeded: return String(localized: "Paste the recovery key from the printed kit (AGE-SECRET-KEY-PQ-1…).")
        }
    }
}

extension JoinDelivery {
    /// The join screen's line.
    var text: String {
        switch self {
        case .sending:
            return String(localized: "Sending the request to the vault's sync target…")
        case .waitingForUpload(let iCloud):
            return iCloud
                ? String(localized: "Waiting for iCloud Drive to upload the request. It can take a minute or two; keep this screen open.")
                : String(localized: "Waiting for the sync folder's storage to upload the request. Keep this screen open.")
        case .sent:
            return String(localized: "The request is in the sync target. On the device that manages devices, open Add Device and type these words.")
        case .problem(let why):
            return String(localized: "The request could not be sent yet: \(why)", comment: "Join screen; the value is the sync problem")
        }
    }
}

extension NearbyJoinStatus {
    /// The join screen's line for the nearby link (docs/design/nearby-join.md); nil when there is nothing to say.
    var text: String? {
        switch self {
        case .off, .unavailable:
            return nil
        case .looking:
            return String(localized: "Looking for the device that manages devices nearby…",
                          comment: "Join screen: the direct link to the other device")
        case .found:
            return String(localized: "Found a device nearby. Connecting…", comment: "Join screen: the direct link")
        case .connected:
            return String(localized: "Connected: the device that manages devices has this request. Approve it there.",
                          comment: "Join screen: the direct link")
        case .received:
            return String(localized: "The approval arrived from the device nearby.", comment: "Join screen: the direct link")
        case .declined:
            return String(localized: "The device nearby declined this request. Choose Cancel, then Ask to Join again.",
                          comment: "Join screen: the direct link")
        }
    }
}

extension NearbyApproverStatus {
    /// Add Device's line for the nearby link; nil when there is nothing to say.
    var text: String? {
        switch self {
        case .off, .unavailable:
            return nil
        case .advertising:
            return String(localized: "A new device nearby can send its request straight to this one while this screen is open.",
                          comment: "Add Device: the direct link")
        case .connected:
            return String(localized: "Connected to a new device nearby.", comment: "Add Device: the direct link")
        }
    }
}

/// `DeviceJoinError` (SempereAppCore) worded.
extension DeviceJoinError {
    var text: String {
        switch self {
        case .noMatchingRequest:
            return String(localized: "No device that asked to join has these words. Check them on the new device.")
        case .requestNotArrived:
            return String(localized: "No request with these words has arrived yet. Check the words on the new device. Its request comes through the vault's sync target, and iCloud Drive can take a minute or two to deliver it: keep this open, and Sempere approves it when it arrives.")
        case .requestArriving:
            return String(localized: "A request is on its way: the sync target's storage (such as iCloud Drive) has listed it but not delivered it yet. Keep this open, and Sempere approves it when it arrives.")
        case .notARecoveryKey:
            return String(localized: "That is not a recovery key (AGE-SECRET-KEY-PQ-1…).")
        case .rootNeeded:
            return String(localized: "This device has not opened the vault before: type the root fingerprint from the kit too (16 groups), or use the passphrase.")
        case .rootUnreadable:
            return String(localized: "The root fingerprint is 16 groups of 4 letters and digits (0–9, a–f).")
        case .otherVaultsRoot:
            return String(localized: "That root fingerprint belongs to another vault.")
        }
    }
}

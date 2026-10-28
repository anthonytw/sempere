import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The name a device gives itself in a vault's list (build 12: "When the Mac syncs, it shows up as iPad … Suppose
/// I sync to multiple iPads or Macs"): its model and a short tag, never the computer's (the owner's) name, which
/// `vault.json` would store unencrypted (review of #124).
struct ThisDeviceNameTests {
    let a = UUID(uuidString: "3F2A0000-0000-0000-0000-000000000000")
    let b = UUID(uuidString: "9C1D0000-0000-0000-0000-000000000000")

    @Test func aMacIsNamedAfterItsModel() {
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "MacBookPro18,3", vendorID: a) == "MacBook Pro 3F2A")
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "MacBookAir10,1", vendorID: b) == "MacBook Air 9C1D")
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "Macmini9,1", vendorID: a) == "Mac mini 3F2A")
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "iMac21,1", vendorID: a) == "iMac 3F2A")
        // Apple silicon models share "MacNN,N"; unknown or unreadable is "Mac".
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "Mac14,2", vendorID: a) == "Mac 3F2A")
        #expect(ThisDevice.name(kind: "mac", systemName: "iPad", hardwareModel: "", vendorID: a) == "Mac 3F2A")
        #expect(ThisDevice.name(kind: "mac", systemName: "Anthony's MacBook", hardwareModel: "", vendorID: nil) == "Mac",
                "never the system's name on a Mac")
    }

    @Test func twoIPadsDiffer() {
        #expect(ThisDevice.name(kind: "ipad", systemName: "iPad", hardwareModel: "", vendorID: a) == "iPad 3F2A")
        #expect(ThisDevice.name(kind: "ipad", systemName: "iPad", hardwareModel: "", vendorID: b) == "iPad 9C1D")
        #expect(ThisDevice.name(kind: "iphone", systemName: "iPhone", hardwareModel: "", vendorID: a) == "iPhone 3F2A")
        #expect(ThisDevice.name(kind: "ipad", systemName: "", hardwareModel: "", vendorID: nil) == "iPad")
        // A name the user gave (with the entitlement) stands as it is.
        #expect(ThisDevice.name(kind: "ipad", systemName: "Rachael's iPad", hardwareModel: "", vendorID: a) == "Rachael's iPad")
        #expect(ThisDevice.kind(isMac: true, isPhone: false) == "mac")
    }

    /// About Your Key and the tour wait while the "has not confirmed this vault" alert or Confirm Vault is up (build 12:
    /// the key notice dismissed the alert at once).
    @MainActor
    @Test func theNoticesWaitForTheVaultAlert() {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        #expect(!model.holdsOnboardingForVaultNotice)
        model.listAlert = ListAlert(problem: ListProblem(.rootUnconfirmed, "x"))
        #expect(model.holdsOnboardingForVaultNotice)
        model.dismissListAlert()
        model.confirmingVault = true
        #expect(model.holdsOnboardingForVaultNotice)
        model.confirmingVault = false
        #expect(!model.holdsOnboardingForVaultNotice)
        #expect(ListAlert(problem: ListProblem(.rootUnconfirmed, "x")).message.contains("not the recovery key"))
    }
}

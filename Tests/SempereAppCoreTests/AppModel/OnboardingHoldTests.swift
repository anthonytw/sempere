import Foundation
import Sempere
@testable import SempereAppCore
import Testing

extension AppModelSuites {
    /// About Your Key and the tour wait while the "has not confirmed this vault" alert or Confirm Vault is up (build 12:
    /// the key notice dismissed the alert at once). Moved from the app's `ThisDeviceNameTests` (wave 6 follow-up F1);
    /// the alert's words are `VaultNoticeTextTests` there.
    @MainActor
    struct OnboardingHoldTests {
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
        }
    }
}

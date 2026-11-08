import Foundation
import Sempere

// The list alert (`ListAlert`, design §4.3) and Confirm Vault, as the model holds them; their words are the app's
// (`ListAlert+Text.swift`).

extension AppModelCore {
    /// While the list alert or Confirm Vault is up, About Your Key and the tour wait (build 12: the key notice, a sheet
    /// presented a second after the unlock, dismissed the "has not confirmed this vault" alert at once, before it could
    /// be read). They show after it is closed.
    public var holdsOnboardingForVaultNotice: Bool { listAlert != nil || confirmingVault }

    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `VaultError.untrustedList`.
    public func dismissListAlert() {
        listAlert = nil
    }
}

import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// The words of the vault alert that About Your Key and the tour wait for (the rule, `holdsOnboardingForVaultNotice`, is
/// `OnboardingHoldTests` in `SempereAppCoreTests`).
struct VaultNoticeTextTests {
    @Test func theUnconfirmedVaultAlertSaysItIsNotTheRecoveryKey() {
        #expect(ListAlert(problem: ListProblem(.rootUnconfirmed, "x")).message.contains("not the recovery key"))
    }
}

import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// The in-app vault store's words (docs/design/device-first-sync.md §2, §8.1). Creating, copying in, opening and
/// removing store vaults is the model's: `VaultStoreTests` in `SempereAppCoreTests`.
@MainActor
struct VaultStoreAppTests {
    @Test func copyProgressAndRefusalsRead() {
        let progress = VaultCopyProgress(name: "Notes", stage: .copying(done: 3, total: 12))
        #expect(progress.text.contains("3 of 12"))
        #expect(progress.text.contains("“Notes”"))
        #expect(VaultCopyProgress(name: "Notes", stage: .downloading(done: 1, total: 4)).text.contains("1 of 4"))
        #expect(VaultStoreProblem(error: .alreadyInStore(vaultId: UUID(), name: "Notes")).description.contains("“Notes”"))
        #expect("\(VaultStoreProblem(error: .inUse(UUID())))" == "That vault is open. Close it first.")
        #expect(InvalidVaultName.describe(InvalidVaultName()).contains("slashes"))
        #expect(VaultListStatus(sessions: []) == VaultListStatus.onlyOnThisDevice)
    }
}

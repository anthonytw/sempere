import Foundation
import SempereAppCore

// The words of Vault Details' values (`AppModel+VaultDetails.swift` in SempereAppCore).

extension RepairProblem {
    var text: String {
        switch self {
        case .unlockFirst: return String(localized: "Open and unlock this vault to check the file under its keys.")
        }
    }
}

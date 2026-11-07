#if DEBUG
import Foundation
import Testing
import UIKit
@testable import SempereApp

/// The demo launch's appearance (`DemoLaunch`); the vault itself: `DemoVaultTests` (SempereAppCoreTests).
struct DemoLaunchTests {
    /// The shots are light whatever the simulator's or the Mac's appearance.
    @MainActor @Test func demoForcesLightAppearance() {
        let windows = [UIWindow(frame: .zero), UIWindow(frame: .zero)]
        windows[0].overrideUserInterfaceStyle = .dark
        DemoLaunch.forceLight(windows)
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .light })
    }
}
#endif

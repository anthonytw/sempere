#if DEBUG
import Foundation
import Testing
import UIKit
@testable import SempereApp

/// The demo launch's appearance and launch variables (`DemoLaunch`); the vault itself: `DemoVaultTests` (SempereAppCoreTests).
struct DemoLaunchTests {
    /// The shots are light whatever the simulator's or the Mac's appearance, unless the launch asks for dark.
    @MainActor @Test func demoForcesLightAppearanceByDefault() {
        let windows = [UIWindow(frame: .zero), UIWindow(frame: .zero)]
        windows[0].overrideUserInterfaceStyle = .dark
        DemoLaunch.forceAppearance(windows)
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .light })
        DemoLaunch.forceAppearance(windows, "light")
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .light })
    }

    @MainActor @Test func demoForcesDarkWhenAsked() {
        let windows = [UIWindow(frame: .zero), UIWindow(frame: .zero)]
        DemoLaunch.forceAppearance(windows, "dark")
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .dark })
    }

    @Test func anUnknownAppearanceFallsBackToLight() {
        #expect(DemoLaunch.appearance(nil) == .light)
        #expect(DemoLaunch.appearance("") == .light)
        #expect(DemoLaunch.appearance("Dark") == .light)
        #expect(DemoLaunch.appearance("sepia") == .light)
        #expect(DemoLaunch.appearance("dark") == .dark)
    }

    @Test func insightsModeTakesNoteMapAndOnOnly() {
        #expect(DemoLaunch.insightsMode("note") == "note")
        #expect(DemoLaunch.insightsMode("map") == "map")
        #expect(DemoLaunch.insightsMode("on") == "on")
        #expect(DemoLaunch.insightsMode("1") == nil)
        #expect(DemoLaunch.insightsMode(nil) == nil)
    }
}
#endif

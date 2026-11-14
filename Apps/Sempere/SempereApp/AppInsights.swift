import Foundation
import SempereAppCore
import SempereInsights
import SempereInsightsApple
import UIKit

/// Note Insights' platform half (`AppModelServices.insights`, docs/design/1.2-note-insights.md §3.7, §4): Apple's
/// on-device model (`SystemLanguageModel.default`, nothing else) and the sentence embedder from `SempereInsightsApple`,
/// and when this device may process: on power (on an iPhone or iPad only while charging or full), not in Low Power
/// Mode, thermal state below serious. Whether the device does the work is the vault's choice (the work device, D13),
/// never the platform's.
enum AppInsights {
    @MainActor static var services: InsightsServices {
        InsightsServices(model: { AppleInsightsProviders.model() }, embedder: { AppleInsightsProviders.embedder() },
                         powerWindow: { powerWindow }, maxGraphNotes: maxGraphNotes)
    }

    /// The most notes the related graph takes here (review of #50, L7): its three n x n matrices of doubles are about
    /// 54 MB at 1 500 notes, the iPhone's bound; 4 000 notes (384 MB) on an iPad or a Mac.
    @MainActor static var maxGraphNotes: Int { Platform.isPhone ? 1500 : 4000 }

    @MainActor static var powerWindow: Bool {
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled, info.thermalState != .serious, info.thermalState != .critical else { return false }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .charging, .full: return true
        // A Mac without a battery reports no state: it is on power.
        case .unknown: return Platform.isMac
        case .unplugged: return false
        @unknown default: return false
        }
    }
}

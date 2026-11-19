import Foundation
#if targetEnvironment(macCatalyst) && canImport(IOKit)
import IOKit.ps
#endif
import SempereAppCore
import SempereInsights
import SempereInsightsApple
import UIKit

/// Note Insights' platform half (`AppModelServices.insights`, docs/design/1.2-note-insights.md §3.7, §4): Apple's
/// on-device model (`SystemLanguageModel.default`, nothing else) and the sentence embedder from `SempereInsightsApple`,
/// and when this device may process: on power (on an iPhone or iPad only while charging or full), not in Low Power
/// Mode, thermal state below serious. Which device does the work is nobody's choice (D21: any capable device does),
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
        if let ac = macOnExternalPower { return ac }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .charging, .full: return true
        // Unknown is not taken for power (the safe side: "Process Now" still runs).
        case .unknown, .unplugged: return false
        @unknown default: return false
        }
    }

    /// On a Mac, whether it runs on external power (IOKit's power sources: no time limit means AC, also on a Mac
    /// without a battery); nil elsewhere.
    static var macOnExternalPower: Bool? {
        #if targetEnvironment(macCatalyst) && canImport(IOKit)
        return IOPSGetTimeRemainingEstimate() == -2.0   // kIOPSTimeRemainingUnlimited
        #else
        return nil
        #endif
    }
}

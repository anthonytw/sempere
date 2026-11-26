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
        var services = InsightsServices(model: { AppleInsightsProviders.model() }, embedder: { AppleInsightsProviders.embedder() },
                                        powerWindow: { powerWindow }, maxGraphNotes: maxGraphNotes)
        services.powerState = { powerState }
        // Ask names the language of a question (docs/design/1.3-ask.md §3.1).
        services.detectLanguage = { AppleInsightsProviders.detectLanguage($0, among: $1) }
        services.languageHypotheses = { AppleInsightsProviders.languageHypotheses($0, among: $1, likely: $2) }
        services.nameTagger = { AppleInsightsProviders.nameKeys($0, language: $1) }
        return services
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

    /// What the device says about its power now, for the foreground's gate (`InsightsPowerGate`): on battery too, with
    /// enough charge. Battery monitoring is switched on here (the charge reads -1 without it); a Mac or a simulator
    /// reports no charge, so it never counts as "enough".
    @MainActor static var powerState: InsightsPowerState {
        let info = ProcessInfo.processInfo
        let thermal: InsightsThermal
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let source: InsightsPowerState.Source
        if let ac = macOnExternalPower {
            source = ac ? .external : .battery
        } else {
            switch device.batteryState {
            case .charging, .full: source = .external
            case .unplugged: source = .battery
            // Unknown is not taken for power (the safe side: "Process Now" still runs).
            case .unknown: source = .unknown
            @unknown default: source = .unknown
            }
        }
        return InsightsPowerState(source: source, batteryLevel: level, lowPowerMode: info.isLowPowerModeEnabled, thermal: thermal)
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

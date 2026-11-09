import Foundation
import Sempere
import UIKit
import SempereAppCore

/// Where the app is running. The Mac behavior (menus, windows, pointer input)
/// is gated on this at run time, or on `#if targetEnvironment(macCatalyst)`
/// where the code only builds there, so the iPad is unchanged.
enum Platform {
    /// True for the Mac Catalyst build.
    static var isMac: Bool { ProcessInfo.processInfo.isMacCatalystApp }
    /// True on an iPhone: the phone layouts (`PhoneLayout.swift`) apply. Never true on an iPad or a Mac.
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

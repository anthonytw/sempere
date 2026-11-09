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
    /// True on an iPhone: the reader layouts (`PhoneLayout.swift`) apply. Never true on an iPad or a Mac.
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

/// The pointer shown over the canvas with a mouse or trackpad.
enum PointerCursor {
    /// Smallest and largest diameter, screen points.
    static let range: ClosedRange<Double> = 6...64

    /// Diameter of the circle that shows where an ink tool of `toolWidth`
    /// (page points) draws at `zoom`; never smaller than a visible dot or
    /// larger than a reasonable cursor.
    static func diameter(toolWidth: Double, zoom: Double) -> Double {
        guard toolWidth.isFinite, zoom.isFinite, toolWidth > 0, zoom > 0 else { return range.lowerBound }
        return min(max(toolWidth * zoom, range.lowerBound), range.upperBound)
    }
}

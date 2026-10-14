import OSLog
import SwiftUI

/// `@Environment(AppModel.self)` that cannot trap: SwiftUI traps when a view
/// reads an Observable object no ancestor provides, and on Mac Catalyst a view
/// can be updated outside its window's environment (build 8 / Mac build 5
/// crashed at launch right after the vault opened: "No Observable object of
/// type AppModel found"). The app has one model, so a view without one gets
/// it (`AppModel.current`) and the site is logged to find the view.
@MainActor
@propertyWrapper
struct AppModelEnvironment: DynamicProperty {
    @Environment(AppModel.self) private var injected: AppModel?
    private let site: StaticString
    private let line: UInt

    init(file: StaticString = #fileID, line: UInt = #line) {
        site = file
        self.line = line
    }

    var wrappedValue: AppModel {
        if let injected { return injected }
        guard let shared = AppModel.current else {
            preconditionFailure("No AppModel in the environment at \(site):\(line), and none created yet")
        }
        Self.fallbacks += 1
        environmentLog.fault("AppModel not in the environment at \(String(describing: self.site), privacy: .public):\(self.line); using the app's")
        return shared
    }

    /// Reads that found no injected model and used `AppModel.current`. The
    /// test host's `SempereApp.init` sets `current`, so a view a test forgot
    /// to inject no longer traps there: tests check this count instead.
    static var fallbacks = 0
}

private let environmentLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "environment")

/// The other app-wide objects every window injects (`appEnvironment`): one
/// instance each in the app (`current`, set in `SempereApp.init`).
@MainActor
protocol AppWideObject: AnyObject, Observable {
    static var current: Self? { get }
}

extension VaultLibrary: AppWideObject {
    /// The app's vault library (`SempereApp.init`); nil in tests that build their own.
    @MainActor static var current: VaultLibrary?
}

extension RememberedKeys: AppWideObject {
    /// The app's remembered keys (`SempereApp.init`); nil in tests that build their own.
    @MainActor static var current: RememberedKeys?
}

/// `@Environment(VaultLibrary.self)` / `@Environment(RememberedKeys.self)`
/// that cannot trap, as `AppModelEnvironment` does for the model: a view
/// updated outside its window's environment reads all three (`SidebarView`
/// reads the model and the keys in one body), so all three fall back.
@MainActor
@propertyWrapper
struct AppEnvironmentObject<Object: AppWideObject>: DynamicProperty {
    @Environment(Object.self) private var injected: Object?
    private let site: StaticString
    private let line: UInt

    init(file: StaticString = #fileID, line: UInt = #line) {
        site = file
        self.line = line
    }

    var wrappedValue: Object {
        if let injected { return injected }
        guard let shared = Object.current else {
            preconditionFailure("No \(Object.self) in the environment at \(site):\(line), and none created yet")
        }
        AppModelEnvironment.fallbacks += 1
        environmentLog.fault("\(String(describing: Object.self), privacy: .public) not in the environment at \(String(describing: self.site), privacy: .public):\(self.line); using the app's")
        return shared
    }
}

extension AppModel {
    /// The app's model (`SempereApp.init`); nil in tests that build their own.
    @MainActor static var current: AppModel?
}

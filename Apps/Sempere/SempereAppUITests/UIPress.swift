import XCTest

/// One press for the iPad and the Mac: a tap, or on Mac Catalyst a click (a synthesized tap does not reach SwiftUI's
/// toolbar buttons, settings rows or menus there).
extension XCUIElement {
    @MainActor
    func press() {
        #if targetEnvironment(macCatalyst)
        click()
        #else
        tap()
        #endif
    }
}

extension XCUICoordinate {
    @MainActor
    func press() {
        #if targetEnvironment(macCatalyst)
        click()
        #else
        tap()
        #endif
    }
}

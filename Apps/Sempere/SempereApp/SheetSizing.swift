import CoreGraphics

/// Minimum sizes for sheets that give themselves room on an iPad or a Mac
/// (a form sheet there can be narrow). On an iPhone the sheet is the screen:
/// a minimum wider than it (390 points on most phones) would push the form
/// off the side, so it gets none.
enum SheetSizing {
    static func minWidth(_ width: CGFloat, isPhone: Bool) -> CGFloat? {
        isPhone ? nil : width
    }
}

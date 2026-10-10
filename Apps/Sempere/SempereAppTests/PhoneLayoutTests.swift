import Foundation
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// The iPhone reader (`PhoneLayout.swift`): the stack navigation rules, the
/// reading mode of the canvas at iPhone sizes, and that the iPad keeps
/// drawing. Pure rules run on every destination; the view checks use the
/// destination's idiom, so the iPhone simulator run in CI exercises the phone
/// side and the iPad run the other.
struct CompactNavigationTests {
    @Test func poppingToTheListDropsTheNoteOnly() {
        #expect(CompactNavigation.clear(whenShowing: .content) == .init(note: true, sidebar: false))
    }

    @Test func poppingToTheSidebarDropsBothSelections() {
        #expect(CompactNavigation.clear(whenShowing: .sidebar) == .init(note: true, sidebar: true))
    }

    @Test func showingTheNoteDropsNothing() {
        #expect(CompactNavigation.clear(whenShowing: .detail) == .init())
    }

    @Test func aSelectedNoteOpensTheDetailColumn() {
        let id = UUID()
        #expect(CompactNavigation.column(note: id, sidebar: .allNotes, current: .sidebar) == .detail)
        #expect(CompactNavigation.column(note: id, sidebar: nil, current: .content) == .detail)
        #expect(CompactNavigation.column(note: id, sidebar: nil, current: .detail) == nil)   // already there
    }

    @Test func aSidebarSelectionOpensTheListOnlyFromTheSidebar() {
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .sidebar) == .content)
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .content) == nil)
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .detail) == nil)
        #expect(CompactNavigation.column(note: nil, sidebar: nil, current: .sidebar) == nil)
    }

}

/// What a back swipe does to the model (`AppModel.didShowCompactColumn`, the
/// handler `RootView` runs on an iPhone).
@MainActor
struct CompactBackTests {
    static let lecture = AppModelTests.lecture

    /// Back to the list: the note is deselected (so its row can be tapped
    /// again), its editor closed and its pending ink saved; the notebook stays.
    /// Back to the notebooks: the sidebar selection goes too.
    @Test func backSavesTheNoteAndClearsTheSelectionsItLeft() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.sidebarSelection = .allNotes
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 500)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        let vault = try #require(model.vault)
        let before = try vault.reconstruct(noteId: Self.lecture).pages.first { $0.id == page.id }?.strokes.count ?? 0

        await model.didShowCompactColumn(.content)
        #expect(model.selectedNoteID == nil)
        #expect(model.editor == nil)
        #expect(model.sidebarSelection == .allNotes)
        let after = try vault.reconstruct(noteId: Self.lecture).pages.first { $0.id == page.id }?.strokes.count ?? 0
        #expect(after == before + 1, "the stroke drawn before going back was saved")

        // The same row again: a change, so the stack pushes the note.
        #expect(CompactNavigation.column(note: Self.lecture, sidebar: model.sidebarSelection, current: .content) == .detail)

        await model.didShowCompactColumn(.sidebar)
        #expect(model.sidebarSelection == nil)
        await model.didShowCompactColumn(.detail)   // nothing to drop
        #expect(model.sidebarSelection == nil && model.selectedNoteID == nil)
        model.close()
    }
}

struct PhoneReadingTests {
    @Test func aPhoneReadsUntilAnnotationIsOn() {
        #expect(PhoneReading.drawingSuspended(isPhone: true, annotating: false))
        #expect(!PhoneReading.drawingSuspended(isPhone: true, annotating: true))
    }

    @Test func theIPadAndTheMacNeverSuspendDrawing() {
        #expect(!PhoneReading.drawingSuspended(isPhone: false, annotating: false))
        #expect(!PhoneReading.drawingSuspended(isPhone: false, annotating: true))
    }

    @Test func thePhonePaletteIsAlwaysTheShortOne() {
        #expect(PhoneReading.paletteCompact(isPhone: true, stored: false))
        #expect(!PhoneReading.paletteCompact(isPhone: false, stored: false))
        #expect(PhoneReading.paletteCompact(isPhone: false, stored: true))
    }

    @Test func annotationStartsOffForTheNextNote() {
        #expect(!PhoneReading.annotatingAfterNoteChange())
    }

    /// The footer below a finite page never writes while an iPhone is reading.
    @Test func theFooterAddsAPageOnlyWhenTheNoteIsBeingWritten() {
        #expect(PhoneReading.footer(infinite: false, isLast: true, readOnly: false, drawingSuspended: false) == .addPage)
        #expect(PhoneReading.footer(infinite: false, isLast: true, readOnly: false, drawingSuspended: true) == .none)
        #expect(PhoneReading.footer(infinite: false, isLast: true, readOnly: true, drawingSuspended: false) == .none)
        #expect(PhoneReading.footer(infinite: false, isLast: false, readOnly: false, drawingSuspended: true) == .nextPage)
        #expect(PhoneReading.footer(infinite: true, isLast: false, readOnly: false, drawingSuspended: false) == .none)
    }

    @Test func deviceNamesInTheKeyTexts() {
        #expect(RememberedKeys.name(isMac: false, isPhone: false) == "this iPad")
        #expect(RememberedKeys.name(isMac: false, isPhone: true) == "this iPhone")
        #expect(RememberedKeys.name(isMac: true, isPhone: false) == "this Mac")
    }
}

/// The canvas in windows of iPhone sizes (points): 6.9" Pro Max portrait, 6.3" portrait,
/// the small SE, and a landscape one.
@MainActor
@Suite(.serialized)
struct PhoneCanvasTests {
    static let sizes: [CGSize] = [CGSize(width: 440, height: 956), CGSize(width: 402, height: 874),
                                  CGSize(width: 375, height: 667), CGSize(width: 956, height: 440)]

    static func host(size: CGSize, pageSize: PageSize = PageSize(width: 612, height: 792, infinite: false, breakHeight: 792))
        -> (UIWindow, PageCanvasHost) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: pageSize)
        host.layoutIfNeeded()
        return (window, host)
    }

    @Test func thePageFitsTheWidthAtEveryPhoneSize() {
        for size in Self.sizes {
            let (window, host) = Self.host(size: size)
            #expect(abs(host.canvas.zoomScale - size.width / 612) < 0.0005, "\(size)")
            #expect(host.canvas.minimumZoomScale == host.canvas.zoomScale)
            #expect(abs(host.canvas.maximumZoomScale - host.canvas.minimumZoomScale * 4) < 0.0005)
            window.isHidden = true
        }
    }

    @Test func readingModeLeavesTheFingersToScrollAndZoom() {
        let (window, host) = Self.host(size: Self.sizes[0])
        host.drawingSuspended = true
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        #expect(host.canvas.isScrollEnabled)
        #expect(host.canvas.pinchGestureRecognizer?.isEnabled ?? true)
        #expect(host.canvas.panGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func annotatingTurnsFingerDrawingBackOn() {
        let (window, host) = Self.host(size: Self.sizes[1])
        host.drawingSuspended = true
        host.drawingSuspended = false
        #expect(host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func aReadOnlyNoteStaysUndrawableWhateverTheMode() {
        let (window, host) = Self.host(size: Self.sizes[2])
        host.isReadOnly = true
        host.drawingSuspended = false
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    /// Fingers draw on a phone (it has no Pencil); the iPad keeps the system's
    /// Pencil preference (`.default`) and the Mac draws with the pointer.
    @Test func theDrawingPolicyFollowsTheDevice() {
        let (window, host) = Self.host(size: Self.sizes[0])
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: #expect(host.canvas.drawingPolicy == .anyInput)
        case .pad where !ProcessInfo.processInfo.isMacCatalystApp: #expect(host.canvas.drawingPolicy == .default)
        default: #expect(host.canvas.drawingPolicy == .anyInput)
        }
        #expect(!(Platform.isPhone && Platform.isMac))
        window.isHidden = true
    }

    @Test func theIPadCanvasIsNotSuspendedByDefault() {
        let (window, host) = Self.host(size: CGSize(width: 1024, height: 1366))
        #expect(!host.drawingSuspended)
        #expect(host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func aFinitePageEndsWithRoomForTheFooterAtPhoneWidth() {
        let (window, host) = Self.host(size: Self.sizes[0])
        host.footer = .nextPage
        host.layoutIfNeeded()
        let z = host.canvas.zoomScale
        #expect(host.canvas.contentSize.height >= (792 * z) + PageExtent.footerScreenHeight - 0.5)
        #expect(!host.footerButton.isHidden)
        window.isHidden = true
    }
}

/// The root view hosted at an iPhone size: it must lay out without trapping,
/// on the welcome screen as well as with an unlocked vault.
@MainActor
@Suite(.serialized)
struct PhoneRootTests {
    static func host(_ model: AppModel) -> (UIWindow, UIViewController) {
        let controller = UIHostingController(rootView: RootView()
            .environment(model).environment(VaultLibrary(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("recents.json"))).environment(RememberedKeys(store: FakeKeyStore())))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    @Test func theWelcomeScreenLaysOutAtPhoneWidth() {
        let model = AppModel()
        let (window, controller) = Self.host(model)
        #expect(controller.view.bounds.width == 402)
        #expect(model.phase == .noVault)
        window.isHidden = true
    }

    /// The split view with an unlocked vault and a note open, at phone width.
    @Test func anUnlockedVaultWithANoteLaysOutAtPhoneWidth() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let (window, controller) = Self.host(model)
        model.selectedNoteID = AppModelTests.lecture
        await model.showSelectedNote()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(controller.view.bounds.width == 402)
        #expect(model.phase == .unlocked)
        #expect(model.editor?.noteID == AppModelTests.lecture)
        window.isHidden = true
        model.close()
    }
}

/// TestFlight build 6: iCloud Drive missing from the picker on an iPhone is a
/// device setting; the welcome and new-vault screens say where to turn it on.
@MainActor
struct ICloudDriveHelpTests {
    @Test func theStepsNameTheDeviceSettingAndTheFilesLocation() {
        let phone = ICloudDriveHelp.steps(device: "iPhone")
        #expect(phone.first?.contains("Settings › your name › iCloud › iCloud Drive") == true)
        #expect(phone.first?.contains("Sync this iPhone") == true)
        #expect(phone.contains { $0.contains("Browse") && $0.contains("Edit") })
        #expect(ICloudDriveHelp.steps(device: "iPad").first?.contains("Sync this iPad") == true)
        #expect(ICloudDriveHelp.deviceName == (Platform.isPhone ? "iPhone" : "iPad"))
        #expect(ICloudDriveHelp.isShown == !Platform.isMac)
    }
}

/// Review of #135: the device-key and Choose Devices to Keep sheets asked for 460 points of
/// width, more than an iPhone has (390), so their forms ran off the screen there.
struct SheetSizingTests {
    @Test func aPhoneSheetHasNoMinimumWidth() {
        #expect(SheetSizing.minWidth(460, isPhone: true) == nil)
        #expect(SheetSizing.minWidth(460, isPhone: false) == 460)
    }
}

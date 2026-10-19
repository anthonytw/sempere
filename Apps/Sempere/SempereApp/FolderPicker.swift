import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let pickerLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "folderPicker")

extension View {
    /// Presents the system folder picker with New Folder: for every pick of a folder the app
    /// writes into (a new vault's location, a backup or restore folder, an export folder). A pick
    /// that only opens something that exists (a vault, a file to import) keeps `fileImporter`.
    ///
    /// On a Mac this is AppKit's open panel with `canCreateDirectories` on (`MacFolderPanel`):
    /// UIKit's folder picker there is that panel with New Folder off, and neither `fileImporter`
    /// nor `UIDocumentPickerViewController` has a switch for it. Elsewhere it is the system's
    /// document picker in folder mode, which offers New Folder itself.
    func folderPicker(isPresented: Binding<Bool>, onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented, onCompletion: onCompletion))
    }
}

private struct FolderPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onCompletion: (Result<URL, Error>) -> Void

    func body(content: Content) -> some View {
        if MacFolderPanel.isAvailable {
            content.onChange(of: isPresented) { _, shown in
                guard shown else { return }
                // Like `fileImporter`, a cancel calls nothing.
                let started = MacFolderPanel.run { url in
                    isPresented = false
                    if let url { onCompletion(.success(url)) }
                }
                if !started { isPresented = false }
            }
        } else {
            content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], onCompletion: onCompletion)
        }
    }
}

/// AppKit's `NSOpenPanel` from the Catalyst app, reached through the Objective-C runtime (the
/// app cannot link AppKit; AppKit is loaded in every Catalyst process). Set up to choose one
/// folder, with New Folder. In the sandbox the panel runs in the system's open-panel service and
/// grants access to what the user chose, as UIKit's picker does (it is the same panel); the URL
/// is used and bookmarked like a picked one.
@MainActor
enum MacFolderPanel {
    /// `NSModalResponseOK`.
    private static let responseOK = 1

    private static var panelClass: AnyClass? {
        Platform.isMac ? NSClassFromString("NSOpenPanel") : nil
    }

    /// True on a Mac where AppKit's open panel can be used.
    static var isAvailable: Bool {
        guard let cls = panelClass else { return false }
        return (cls as AnyObject).responds(to: NSSelectorFromString("openPanel"))
    }

    /// A new open panel set up for one folder with New Folder; nil without AppKit.
    static func makePanel() -> NSObject? {
        guard let cls = panelClass,
              let panel = (cls as AnyObject).perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        panel.setValue(true, forKey: "canChooseDirectories")
        panel.setValue(false, forKey: "canChooseFiles")
        panel.setValue(true, forKey: "canCreateDirectories")
        panel.setValue(false, forKey: "allowsMultipleSelection")
        panel.setValue(String(localized: "Choose", comment: "Button of the Mac's folder panel"), forKey: "prompt")
        return panel
    }

    /// Shows the panel (a sheet on the key window, else a window of its own) and calls `done`
    /// with the chosen folder, or nil when it was canceled. False when there is no panel.
    @discardableResult
    static func run(_ done: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard let panel = makePanel() else { return false }
        let handler: @convention(block) (Int) -> Void = { response in
            let url = response == responseOK ? (panel.value(forKey: "URLs") as? [URL])?.first : nil
            MainActor.assumeIsolated { done(url) }
        }
        if let window = keyWindow() {
            let sel = NSSelectorFromString("beginSheetModalForWindow:completionHandler:")
            typealias Sheet = @convention(c) (NSObject, Selector, NSObject, @convention(block) (Int) -> Void) -> Void
            unsafeBitCast(panel.method(for: sel), to: Sheet.self)(panel, sel, window, handler)
        } else {
            let sel = NSSelectorFromString("beginWithCompletionHandler:")
            typealias Begin = @convention(c) (NSObject, Selector, @convention(block) (Int) -> Void) -> Void
            unsafeBitCast(panel.method(for: sel), to: Begin.self)(panel, sel, handler)
        }
        pickerLog.debug("folder panel shown")
        return true
    }

    /// `NSApp.keyWindow`, when there is one.
    private static func keyWindow() -> NSObject? {
        guard let app = NSClassFromString("NSApplication") as AnyObject?,
              app.responds(to: NSSelectorFromString("sharedApplication")),
              let shared = app.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        return shared.value(forKey: "keyWindow") as? NSObject
    }
}

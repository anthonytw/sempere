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
    ///
    /// `purpose` says what may be chosen (`PickedFolderRules`): never a folder inside a vault or a backup, and for a
    /// sync folder never a backup. A pick that breaks the rule is refused with an alert, and `onCompletion` is not
    /// called.
    func folderPicker(isPresented: Binding<Bool>, purpose: PickedFolderRules.Purpose = .writeFolder,
                      onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented, purpose: purpose, onCompletion: onCompletion))
    }

    /// Presents the picker of Open Vault…: a vault folder (`.sempere` or not), a backup, or a folder holding one
    /// (`VaultLocator`). On a Mac this is AppKit's open panel choosing one folder, without New Folder:
    /// UIKit's picker there, given the vault type and `public.folder`, let the user go into folders
    /// but not choose one, so neither a `.sempere` vault nor a plain folder could be opened (TestFlight
    /// 1.0.0 (8)). Elsewhere it is `fileImporter` with `UTType.vaultPickerTypes`. Nothing inside a vault or a
    /// backup can be chosen (`PickedFolderRules`).
    func vaultPicker(isPresented: Binding<Bool>, onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented, purpose: .openVault, onCompletion: onCompletion))
    }
}

private struct FolderPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let purpose: PickedFolderRules.Purpose
    let onCompletion: (Result<URL, Error>) -> Void
    /// Why the last pick was refused (`PickedFolderRules.problem`).
    @State private var refusal: String?

    func body(content: Content) -> some View {
        picker(content)
            .alert(String(localized: "Choose Another Folder", comment: "Title of the alert when a folder pick is refused"),
                   isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
    }

    @ViewBuilder private func picker(_ content: Content) -> some View {
        if MacFolderPanel.isAvailable {
            content.onChange(of: isPresented) { _, shown in
                guard shown else { return }
                // Like `fileImporter`, a cancel calls nothing.
                let started = MacFolderPanel.run(purpose: purpose) { url in
                    isPresented = false
                    guard let url else { return }
                    // The panel's grant is in place now: what the delegate could not read is read under it.
                    let scoped = url.startAccessingSecurityScopedResource()
                    let kind = MacPanelRules.kind(of: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    guard PickedFolderRules.accepts(kind, at: url) else {
                        pickerLog.info("folder pick refused: not a plain folder")
                        refusal = PickedFolderRules.notAFolder
                        return
                    }
                    deliver(.success(url))
                }
                if !started { isPresented = false }
            }
        } else {
            content.fileImporter(isPresented: $isPresented,
                                 allowedContentTypes: PickedFolderRules.documentPickerTypes(for: purpose),
                                 onCompletion: deliverFromDocumentPicker)
        }
    }

    /// The document picker's pick: its types let a package through, for a vault or a backup iCloud Drive holds as one
    /// (`PickedFolderRules.isFolderLike`); any other package is refused here.
    private func deliverFromDocumentPicker(_ result: Result<URL, Error>) {
        if case .success(let url) = result, let refused = PickedFolderRules.documentPickerRefusal(url) {
            pickerLog.info("folder pick refused: a package")
            refusal = refused
            return
        }
        deliver(result)
    }

    /// Hands a pick on, unless it breaks the purpose's rule: then the alert says what to choose instead (on the
    /// iPhone and iPad the picker has no other way; the Mac's panel refuses it before).
    private func deliver(_ result: Result<URL, Error>) {
        if case .success(let url) = result, let problem = PickedFolderRules.problem(url, for: purpose) {
            pickerLog.info("folder pick refused")
            refusal = problem
            return
        }
        onCompletion(result)
    }
}

extension PickedFolderRules {
    /// The document picker's types for `purpose`: a folder an export writes into is a plain folder (a vault or a
    /// backup is never one, `problem`); the others let a vault or a backup held as a package through.
    static func documentPickerTypes(for purpose: Purpose) -> [UTType] {
        switch purpose {
        case .openVault: UTType.vaultPickerTypes
        case .syncFolder, .writeFolder: UTType.folderPickerTypes
        case .exportFolder: [.folder]
        }
    }

    /// Why a pick from the iPhone's and iPad's document picker is refused before anything reads it (its types let a
    /// package through, `UTType.vaultPickerTypes`): any package other than a vault or a backup; nil when it is taken.
    /// Read under the pick's security scope.
    static func documentPickerRefusal(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        let kind = MacPanelRules.kind(of: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        return acceptsFromDocumentPicker(kind, at: url) ? nil : notAFolder
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

    /// A new open panel set up for one folder (with New Folder unless it opens a vault); nil without AppKit.
    ///
    /// `canChooseFiles` is on, and the delegate (`MacPanelRules`) enables folders only: the panel counts a folder of
    /// a type the app declares as a document (`.sempere`, `CFBundleDocumentTypes`) as a file, so with files off it
    /// greyed out every vault (TestFlight build 10), while a `.sempere-backup` (no document type) stayed choosable.
    /// The delegate also keeps everything inside a vault or a backup from being chosen (`PickedFolderRules`).
    static func makePanel(purpose: PickedFolderRules.Purpose = .writeFolder) -> NSObject? {
        guard let cls = panelClass,
              let panel = (cls as AnyObject).perform(NSSelectorFromString("openPanel"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let canCreateFolders = purpose != .openVault
        panel.setValue(true, forKey: "canChooseDirectories")
        panel.setValue(true, forKey: "canChooseFiles")
        panel.setValue(false, forKey: "treatsFilePackagesAsDirectories")
        panel.setValue(canCreateFolders, forKey: "canCreateDirectories")
        panel.setValue(false, forKey: "allowsMultipleSelection")
        panel.setValue(canCreateFolders ? String(localized: "Choose", comment: "Button of the Mac's folder panel")
                                        : String(localized: "Open", comment: "Button of the Mac's Open Vault panel"),
                       forKey: "prompt")
        return panel
    }

    /// Shows the panel (a sheet on the key window, else a window of its own) and calls `done`
    /// with the chosen folder, or nil when it was canceled. False when there is no panel.
    @discardableResult
    static func run(purpose: PickedFolderRules.Purpose = .writeFolder, _ done: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard let panel = makePanel(purpose: purpose) else { return false }
        begin(panel, delegate: MacPanelRules(purpose: purpose)) { response in
            done(response ? (panel.value(forKey: "URLs") as? [URL])?.first : nil)
        }
        pickerLog.debug("folder panel shown")
        return true
    }

    /// Shows an open or save `panel` with `delegate` (a sheet on the key window, else a window of its own); `done`
    /// gets whether the user confirmed it. The panel's delegate is weak: the handler keeps it until the panel is done.
    static func begin(_ panel: NSObject, delegate: NSObject, _ done: @escaping @MainActor (Bool) -> Void) {
        panel.setValue(delegate, forKey: "delegate")
        let handler: @convention(block) (Int) -> Void = { response in
            withExtendedLifetime(delegate) {}
            MainActor.assumeIsolated { done(response == responseOK) }
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

/// The open panel's delegate (`NSOpenSavePanelDelegate`, answered by selector: the app cannot link AppKit). The panel
/// asks it on the main thread, also when it runs in the sandbox's open-panel service.
final class MacPanelRules: NSObject {
    let purpose: PickedFolderRules.Purpose

    init(purpose: PickedFolderRules.Purpose) {
        self.purpose = purpose
    }

    /// Whether the item can be chosen (greyed out otherwise; folders stay open to browse).
    @objc(panel:shouldEnableURL:)
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        PickedFolderRules.canChoose(url, kind: Self.kind(of: url), for: purpose)
    }

    /// The panel's last check of the choice (the folder the user went into counts too): refused with the reason,
    /// which the panel shows, and the panel stays open.
    @objc(panel:validateURL:error:)
    func panel(_ sender: Any, validate url: URL) throws {
        if let problem = PickedFolderRules.problem(url, for: purpose) {
            throw NSError(domain: "io.github.anthonytw.sempere.folderPicker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: problem])
        }
        // Only what is known to be no folder (a vault or a backup held as a package is one: `isFolderLike`); an item
        // not readable yet is checked after the pick (`accepts`).
        let kind = Self.kind(of: url)
        if kind == .file || (kind == .package && !PickedFolderRules.isFolderLike(url, kind: kind)) {
            throw NSError(domain: "io.github.anthonytw.sempere.folderPicker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: PickedFolderRules.notAFolder])
        }
    }

    /// What `url` is (`isDirectory`, `isPackage`, and a type conforming to `com.apple.package`); `.unknown` when its
    /// resource values cannot be read.
    static func kind(of url: URL) -> PickedFolderRules.ItemKind {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey]),
              let isDirectory = values.isDirectory else { return .unknown }
        guard isDirectory else { return .file }
        if values.isPackage == true || values.contentType?.conforms(to: .package) == true { return .package }
        return .folder
    }
}

/// AppKit's `NSSavePanel` for Save… of an export on a Mac (`ExportHandOff.save`), through the Objective-C runtime like
/// `MacFolderPanel`, with a delegate that keeps exported files out of vaults and backups (`MacSaveRules`). Owner's test
/// of build 12: UIKit's export picker saved a note's PDF into a `.sempere-backup`, and saving into a `.sempere` froze
/// the app; with the app's own panel the refusal is the panel's (an alert on the panel) and the app copies the file.
@MainActor
enum MacSavePanel {
    /// True on a Mac where AppKit's save panel can be used.
    static var isAvailable: Bool {
        guard Platform.isMac, let cls = NSClassFromString("NSSavePanel") else { return false }
        return (cls as AnyObject).responds(to: NSSelectorFromString("savePanel"))
    }

    /// A save panel proposing `fileName`, with New Folder, never going into a package; nil without AppKit.
    static func makePanel(fileName: String) -> NSObject? {
        guard isAvailable, let cls = NSClassFromString("NSSavePanel"),
              let panel = (cls as AnyObject).perform(NSSelectorFromString("savePanel"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        panel.setValue(fileName, forKey: "nameFieldStringValue")
        panel.setValue(true, forKey: "canCreateDirectories")
        panel.setValue(false, forKey: "treatsFilePackagesAsDirectories")
        return panel
    }

    /// Shows the panel and calls `done` with the file's URL (the panel asked before replacing a file there), or nil
    /// when it was canceled. False when there is no panel.
    @discardableResult
    static func run(fileName: String, _ done: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard let panel = makePanel(fileName: fileName) else { return false }
        MacFolderPanel.begin(panel, delegate: MacSaveRules()) { confirmed in
            done(confirmed ? panel.value(forKey: "URL") as? URL : nil)
        }
        return true
    }
}

/// The save panel's delegate (`NSOpenSavePanelDelegate`, by selector): vaults and backups are greyed out (the panel
/// does not go into them), and a file inside one, or named like one, is refused with words the panel shows.
final class MacSaveRules: NSObject {
    @objc(panel:shouldEnableURL:)
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath()
        return !PickedFolderRules.isHolderName(url) && PickedFolderRules.enclosingNamedHolder(of: url) == nil
    }

    @objc(panel:validateURL:error:)
    func panel(_ sender: Any, validate url: URL) throws {
        if let problem = PickedFolderRules.saveProblem(url) {
            throw NSError(domain: "io.github.anthonytw.sempere.savePanel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: problem])
        }
    }
}

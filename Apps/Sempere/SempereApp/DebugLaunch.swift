#if DEBUG
import Age
import Foundation
import Sempere
import UIKit

/// Debug builds only: open a vault, unlock it and show a note straight from
/// launch environment variables, without the folder picker, so a simulator
/// run can be scripted (`xcrun simctl launch` with `SIMCTL_CHILD_` prefixes):
///
/// - `SEMPERE_DEBUG_VAULT`: path of a `.sempere` folder.
/// - `SEMPERE_DEBUG_IDENTITY`: path of a device key file (`DeviceKeys`, read-write), or of a plain
///   age identity file (the recovery key: read-only).
/// - `SEMPERE_DEBUG_NOTE`: note id (or a unique prefix of it) to open.
/// - `SEMPERE_DEBUG_SCROLL_Y`: page y (points) to scroll the canvas to.
/// - `SEMPERE_DEBUG_ZOOM`: zoom as a multiple of the fit-width zoom.
/// - `SEMPERE_DEBUG_SNAPSHOT`: path to write a PNG of the canvas to, once shown.
/// - `SEMPERE_DEMO`: a synthetic vault for the App Store screenshots (`DemoLaunch`).
/// - `SEMPERE_DEBUG_FRESH`: start as a first launch (`resetForFreshLaunch`).
/// - `SEMPERE_DEBUG_ONBOARDING`: show the key notice and the quick tour by themselves, which
///   every other scripted launch skips (`OnboardingPolicy.automatic`).
/// - `SEMPERE_DEBUG_OWNER_CHECK`: `pass`, `fail` or `cancel` instead of Face ID, Touch ID or the
///   password whenever the app asks for the owner (`SystemOwnerAuthenticator`: Save Key…, the
///   recovery kit, key changes), so a UI test can reach what is behind it (`KeyShareMacUITests`).
///   The remembered-key unlock (`RememberedKeys`, the Keychain) is not affected.
/// - `SEMPERE_DEBUG_LEFTOVERS`: at launch, before anything is purged, look for plaintext a
///   previous run left in the container (decrypted attachments, staged exports and imports,
///   a staged key file) and for the given text (a demo note title) in the saved window state,
///   preferences and Application Support, and show the counts in the app's alert
///   (`leftoverReport`, `QuitPurgeMacUITests`); that launch opens no vault.
/// - `SEMPERE_DEBUG_IMPORT_PICK`: `COUNT:PATH`. File ▸ Import from … skips the open panel and
///   imports COUNT copies of the note file at PATH, in nested folders under the app's temporary
///   directory, as if that folder had been picked (`importPick`, `MacImportUITests`: the panel
///   cannot open a folder in the test runner's container).
///
/// - `SEMPERE_DEBUG_PICK_VAULT`: `demo`. "Open Vault…" skips the folder picker (another process, which a
///   UI test cannot drive on the iPad) and takes the demo vault (`DemoVault`, its key stored under
///   `SEMPERE_DEMO_PASSPHRASE`), built in the app's temporary folder once per launch, as if it had been
///   picked: the copy-in itself is the real one (`vaultPick`, `VaultStoreUITests`).
///
/// Release builds compile none of this.
enum DebugLaunch {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Expands a leading `~/` to the app's home (its data container), so a
    /// device launch can name files copied in with `devicectl device copy to`.
    static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + "/" + path.dropFirst(2) : path
    }

    /// True when the launch environment names a vault (or the demo).
    static var isActive: Bool { environment["SEMPERE_DEBUG_VAULT"] != nil
        || DemoLaunch.isActive }

    /// `SEMPERE_DEBUG_FRESH`: deletes the app's own state before anything reads
    /// it, so the launch is a first one (launch smoke tests, `LaunchSmokeUITests`):
    /// the preferences domain (column layout, recent vaults, tool and eraser
    /// choices), the app's own `Sempere…` folders in Application Support,
    /// Caches and tmp (device clock, recents, trust records, summary, drawing,
    /// blob and render caches, staged exports) and the saved window state.
    /// The system's files in the container (keyboard and UIKit caches) stay:
    /// they are not the app's state, and wiping them on every launch was the
    /// suspect when the iPad simulator stopped answering UI tests for minutes
    /// in CI. Keychain items stay (unsigned test builds have none). Files
    /// are removed only inside an app container (the simulator, a device, the
    /// sandboxed Mac build), never an unsandboxed Mac build's real home. Called
    /// first thing in `SempereApp.init`.
    static func resetForFreshLaunch() {
        guard environment["SEMPERE_DEBUG_FRESH"] != nil else { return }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        // Only inside the app's container: an unsandboxed Mac build's home is the user's own.
        guard NSHomeDirectory().contains("/Containers/") else {
            NSLog("SempereDebug fresh launch: removed the preferences; files kept (no app container)")
            return
        }
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let folders = ["Library/Application Support", "Library/Caches", "tmp"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
            + [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]
        var removed = 0
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix("Sempere") {
                if (try? fm.removeItem(at: item)) != nil { removed += 1 }
            }
        }
        // Mac: the windows an earlier run saved.
        if (try? fm.removeItem(at: home.appendingPathComponent("Library/Saved Application State", isDirectory: true))) != nil {
            removed += 1
        }
        NSLog("SempereDebug fresh launch: removed the preferences and %d items", removed)
    }

    /// Page y to scroll to after a note opens, if requested.
    /// `SEMPERE_DEBUG_IMPORT_PICK`: builds the folder to import (anew each time) and returns it; nil
    /// when the variable is not set or the folder cannot be built.
    static func importPick() -> [URL]? {
        guard let value = environment["SEMPERE_DEBUG_IMPORT_PICK"], let colon = value.firstIndex(of: ":"),
              let count = Int(value[..<colon]) else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SempereDebugImport", isDirectory: true)
        try? fm.removeItem(at: root)
        let top = root.appendingPathComponent("Notability", isDirectory: true)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: String(value[value.index(after: colon)...])))
            for i in 0..<count {
                let dir = top.appendingPathComponent("Folder \(i % 20)/Sub \(i % 7)", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent("Copy \(i).note"))
            }
        } catch {
            NSLog("SempereDebug importPick failed: %@", "\(error)")
            return nil
        }
        return [top]
    }

    /// `SEMPERE_DEBUG_PICK_VAULT=demo`: the demo vault to copy in, built on the first call of a launch
    /// and the same folder after (so picking it twice picks the same vault); nil when not asked for or
    /// when it cannot be built.
    @MainActor
    static func vaultPick() async -> URL? {
        guard environment["SEMPERE_DEBUG_PICK_VAULT"] == "demo" else { return nil }
        if let built = pickedDemo { return built }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SempereDebugPick", isDirectory: true)
        let passphrase = environment["SEMPERE_DEMO_PASSPHRASE"]
        do {
            let url = try await Task.detached { try await DemoVault.build(in: dir, passphrase: passphrase).url }.value
            pickedDemo = url
            return url
        } catch {
            NSLog("SempereDebug vaultPick failed: %@", "\(error)")
            return nil
        }
    }

    @MainActor private static var pickedDemo: URL?

    static var scrollY: Double? { environment["SEMPERE_DEBUG_SCROLL_Y"].flatMap(Double.init) }

    /// What `SEMPERE_DEBUG_OWNER_CHECK` asks the owner check to answer.
    enum OwnerCheckAnswer: String {
        case pass, fail, cancel
    }

    /// `SEMPERE_DEBUG_OWNER_CHECK`, when set to a known answer.
    static var ownerCheck: OwnerCheckAnswer? { environment["SEMPERE_DEBUG_OWNER_CHECK"].flatMap(OwnerCheckAnswer.init) }

    /// `SEMPERE_DEBUG_LEFTOVERS`: what `takeLeftoverReport` found at launch.
    nonisolated(unsafe) private(set) static var leftoverReport: String?

    /// Called first thing at launch (after `resetForFreshLaunch`), before any purge: counts the
    /// regular files left in the app's plaintext folders and the files of the saved window
    /// state, preferences and Application Support that hold `SEMPERE_DEBUG_LEFTOVERS`'s text
    /// (UTF-8 or UTF-16). Only counts and container-relative paths: never the content.
    static func takeLeftoverReport() {
        guard let needle = environment["SEMPERE_DEBUG_LEFTOVERS"] else { return }
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let tmp = fm.temporaryDirectory
        func regularFiles(_ dir: URL) -> [URL] {
            guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            return walk.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        }
        let plaintext: [(String, URL)] = [
            ("blobs", BlobCache.folder),
            ("import", tmp.appendingPathComponent("SempereImport", isDirectory: true)),
            ("keyshare", KeyShareFile.root),
            ("export", tmp.appendingPathComponent("SempereExport", isDirectory: true)),
        ]
        var parts = plaintext.map { "\($0.0)=\(regularFiles($0.1).count)" }
        let patterns = [Data(needle.utf8), needle.data(using: .utf16LittleEndian) ?? Data(),
                        needle.data(using: .utf16BigEndian) ?? Data()].filter { !$0.isEmpty }
        var hits: [String] = []
        var scanned = 0
        for area in ["Library/Saved Application State", "Library/Preferences", "Library/Application Support"] {
            for file in regularFiles(home.appendingPathComponent(area, isDirectory: true)) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= 8 << 20, let data = try? Data(contentsOf: file) else { continue }
                scanned += 1
                if patterns.contains(where: { data.range(of: $0) != nil }) {
                    hits.append(String(file.path.dropFirst(home.path.count + 1)))
                }
            }
        }
        parts.append("scanned=\(scanned)")
        parts.append("hits=\(hits.count)")
        leftoverReport = "SempereLeftovers " + parts.joined(separator: " ") + (hits.isEmpty ? "" : " in " + hits.joined(separator: ", "))
        NSLog("%@", leftoverReport ?? "")
    }

    /// Opens what the environment names; errors land in `model.errorMessage`.
    @MainActor
    static func run(_ model: AppModel, library: VaultLibrary, keys: RememberedKeys? = nil) async {
        let env = environment
        // The leftover probe's launch only shows its report: opening the demo vault replaced the welcome
        // screen under the alert half a second later and dismissed it (QuitPurgeMacUITests).
        if let report = leftoverReport {
            model.errorMessage = report
            return
        }
        if DemoLaunch.isActive {
            await DemoLaunch.run(model, keys: keys)
            return
        }
        guard let vaultPath = env["SEMPERE_DEBUG_VAULT"] else { return }
        await model.report {
            let url = URL(fileURLWithPath: expand(vaultPath))
            if let keyPath = env["SEMPERE_DEBUG_IDENTITY"] {
                let text = try String(contentsOfFile: expand(keyPath), encoding: .utf8)
                try await model.openVault(at: url)
                try await model.unlock(identityText: text)
            } else {
                try await model.openVault(at: url)
            }
            if let note = env["SEMPERE_DEBUG_NOTE"]?.lowercased(),
               let match = model.notes.first(where: { $0.id.uuidString.lowercased().hasPrefix(note) }) {
                model.selectedNoteID = match.id
            }
        }
    }

    /// The first layout of a canvas: applies the requested zoom and scroll,
    /// logs the geometry and writes the snapshot, if asked.
    @MainActor
    static func canvasDidLayOut(_ host: PageCanvasHost) {
        let env = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak host] in
            guard let host else { return }
            let canvas = host.canvas
            if let z = env["SEMPERE_DEBUG_ZOOM"].flatMap(Double.init) {
                canvas.zoomScale = host.fitScale * CGFloat(z)
            }
            canvas.setContentOffset(CGPoint(x: 0, y: CGFloat(scrollY ?? 0) * canvas.zoomScale), animated: false)
            NSLog("SempereDebug zoom=%f contentSize=%@ offset=%@ bounds=%@", canvas.zoomScale,
                  NSCoder.string(for: canvas.contentSize), NSCoder.string(for: canvas.contentOffset),
                  NSCoder.string(for: host.bounds))
            NSLog("SempereDebug footer=%@ hidden=%d title=%@ frame=%@", "\(host.footer)", host.footerButton.isHidden ? 1 : 0,
                  host.footerButton.configuration?.title ?? "-", NSCoder.string(for: host.footerButton.frame))
            guard let path = env["SEMPERE_DEBUG_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak host] in
                guard let host else { return }
                let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
                    host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: expand(path)))
                NSLog("SempereDebug snapshot %@", path)
            }
        }
    }

    /// The first layout of a paged note's page stack: the requested zoom
    /// (`SEMPERE_DEBUG_ZOOM`, times the fit) and scroll (`SEMPERE_DEBUG_SCROLL_Y`,
    /// page points from the top of the stack, gaps included), the geometry
    /// in the log and the snapshot, if asked.
    @MainActor
    static func stackDidLayOut(_ stack: PageStackHost) {
        let env = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak stack] in
            guard let stack, let fit = stack.fitScale else { return }
            if let z = env["SEMPERE_DEBUG_ZOOM"].flatMap(Double.init) { stack.setScale(fit * CGFloat(z)) }
            stack.scroller.setContentOffset(CGPoint(x: 0, y: CGFloat(scrollY ?? 0) * stack.scale), animated: false)
            NSLog("SempereDebug stack scale=%f pages=%d canvases=%d contentSize=%@ offset=%@ bounds=%@", stack.scale,
                  stack.layout.count, stack.slots.count, NSCoder.string(for: stack.scroller.contentSize),
                  NSCoder.string(for: stack.scroller.contentOffset), NSCoder.string(for: stack.bounds))
            guard let path = env["SEMPERE_DEBUG_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak stack] in
                guard let stack else { return }
                let image = UIGraphicsImageRenderer(bounds: stack.bounds).image { _ in
                    stack.drawHierarchy(in: stack.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: expand(path)))
                NSLog("SempereDebug snapshot %@", path)
            }
        }
    }
}
#endif

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
/// - `SEMPERE_DEBUG_IDENTITY`: path of an age identity file.
/// - `SEMPERE_DEBUG_NOTE`: note id (or a unique prefix of it) to open.
/// - `SEMPERE_DEBUG_SCROLL_Y`: page y (points) to scroll the canvas to.
/// - `SEMPERE_DEBUG_ZOOM`: zoom as a multiple of the fit-width zoom.
/// - `SEMPERE_DEBUG_SNAPSHOT`: path to write a PNG of the canvas to, once shown.
/// - `SEMPERE_DEMO`: a synthetic vault for the App Store screenshots (`DemoLaunch`).
/// - `SEMPERE_DEBUG_FRESH`: start as a first launch (`resetForFreshLaunch`).
/// - `SEMPERE_DEBUG_ONBOARDING`: show the key notice and the quick tour by themselves, which
///   every other scripted launch skips (`OnboardingPolicy.automatic`).
///
/// Release builds compile none of this.
enum DebugLaunch {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Expands a leading `~/` to the app's home (its data container), so a
    /// device launch can name files copied in with `devicectl device copy to`.
    static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + "/" + path.dropFirst(2) : path
    }

    /// True when the launch environment names a vault (or asks for the most
    /// recent one, `SEMPERE_DEBUG_RECENT=1`).
    static var isActive: Bool { environment["SEMPERE_DEBUG_VAULT"] != nil || environment["SEMPERE_DEBUG_RECENT"] != nil
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
    static var scrollY: Double? { environment["SEMPERE_DEBUG_SCROLL_Y"].flatMap(Double.init) }

    /// Opens what the environment names; errors land in `model.errorMessage`.
    @MainActor
    static func run(_ model: AppModel, library: VaultLibrary, keys: RememberedKeys? = nil) async {
        let env = environment
        if DemoLaunch.isActive {
            await DemoLaunch.run(model, keys: keys)
            return
        }
        if env["SEMPERE_DEBUG_RECENT"] != nil {
            await runRecent(model, library: library)
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

    /// Opens the most recent vault through its bookmark, as a relaunch does
    /// (the only way a debug run reaches a vault in iCloud Drive, which needs
    /// the picker's security scope). `SEMPERE_DEBUG_PROBE=1` logs how iCloud
    /// presents the files first, `SEMPERE_DEBUG_EVICT=1` evicts the notes'
    /// files from this device beforehand (they stay in iCloud), and
    /// `SEMPERE_DEBUG_OPEN_ALL=N` opens the first N notes one by one and logs
    /// page and stroke counts (never titles or content). Never draws.
    @MainActor
    static func runRecent(_ model: AppModel, library: VaultLibrary) async {
        let env = environment
        guard let entry = library.recents.first else { DebugProbe.log("no recent vault"); return }
        let clock = ContinuousClock()
        let start = clock.now
        func t() -> String { String(format: "t=%.1fs", Double((clock.now - start).components.attoseconds) / 1e18
                                    + Double((clock.now - start).components.seconds)) }
        do {
            let url = try library.resolve(entry)
            let scoped = url.startAccessingSecurityScopedResource()
            DebugProbe.log("\(t()) recent resolved scoped=\(scoped)")
            if let mode = env["SEMPERE_DEBUG_EVICT"] {
                await Task.detached { DebugProbe.evictNotes(url, mode: mode) }.value
                DebugProbe.log("\(t()) evict done")
            }
            if env["SEMPERE_DEBUG_PROBE"] != nil { await Task.detached { DebugProbe.probe(url, label: "before-open") }.value }
            if scoped { url.stopAccessingSecurityScopedResource() }
            try await model.open(recent: entry, library: library)
            DebugProbe.log("\(t()) opened phase=\(model.phase) cloud=\(model.isCloudVault)")
            guard let keyPath = env["SEMPERE_DEBUG_IDENTITY"] else { return }
            let text = try String(contentsOfFile: expand(keyPath), encoding: .utf8)
            try await model.unlock(identityText: text)
            DebugProbe.log("\(t()) unlocked notes=\(model.notes.count) pending=\(model.pendingNoteIDs.count) "
                           + "placeholders=\(model.placeholderNoteIDs.count) syncing=\(model.cloudSyncTask != nil) "
                           + "sync=\(model.cloudSync.map { "\($0.readyNotes)/\($0.notes)" } ?? "nil")")
            let watch = Int(env["SEMPERE_DEBUG_WATCH"] ?? "") ?? 20
            for _ in 0..<watch {
                try await Task.sleep(for: .seconds(1))
                DebugProbe.log("\(t()) notes=\(model.notes.count) pending=\(model.pendingNoteIDs.count) "
                               + "placeholders=\(model.placeholderNoteIDs.count) "
                               + "sync=[\(model.cloudSync.map { "\($0.readyNotes)/\($0.notes) notes \($0.localFiles)/\($0.files) files bar=\($0.isDownloading) problem=\($0.problem != nil)" } ?? "nil")] error=\(model.errorMessage != nil)")
            }
            if let vault = model.vaultURL, env["SEMPERE_DEBUG_PROBE"] != nil { DebugProbe.probe(vault, label: "after-sync") }
            let n = Int(env["SEMPERE_DEBUG_OPEN_ALL"] ?? "") ?? 0
            var empty = 0, mismatched = 0, opened = 0
            for note in model.visibleNotes.prefix(n) {
                model.selectedNoteID = note.id
                let id = String(note.id.uuidString.prefix(8)).lowercased()
                await model.showSelectedNote()
                if let failure = model.editorFailure { DebugProbe.log("\(t()) \(id) shown failure: \(failure.message)") }
                guard let editor = model.editor else { DebugProbe.log("\(t()) \(id) no editor"); continue }
                await editor.loaded()   // opened from the drawing cache: its strokes arrive in the background
                opened += 1
                let strokes = editor.pages.reduce(0) { $0 + editor.liveStrokes(of: $1.id).count }
                let summary = model.notes.first { $0.id == note.id }
                if strokes == 0 { empty += 1 }
                if strokes != summary?.strokes { mismatched += 1 }
                DebugProbe.log("\(t()) \(id) pages=\(editor.pages.count) strokes=\(strokes) "
                               + "summaryStrokes=\(summary?.strokes ?? -1) listed=\(note.strokes) "
                               + "readOnly=\(editor.isReadOnly) reason=\(editor.readOnlyReason ?? "none")")
            }
            if n > 0 { DebugProbe.log("\(t()) opened=\(opened) empty=\(empty) mismatched=\(mismatched)") }
            if let pick = env["SEMPERE_DEBUG_NOTE"]?.lowercased(),
               let match = model.notes.first(where: { $0.id.uuidString.lowercased().hasPrefix(pick) }) {
                model.selectedNoteID = match.id
            }
        } catch {
            DebugProbe.log("\(t()) failed: \(error)")
            model.errorMessage = "\(error)"
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
                canvas.zoomScale = canvas.minimumZoomScale * CGFloat(z)
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

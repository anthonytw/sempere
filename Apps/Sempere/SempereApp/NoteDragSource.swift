import Sempere
import SwiftUI
import UIKit

/// How a row of the note list starts its drag (`NoteDragOut`).
///
/// TestFlight build 8, bug 7: on a Mac a note dragged to the Finder makes no file, and XCUITest's synthetic
/// pointer drops nothing into the Finder even for controls (`MacDragToFinderUITests`), so the drag is
/// checked by hand with the `drag` log (`DragLog`). Hidden switches (`NoteDragDebug`, Mac only, any build,
/// set in Settings ▸ About's hidden Drag Diagnostics, `DragTestSection`; docs/mac.md "Debugging a drag out")
/// pick the style and two experiments; the iPad always uses `onDrag`.
enum NoteDragStyle: String, CaseIterable, Sendable {
    /// SwiftUI's `onDrag` on the row: the list's collection view runs the session (no end reported).
    case onDrag
    /// A `UIDragInteraction` on a clear view over the row (as notebook rows have, `NotebookDragSource`): its
    /// delegate sees the whole session, down to the operation the destination chose.
    case uikit

    static let shipped: NoteDragStyle = .onDrag

    /// The style rows use: `NoteDragDebug.style` on a Mac, else `shipped`. Read once per launch (rows read
    /// it in every body), so a changed default takes effect at the next launch; the launch's `config` line
    /// names it.
    static let current: NoteDragStyle = {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return .onDrag }
        let debug = NoteDragDebug.load()
        let style = debug.style ?? shipped
        DragLog.step("config style=\(style.rawValue) control=\(debug.control) fileOnly=\(debug.fileOnly) (control and fileOnly are read again at each drag)")
        return style
    }()
}

/// The hidden drag switches (bug 7), read from `UserDefaults` when a row is built (the style) and when a
/// drag begins (the experiments). Set from Settings ▸ About's hidden Drag Diagnostics (`NoteDragTestRun`), never synced. In debug builds the environment
/// (`SEMPERE_DEBUG_NOTE_DRAG`, `SEMPERE_DEBUG_DRAG_CONTROL`, `SEMPERE_DEBUG_DRAG_FILE_ONLY`) overrides them.
struct NoteDragDebug: Equatable, Sendable {
    /// `onDrag` or `uikit`; unset or unknown: `NoteDragStyle.shipped`.
    static let styleKey = "Sempere.debug.noteDragStyle"
    /// Drag a small text file written when the drag begins instead of the note (a control).
    static let controlKey = "Sempere.debug.noteDragControl"
    /// Leave the in-app payload off the drag: the file only.
    static let fileOnlyKey = "Sempere.debug.noteDragFileOnly"

    var style: NoteDragStyle?
    var control = false
    var fileOnly = false

    /// The switches in `defaults`; in debug builds overridden by `environment` (the process's when nil).
    /// Release builds never read the environment.
    static func load(from defaults: UserDefaults = .standard, environment: [String: String]? = nil) -> NoteDragDebug {
        var debug = NoteDragDebug(style: defaults.string(forKey: styleKey).flatMap(NoteDragStyle.init(rawValue:)),
                                  control: defaults.bool(forKey: controlKey),
                                  fileOnly: defaults.bool(forKey: fileOnlyKey))
        #if DEBUG
        let environment = environment ?? ProcessInfo.processInfo.environment
        if let v = environment["SEMPERE_DEBUG_NOTE_DRAG"], let s = NoteDragStyle(rawValue: v) { debug.style = s }
        if environment["SEMPERE_DEBUG_DRAG_CONTROL"] != nil { debug.control = true }
        if environment["SEMPERE_DEBUG_DRAG_FILE_ONLY"] != nil { debug.fileOnly = true }
        #endif
        return debug
    }
}

/// The item provider of a note row's drag, for either style.
@MainActor
enum NoteDragProvider {
    private static var count = 0

    /// The ticked notes go together when `note` is among them: their ids as the in-app payload (`DragPayload`),
    /// and on the Mac the note's file first (`NoteFileDrag`). Notes in Recently Deleted are not moved by a
    /// drop (the drag still carries a file out on the Mac).
    static func make(for note: NoteSummary, model: AppModel, style: NoteDragStyle) -> NSItemProvider {
        count += 1
        let tag = "\(style.rawValue)#\(count):\(DragLog.id(note.id))"
        let ids = model.isSelectingNotes && model.multiSelection.contains(note.id) ? model.exportTargetIDs : [note.id]
        let payload = DragPayload.notes(ids)
        let debug = Platform.isMac ? NoteDragDebug.load() : NoteDragDebug()
        let fileOnly = debug.fileOnly
        let control = debug.control
        let provider = payload.provider(includePayload: !fileOnly) { provider in
            guard Platform.isMac else { return }
            if control {
                NoteFileDrag.registerControl(on: provider, folder: model.exportFolder, tag: tag)
                return
            }
            NoteFileDrag.register(on: provider, title: note.title, prepare: NoteFileDrag.prepare(note.id, model: model), tag: tag)
        }
        DragLog.step("begin \(tag) notes=\(ids.count) deleted=\(note.deleted) fileOnly=\(fileOnly) control=\(control) "
                     + "types=\(provider.registeredTypeIdentifiers)")
        DragLog.watchRelease(of: provider, tag: tag)
        return model.beginDrag(note.deleted ? nil : payload, provider: provider)
    }
}

/// A clear view over a note row (`NoteDragStyle.uikit`) whose `UIDragInteraction` starts the note's drag.
/// Clicks go through to the row (the list's selection, the double-click and the context menu are the
/// cell's); the lift shows the row's cell (`SidebarCellPreview`).
struct NoteDragHandle: UIViewRepresentable {
    let model: AppModel
    let note: NoteSummary

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIDragInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.note = note
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, note: note) }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        let model: AppModel
        var note: NoteSummary
        private var moves = 0

        init(model: AppModel, note: NoteSummary) {
            self.model = model
            self.note = note
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            moves = 0
            let item = UIDragItem(itemProvider: NoteDragProvider.make(for: note, model: model, style: .uikit))
            item.localObject = note.id
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                             session: UIDragSession) -> UITargetedDragPreview? {
            SidebarCellPreview.drag(for: interaction.view)
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            DragLog.step("session will begin items=\(session.items.count) \(DragLog.id(note.id))")
        }

        func dragInteraction(_ interaction: UIDragInteraction,
                             sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
            DragLog.step("session restricted to app? no")
            return false
        }

        /// Drops in the app propose `.copy` (`SidebarDrop.proposedOperation`) and the Finder copies: no move.
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool {
            false
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
            moves += 1
            // The first move, then every 50th: where the pointer is, without flooding the log.
            if moves == 1 || moves % 50 == 0 {
                let window = interaction.view?.window
                let inWindow = window.map { $0.bounds.contains(session.location(in: $0)) } ?? false
                DragLog.step("session moved n=\(moves) insideWindow=\(inWindow)")
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession,
                             willEndWith operation: UIDropOperation) {
            DragLog.step("session will end operation=\(Self.name(operation)) moves=\(moves)")
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession,
                             didEndWith operation: UIDropOperation) {
            DragLog.step("end operation=\(Self.name(operation)) \(DragLog.id(note.id))")
            if operation == .cancel || operation == .forbidden { model.endDrag() }
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionDidTransferItems session: UIDragSession) {
            DragLog.step("session did transfer items \(DragLog.id(note.id))")
        }

        static func name(_ operation: UIDropOperation) -> String {
            switch operation {
            case .cancel: return "cancel"
            case .forbidden: return "forbidden"
            case .copy: return "copy"
            case .move: return "move"
            @unknown default: return "raw\(operation.rawValue)"
            }
        }
    }
}

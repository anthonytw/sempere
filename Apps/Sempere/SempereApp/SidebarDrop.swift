import Foundation
import Sempere
import SwiftUI
import UniformTypeIdentifiers
import SempereAppCore

extension UTType {
    /// Notes dragged inside the app (their ids; declared in `SempereInfo.plist`).
    static let sempereNotes = UTType(exportedAs: "io.github.anthonytw.sempere.notes", conformingTo: .data)
    /// A notebook dragged inside the app (its path).
    static let sempereNotebook = UTType(exportedAs: "io.github.anthonytw.sempere.notebook", conformingTo: .data)
}

/// The app's types for what a drag inside the app carries (`DragPayload`, SempereAppCore): registered with
/// `.ownProcess` visibility only, so ids and paths never go to another app.
extension DragPayload {
    var type: UTType { Self.type(of: kind) }

    static func type(of kind: Kind) -> UTType {
        switch kind {
        case .notes: return .sempereNotes
        case .notebook: return .sempereNotebook
        }
    }

    /// The payload in `data` of the type `type`, nil when it is empty, malformed or of another type.
    static func decode(_ data: Data, as type: UTType) -> DragPayload? {
        guard let kind = Kind.allCases.first(where: { Self.type(of: $0) == type }) else { return nil }
        return decode(data, kind: kind)
    }

    /// An item provider for a drag: whatever `extra` registers (first: other
    /// apps, such as the Finder, take the first type they can use), then the
    /// payload for this app only.
    /// `includePayload` false leaves the payload out (DEBUG drag experiments, `NoteDragOut`).
    func provider(includePayload: Bool = true, extra: (NSItemProvider) -> Void = { _ in }) -> NSItemProvider {
        let provider = NSItemProvider()
        extra(provider)
        guard includePayload else { return provider }
        let bytes = data
        let identifier = type.identifier
        provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .ownProcess) { completion in
            DragLog.step("requested payload type=\(identifier) \(DragLog.thread)")
            completion(bytes, nil)
            return nil
        }
        return provider
    }
}

/// The app's half of the drop rules (`SidebarDrop.accepts` is the core's): the operation a row proposes and the undo
/// step's name.
extension SidebarDrop {
    /// The operation a sidebar row proposes for a drag over it: `.copy` when
    /// the drop is accepted, never `.move`. The notes are moved by the app
    /// (`AppModel.move`), not by the drag session, and the sessions SwiftUI's
    /// `onDrag` starts from a `List` row do not allow a move operation
    /// (`UIDropSession.allowsMoveOperation` is false on iOS; the drag source's
    /// operation mask has no move on Mac Catalyst). UIKit turns a `.move`
    /// proposal the session does not allow into a canceled drop: the row is
    /// highlighted while the finger or pointer hovers, but releasing it calls
    /// `dropExited` and never `performDrop`. That was TestFlight builds 6 and 7
    /// ("dropping does nothing", iPad and Mac), shown by `SidebarDropUITests`'
    /// drop trace. `.copy` is allowed for every session.
    static func proposedOperation(accepted: Bool) -> DropOperation {
        accepted ? .copy : .forbidden
    }

    /// The undo menu title of a drop.
    static func actionName(_ payload: DragPayload) -> String {
        switch payload {
        case .notes(let ids): return NotebookMoveRecord.Moved.notes(count: ids.count).actionName
        case .notebook: return NotebookMoveRecord.Moved.notebook.actionName
        }
    }
}

extension NotebookMoveRecord.Moved {
    /// The undo menu title of a move.
    var actionName: String {
        switch self {
        case .notes(let count): return count == 1 ? String(localized: "Move Note", comment: "Undo action name: one note moved to a notebook")
            : String(localized: "Move Notes", comment: "Undo action name: several notes moved to a notebook")
        case .notebook: return String(localized: "Move Notebook", comment: "Undo action name")
        }
    }
}

extension NotebookMoveRecord {
    /// The undo menu title of this move.
    var actionName: String { moved.actionName }
}

/// The delegate of one sidebar row: validates and highlights while a drag is over it,
/// and makes the move (one commit) when it is dropped.
///
/// A drag started in the app (every drag of these types: their providers are
/// `.ownProcess`) is moved from the model's `draggedPayload`, never from the
/// item provider, which is simpler and needs no load. Decoding the provider
/// is only the fallback for a drag the model does not know.
@MainActor
struct SidebarDropDelegate: DropDelegate {
    let model: AppModel
    let target: DropTarget
    /// The undo manager of the window the row is in: the drop's undo goes there.
    let undoManager: UndoManager?

    private static let types: [UTType] = [.sempereNotes, .sempereNotebook]

    /// Only the app's own drags (their types; the providers are `.ownProcess`):
    /// a left-over `draggedPayload` never answers a photo or text dragged in.
    func validateDrop(info: DropInfo) -> Bool {
        let ours = info.hasItemsConforming(to: Self.types)
        trace("validate ours=\(ours)")
        return ours
    }

    private func trace(_ event: String) {
        #if DEBUG
        DropTrace.note("\(event) target=\(target) payload=\(model.draggedPayload.map { "\($0)" } ?? "nil")")
        #endif
    }

    func dropEntered(info: DropInfo) {
        trace("entered")
        model.setDropTarget(model.acceptsDrop(on: target, carriesAppTypes: validateDrop(info: info)) ? target : nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        trace("updated")
        let allowed = model.acceptsDrop(on: target, carriesAppTypes: validateDrop(info: info))
        model.setDropTarget(allowed ? target : nil)
        return DropProposal(operation: SidebarDrop.proposedOperation(accepted: allowed))
    }

    func dropExited(info: DropInfo) {
        trace("exited")
        if model.dropTarget == target { model.setDropTarget(nil) }
    }

    func performDrop(info: DropInfo) -> Bool {
        trace("perform")
        return SidebarDropDelegate.perform(model: model, target: target, undoManager: undoManager,
                                           carriesAppTypes: validateDrop(info: info)) { info.itemProviders(for: [$0]).first }
    }

    static let acceptedTypes = types

    /// A drop on `target` (this delegate's and `NotebookDragSource`'s UIKit
    /// one): the drag the model started, else the payload decoded from
    /// `provider(type)`; one move and one undo step on `undoManager`.
    static func perform(model: AppModel, target: DropTarget, undoManager: UndoManager?, carriesAppTypes ours: Bool,
                        provider: (UTType) -> NSItemProvider?) -> Bool {
        model.setDropTarget(nil)
        let undo = UndoBox(undoManager)
        if model.draggedPayload != nil || !ours {
            guard let payload = model.takeDrop(on: target, carriesAppTypes: ours) else { return false }
            Task { @MainActor in await model.move(payload, to: target, undoManager: undo.manager) }
            return true
        }
        for type in types {
            guard let provider = provider(type) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let payload = data.flatMap { DragPayload.decode($0, as: type) }
                Task { @MainActor in
                    model.endDrag()
                    guard let payload else { return }
                    await model.move(payload, to: target, undoManager: undo.manager)
                }
            }
            return true
        }
        return false
    }
}

/// `NotebookDragStyle.transferable`: notebooks dropped through `dropDestination`.
private struct TransferDropDestination: ViewModifier {
    @AppModelEnvironment private var model
    let target: DropTarget
    let undoManager: UndoManager?

    func body(content: Content) -> some View {
        if NotebookDragStyle.current == .transferable {
            content.dropDestination(for: NotebookTransfer.self) { items, _ in
                #if DEBUG
                DropTrace.note("perform-transfer target=\(target) items=\(items.map(\.path))")
                #endif
                guard let path = items.first?.path, let canonical = NotebookPath.canonical(path) else { return false }
                let payload = DragPayload.notebook(canonical)
                guard SidebarDrop.accepts(payload, on: target, notes: model.notes) else { return false }
                let model = model, target = target, undo = UndoBox(undoManager)
                Task { @MainActor in await model.move(payload, to: target, undoManager: undo.manager) }
                return true
            } isTargeted: { on in
                #if DEBUG
                DropTrace.note("targeted-transfer \(on) target=\(target)")
                #endif
                if on { model.setDropTarget(target) } else if model.dropTarget == target { model.setDropTarget(nil) }
            }
        } else {
            content
        }
    }
}

/// Carries a window's undo manager across an item provider's callback (it is
/// only read on the main actor); weak, so a closed window's is not kept.
final class UndoBox: @unchecked Sendable {
    weak var manager: UndoManager?
    init(_ manager: UndoManager?) { self.manager = manager }
}

extension View {
    /// Makes a sidebar row take dropped notes and notebooks, highlighted while a drag over it would be accepted.
    func sidebarDropTarget(_ item: SidebarItem) -> some View {
        modifier(SidebarDropRow(item: item))
    }
}

private struct SidebarDropRow: ViewModifier {
    @AppModelEnvironment private var model
    @Environment(\.undoManager) private var undoManager
    let item: SidebarItem

    func body(content: Content) -> some View {
        if let target = DropTarget(item) {
            let highlighted = model.dropTarget == target
            // After a drop: the row the notes or the notebook went into glows for a moment (`AppModel.landedDrop`).
            let landed = model.landedDrop?.target == target
            content
                .background(highlighted || landed ? SwiftUI.Color.accentColor.opacity(landed ? 0.35 : 0.25) : SwiftUI.Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if highlighted { RoundedRectangle(cornerRadius: 8).stroke(SwiftUI.Color.accentColor, lineWidth: 2) }
                }
                .animation(.easeInOut(duration: landed ? 0.15 : 0.6), value: landed)
                .onDrop(of: [.sempereNotes, .sempereNotebook],
                        delegate: SidebarDropDelegate(model: model, target: target, undoManager: undoManager))
                .modifier(TransferDropDestination(target: target, undoManager: undoManager))
        } else {
            content
        }
    }
}

#if DEBUG
/// Debug builds with `SEMPERE_DEBUG_DROPS` set: which drag and drop callbacks
/// ran, newest last, shown in an invisible label (`drop-trace`) that
/// `SidebarDropUITests` reads, so a UI test run tells where a drop stops.
@MainActor @Observable
final class DropTrace {
    static let shared = DropTrace()
    static var isOn: Bool { ProcessInfo.processInfo.environment["SEMPERE_DEBUG_DROPS"] != nil }

    private(set) var events: [String] = []

    static func note(_ event: String) {
        guard isOn else { return }
        shared.events.append(event)
        if shared.events.count > 40 { shared.events.removeFirst(shared.events.count - 40) }
    }
}

/// The trace as an accessibility label (no pixels: it must not change the screenshots).
struct DropTraceLabel: View {
    var body: some View {
        if DropTrace.isOn {
            Text(DropTrace.shared.events.joined(separator: " | "))
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("drop-trace")
                .accessibilityLabel(DropTrace.shared.events.joined(separator: " | "))
                .allowsHitTesting(false)
        }
    }
}
#endif

import Foundation
import Sempere
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Notes dragged inside the app (their ids; declared in `SempereInfo.plist`).
    static let sempereNotes = UTType(exportedAs: "io.github.anthonytw.sempere.notes", conformingTo: .data)
    /// A notebook dragged inside the app (its path).
    static let sempereNotebook = UTType(exportedAs: "io.github.anthonytw.sempere.notebook", conformingTo: .data)
}

/// What a drag inside the app carries. Registered with `.ownProcess`
/// visibility only: ids and paths never go to another app.
enum DragPayload: Equatable, Sendable {
    case notes([UUID])
    case notebook(String)

    /// Most ids or path bytes decoded from a drop (a hostile provider cannot make us read more).
    static let maxNotes = 100_000
    static let maxPathBytes = 4096

    var type: UTType {
        switch self {
        case .notes: return .sempereNotes
        case .notebook: return .sempereNotebook
        }
    }

    var data: Data {
        switch self {
        case .notes(let ids): return (try? JSONEncoder().encode(ids.map { $0.uuidString.lowercased() })) ?? Data()
        case .notebook(let path): return Data(path.utf8)
        }
    }

    /// The payload in `data`, nil when it is empty or malformed.
    static func decode(_ data: Data, as type: UTType) -> DragPayload? {
        if type == .sempereNotes {
            guard data.count <= maxNotes * 48,   // a quoted uuid and a comma are 40 bytes
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= maxNotes else { return nil }
            let ids = names.compactMap { UUID(uuidString: $0) }
            return ids.isEmpty ? nil : .notes(ids)
        }
        if type == .sempereNotebook {
            guard data.count <= maxPathBytes, let path = String(data: data, encoding: .utf8),
                  let canonical = NotebookPath.canonical(path) else { return nil }
            return .notebook(canonical)
        }
        return nil
    }

    /// An item provider for a drag: whatever `extra` registers (first: other
    /// apps, such as the Finder, take the first type they can use), then the
    /// payload for this app only.
    func provider(extra: (NSItemProvider) -> Void = { _ in }) -> NSItemProvider {
        let provider = NSItemProvider()
        extra(provider)
        let bytes = data
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(bytes, nil)
            return nil
        }
        return provider
    }
}

/// Where a drop lands in the sidebar: a notebook, or the top level (the
/// "All Notes" row).
enum DropTarget: Hashable, Sendable {
    case topLevel
    case notebook(String)

    /// The target a sidebar row stands for; nil for rows that take no drops
    /// (tags, Recently Deleted, Recently Recognized).
    init?(_ item: SidebarItem) {
        switch item {
        case .allNotes: self = .topLevel
        case .notebook(let path): self = NotebookPath.canonical(path).map(DropTarget.notebook) ?? .topLevel
        case .tag, .deleted, .favorites, .recentlyRecognized: return nil
        }
    }

    /// The notebook path notes dropped here get; nil: none.
    var path: String? {
        if case .notebook(let p) = self { return NotebookPath.canonical(p) }
        return nil
    }
}

/// The rules of dropping notes and notebooks on the sidebar (pure, tested).
enum SidebarDrop {
    /// Whether `payload` dropped on `target` would change something and is allowed.
    ///
    /// - Notes: allowed when at least one of them (live ones only; ids not in `notes` are
    ///   ignored, they may not be listed yet) is not in that notebook already.
    /// - A notebook: allowed when it can move there (never into itself or a
    ///   notebook inside it, `NotebookPath.moved`) and is not there already.
    static func accepts(_ payload: DragPayload, on target: DropTarget, notes: [NoteSummary]) -> Bool {
        switch payload {
        case .notes(let ids):
            let wanted = Set(ids)
            return notes.contains { wanted.contains($0.id) && !$0.deleted && NotebookPath.canonical($0.notebook) != target.path }
        case .notebook(let path):
            guard let moved = NotebookPath.moved(path, into: target.path) else { return false }
            return moved != NotebookPath.canonical(path)
        }
    }

    /// The operation a sidebar row proposes for a drag over it: `.copy` when
    /// the drop is accepted, never `.move`. The notes are moved by the app
    /// (`AppModel.move`), not by the drag session, and the sessions SwiftUI's
    /// `onDrag` starts from a `List` row do not allow a move operation
    /// (`UIDropSession.allowsMoveOperation` is false on iOS; the drag source's
    /// operation mask has no move on Mac Catalyst). UIKit turns a `.move`
    /// proposal the session does not allow into a cancelled drop: the row is
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
        case .notes(let ids): return ids.count == 1 ? String(localized: "Move Note", comment: "Undo action name: one note moved to a notebook")
            : String(localized: "Move Notes", comment: "Undo action name: several notes moved to a notebook")
        case .notebook: return String(localized: "Move Notebook", comment: "Undo action name")
        }
    }
}

/// Where the notes were before a move, to put them back (undo).
struct NotebookMoveRecord: Equatable, Sendable {
    var previous: [UUID: String?]
    var actionName: String
}

/// The delegate of one sidebar row: validates and highlights while a drag is over it,
/// and makes the move (one commit) when it is dropped.
///
/// A drag started in the app (every drag of these types: their providers are
/// `.ownProcess`) is moved from the model's `draggedPayload`, never from the
/// item provider, which is simpler and needs no load. (On iPadOS 26 the
/// provider `onDrag` returns could be released before the drop, TestFlight
/// build 6; the model no longer holds it on iOS 27.) Decoding the provider
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
            content
                .background(highlighted ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if highlighted { RoundedRectangle(cornerRadius: 8).stroke(SwiftUI.Color.accentColor, lineWidth: 2) }
                }
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

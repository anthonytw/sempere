import Foundation
import Sempere
import SempereAppCore

/// The canvas's side of the open vault's attachments (`AppModel+Attachments` in SempereAppCore): what the item
/// layer draws from, and copy and paste with undo.
extension AppModel {
    /// What the canvas's item layer draws from.
    var itemLayerSource: ItemLayerSource {
        let made = attachmentRenders()
        let renders = made as? RenderCache
        assert(made == nil || renders != nil, "the app's services make the app's RenderCache")
        return ItemLayerSource(cache: attachmentCache(), renders: renders, prefetch: { [weak self] note, items in
            self?.prefetchBlobs(note: note, items: items)
        })
    }

    /// Copy and paste of items for the canvas.
    var itemCommands: ItemCommands {
        ItemCommands(copy: { [weak self] items, note in self?.itemClipboard.copy(items, from: note) },
                     canPaste: { [weak self] in self?.itemClipboard.entry != nil },
                     paste: { [weak self] page, actions in await self?.pasteItems(into: page, with: actions) ?? [] })
    }

    /// Pastes the copied items onto `page` of the editor's note, through
    /// `actions` (one delta, one undo step). Blobs from another note are
    /// downloaded and copied first.
    @discardableResult
    func pasteItems(into page: UUID, with actions: ItemActions) async -> [Item] {
        guard let paste = clipboardPaste(onto: page, of: actions.editor) else { return [] }
        do {
            return try await actions.paste(paste.entry, on: page, offset: paste.offset, prepare: paste.prepare)
        } catch {
            let detail = "\(error)"
            errorMessage = String(localized: "Could not paste: \(detail)")
            return []
        }
    }

    /// The app's cache of drawn attachments for the open vault (`RenderCache`, made by the services).
    static func makeRenderCache(root: URL?, vault: Vault) -> any RenderCaching {
        RenderCache(root: root, vault: vault)
    }
}

extension AttachmentDeletion.Problem {
    /// One line of the delete result, with the note's title as the list shows it (`title`; its id's first
    /// characters when it has none).
    func text(title: String) -> String {
        let t = title.isEmpty ? String(note.uuidString.lowercased().prefix(8)) : NoteTitle.display(title)
        switch kind {
        case .notDownloaded(let detail):
            return String(localized: "\(t): not downloaded: \(detail)", comment: "Delete result; the note's title, then the error (English)")
        case .failed(let detail), .blocked(let detail):
            return "\(t): \(detail)"
        case .doesNotVerify(let why):
            return String(localized: "\(t): a file does not verify and was kept: \(why)", comment: "Delete result; the note's title, then the reason (English)")
        }
    }
}

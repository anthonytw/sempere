import ArgumentParser
import Foundation
import Sempere
import SempereRender

// The app's item gestures (format.md §8.2, docs/attachments.md §13) from the
// command line: one delta each, built by the same `NoteOps` item builders
// the app's canvas calls, computed from the note as it is on disk when the
// delta is written (`editNote`).

struct ItemsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "items",
        abstract: "List, move, resize, rotate, crop, replace, reorder, delete, duplicate and copy a note's placed items; set a video's poster; change an equation.",
        discussion: """
            Placed items are text boxes, images, PDF pages, video clips, equations and recordings shown on the page \
            (audio; format.md §8.2; `recordings place` adds one). An item is named by its
            id or an id prefix of at least 4 characters, as `items list` prints it. Each edit writes one
            delta, as the app's gesture does; nothing when the item already is that way.
            """,
        subcommands: [ItemsList.self, ItemsText.self, ItemsMove.self, ItemsRotate.self, ItemsCrop.self, ItemsReplace.self, ItemsPoster.self, ItemsMath.self,
                      ItemsFront.self, ItemsDelete.self, ItemsDuplicate.self, ItemsCopy.self]
    )
}

/// The page and item named `name` (a full id or a prefix of 4+ characters) in `state`.
func findItem(_ name: String, in state: NoteState) throws -> (page: Page, item: Item) {
    let key = name.lowercased()
    var found: [(Page, Item)] = []
    for page in state.pages {
        for item in page.items {
            let id = item.id.uuidString.lowercased()
            if id == key { return (page, item) }
            if key.count >= 4, id.hasPrefix(key) { found.append((page, item)) }
        }
    }
    guard let only = found.first else { throw CLIError.failure("no item \(name) in this note") }
    guard found.count == 1 else { throw CLIError.failure("\(name) names \(found.count) items: give more of the id") }
    return only
}

/// The items named `names`, all on one page.
func findItems(_ names: [String], in state: NoteState) throws -> (page: Page, items: [Item]) {
    let hits = try names.map { try findItem($0, in: state) }
    guard let page = hits.first?.page else { throw CLIError.failure("no items given") }
    guard hits.allSatisfy({ $0.page.id == page.id }) else { throw CLIError.failure("the items are on different pages") }
    var seen: Set<UUID> = []
    return (page, hits.map(\.item).filter { seen.insert($0.id).inserted })
}

struct ItemsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a note's placed items: page, id, kind, layer, frame, rotation, attachment."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("Only this page (1-based).", valueName: "page"))
    var page: Int?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try vault.reconstruct(try vault.loadNote(id, detail: .withoutStrokePoints))
        if let page { _ = try pageNumbered(page, of: state) }
        struct Row: Encodable {
            var page: Int; var id: String; var kind: String; var layer: String; var frame: Rect
            var rotation: Double?; var z: String; var blob: BlobRef?; var crop: Rect?
            /// Videos: seconds, the poster blob (nil when none).
            var duration: Double?; var poster: BlobRef?
            /// An equation (format.md §8.2.8): its source, style and rendering.
            var math: MathContent?
            /// Audio items: the recording shown, and whether the note has it (format.md §8.2.9).
            var recording: String?; var recordingMissing: Bool?
            /// Text boxes: the text as search sees it, and `markdown` for a Markdown box (format.md §8.2.4).
            var text: String?; var markup: String?
        }
        var rows: [Row] = []
        for (i, p) in state.pages.enumerated() where page == nil || page == i + 1 {
            for item in p.items.sorted(by: Item.drawsBefore) {
                rows.append(Row(page: i + 1, id: item.id.uuidString.lowercased(), kind: item.kind.rawValue,
                                layer: "\(item.layer)", frame: item.frame, rotation: item.rotation, z: item.z,
                                blob: item.blob ?? item.math?.render, crop: item.crop, duration: item.duration, poster: item.poster,
                                math: item.math, recording: item.recording?.uuidString.lowercased(),
                                recordingMissing: item.kind == .audio ? state.recording(shownBy: item) == nil : nil,
                                text: item.text.map(MarkdownText.searchText), markup: item.text?.markup?.rawValue))
            }
        }
        if output.json { try output.emitJSON(rows); return }
        if rows.isEmpty { output.info("No items."); return }
        var table = output.quiet ? [] : [["PAGE", "ID", "KIND", "FRAME", "ATTACHMENT"]]
        for r in rows {
            let f = r.frame
            let n = AttachmentListing.number
            let place: String = n(f.x) + "," + n(f.y) + " " + n(f.w) + "x" + n(f.h)
            var blob: String = r.blob.map(AttachmentListing.blob) ?? "-"
            if r.kind == ItemKind.audio.rawValue {
                blob = "recording " + (r.recording.map { String($0.prefix(8)) } ?? "-") + (r.recordingMissing == true ? " (missing)" : "")
            }
            if r.kind == ItemKind.video.rawValue {
                blob += " " + AttachmentListing.number(r.duration ?? 0) + " s" + (r.poster == nil ? " (no poster)" : " +poster")
            }
            if let t = r.text {
                let line = t.split(whereSeparator: \.isNewline).joined(separator: " ")
                blob = "\"" + (line.count > 40 ? String(line.prefix(39)) + "…" : line) + "\"" + (r.markup == "markdown" ? " (Markdown)" : "")
            }
            if let m = r.math {
                let line = m.latex.split(whereSeparator: \.isNewline).joined(separator: " ")
                blob = (line.count > 40 ? String(line.prefix(39)) + "…" : line) + (m.render == nil ? " (not typeset)" : "")
            }
            table.append([String(r.page), String(r.id.prefix(8)), r.kind, place, blob])
        }
        print(Format.table(table))
    }
}

struct ItemsMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move or resize an item (one setItem frame delta).",
        discussion: """
            The frame is x,y,w,h in page points (origin top left); width and height must be positive. A text \
            box with stored line breaks that gets another width is laid out again with the CLI's fonts: new \
            breaks, and the height its lines take, in the same delta (format.md §8.2.4).
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item id or prefix.", valueName: "item"))
    var item: String

    @Option(name: .long, help: ArgumentHelp("The new frame.", valueName: "x,y,w,h"))
    var frame: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func parsedFrame() throws -> Rect {
        let v = frame.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4, let x = v[0], let y = v[1], let w = v[2], let h = v[3],
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else {
            throw ValidationError("--frame must be x,y,w,h with a positive width and height")
        }
        return Rect(x: x, y: y, w: w, h: h)
    }

    func validate() throws { _ = try parsedFrame() }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let rect = try parsedFrame()
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            return NoteOps.setFrame(found.id, to: rect, on: page) { text, frame in
                // Breaks belong to the wrapping width: lay out again what was laid out.
                guard text.breaks != nil || text.layout != nil else { return (text, frame) }
                var item = found
                item.text = text
                item.frame = frame
                let laid = laidOutText(item, keepHeight: false)
                return (laid.text ?? text, laid.frame)
            }?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Moved", unchanged: "The item already has that frame.")
    }
}

struct ItemsRotate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Set an item's rotation, degrees clockwise (one setItem rotation delta)."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item id or prefix.", valueName: "item"))
    var item: String

    @Option(name: .long, help: ArgumentHelp("Degrees clockwise (0: upright).", valueName: "deg"))
    var degrees: Double

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !degrees.isFinite { throw ValidationError("--degrees must be a number") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            return NoteOps.setRotation(found.id, to: degrees, on: page)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Rotated", unchanged: "The item already has that rotation.")
    }
}

struct ItemsCrop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crop",
        abstract: "Crop an image or PDF page (one delta: setItem crop, and frame), as the app's Crop.",
        discussion: """
            The crop is x,y,w,h in the source's coordinates: pixels of the upright image (after its EXIF \
            orientation), or points on the PDF page's visible box; it is clamped to the source. The frame \
            follows so the part that stays visible keeps its place and size on the page, unless \
            --keep-frame (the crop is then stretched to the frame). --clear shows the whole source again.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item id or prefix.", valueName: "item"))
    var item: String

    @Option(name: .long, help: ArgumentHelp("The part to show, in source coordinates.", valueName: "x,y,w,h"))
    var crop: RectArgument?

    @Flag(name: .long, help: "Remove the crop: show the whole image or page.")
    var clear = false

    @Flag(name: .customLong("keep-frame"), help: "Leave the frame as it is.")
    var keepFrame = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if (crop == nil) == !clear { throw ValidationError("give --crop x,y,w,h or --clear") }
        if let r = crop?.rect, !(r.w > 0 && r.h > 0) { throw ValidationError("--crop needs a positive width and height") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            do {
                return try NoteOps.setCrop(found.id, to: clear ? nil : crop?.rect, on: page, keepFrame: keepFrame)?.ops ?? []
            } catch let e as AttachmentOpsError {
                throw CLIError.failure("\(e)")
            }
        }
        try reportEdit(vault, id, r, output: output, done: clear ? "Uncropped" : "Cropped", unchanged: "The item already has that crop.")
    }
}

struct ItemsReplace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace",
        abstract: "Replace an image with another JPEG or PNG (one delta), as the app's Replace Image.",
        discussion: """
            An image's picture cannot change in place (format.md §8.2.2): the old image is removed and a new one \
            added whose parent names it, in one delta, after the new picture is stored. The new image takes the \
            old one's place: the largest frame of its proportions inside the old frame, centred on it, with the \
            same rotation and stacking; it shows the whole picture (no crop). The picture is stored without its \
            location and camera metadata unless --keep-metadata. Prints the new item's id.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Image item id or prefix.", valueName: "item"))
    var item: String

    @Argument(help: ArgumentHelp("A JPEG or PNG file.", valueName: "file"))
    var file: String

    @Flag(name: .customLong("keep-metadata"), help: "Store the file as it is, with its EXIF/XMP/GPS metadata.")
    var keepMetadata = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let data = try readInput(file, limit: ImageLimits.maxBlobBytes, what: "image (exports draw larger ones as placeholders)")
        let image = try translating { try ImageIngest.prepare(data, keepMetadata: keepMetadata) }
        let ref = BlobRef(content: image.data, type: image.mediaType)
        // Refuse before anything is written: the item must be an image.
        let (page, found) = try findItem(item, in: try liveState(vault, id))
        _ = try translating {
            try NoteOps.replaceImage(found.id, blob: ref, pixelSize: image.pixelSize, orientation: image.orientation, on: page)
        }
        try storeBlob(vault, id, image.data, type: image.mediaType, expect: ref)
        let newID = UUID()
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (current, old) = try findItem(found.id.uuidString, in: state)
            return try translating {
                try NoteOps.replaceImage(old.id, blob: ref, pixelSize: image.pixelSize, orientation: image.orientation,
                                         on: current, newID: newID).ops
            }
        }
        guard let r else { throw CLIError.failure("internal error: nothing was written") }
        let newName = newID.uuidString.lowercased()
        if output.json {
            try output.emitJSON(ReplaceJSON(note: NoteJSON(try vault.summary(of: id)), changed: true, file: r.name.filename,
                                            item: newName, replaced: found.id.uuidString.lowercased(), blob: ref))
        } else {
            print(newName)
            if !output.quiet { printStderr("Replaced image \(found.id.uuidString.lowercased().prefix(8)) (\(id.uuidString.lowercased())/\(r.name.filename))") }
        }
    }

    /// `--json` output: the edit, the new image's id and the one it replaced.
    struct ReplaceJSON: Encodable {
        var note: NoteJSON
        var changed: Bool
        var file: String
        var item: String
        var replaced: String
        var blob: BlobRef
    }
}

struct ItemsFront: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "front",
        abstract: "Draw an item above the others of its layer (one setItem z delta)."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item id or prefix.", valueName: "item"))
    var item: String

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            return NoteOps.bringToFront(found.id, on: page)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Brought to front", unchanged: "The item already is on top.")
    }
}

struct ItemsDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete items (one removeItem each, one delta).",
        discussion: """
            The attachments stay until `sempere blobs gc` finds them unreferenced, so `notes restore --to`
            can bring the items back.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item ids or prefixes, on one page.", valueName: "item"))
    var items: [String]

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItems(items, in: state)
            return NoteOps.removeItems(found.map(\.id), from: page)?.ops ?? []
        }
        try reportEdit(vault, id, r, output: output, done: "Deleted", unchanged: "No item deleted.")
    }
}

struct ItemsDuplicate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Copy items on their page, shifted, on top (one delta), as the app's Duplicate."
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item ids or prefixes, on one page.", valueName: "item"))
    var items: [String]

    @Option(name: .long, help: ArgumentHelp("Shift right, points (default 20).", valueName: "pt"))
    var dx: Double = 20

    @Option(name: .long, help: ArgumentHelp("Shift down, points (default 20).", valueName: "pt"))
    var dy: Double = 20

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if !dx.isFinite || !dy.isFinite { throw ValidationError("--dx and --dy must be numbers") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItems(items, in: state)
            return try NoteOps.copyItems(found.sorted(by: Item.drawsBefore), to: page, dx: dx, dy: dy).ops
        }
        try reportEdit(vault, id, r, output: output, done: "Duplicated", unchanged: "No item copied.")
    }
}

struct ItemsCopy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy items to a page of another note (copy and paste), attachments first.",
        discussion: """
            The items' attachments are copied into the target note (verified as they are read), then the
            copies are added on top of the target page in one delta, as the app's Paste.
            """
    )

    @Argument(help: ArgumentHelp("The note the items are on: id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item ids or prefixes, on one page.", valueName: "item"))
    var items: [String]

    @Option(name: .long, help: ArgumentHelp("The target note: id or title.", valueName: "id|title"))
    var to: String

    @Option(name: .long, help: ArgumentHelp("The target page (1-based, default 1).", valueName: "page"))
    var page = 1

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let source = try vault.resolveNote(note)
        let target = try vault.resolveNote(to)
        let (_, found) = try findItems(items, in: try vault.reconstruct(try vault.loadNote(source)))
        var copied = found.sorted(by: Item.drawsBefore)
        if source != target {
            // A recording belongs to its note: its audio items cannot show it in another one (format.md §8.2.9).
            let kept = NoteOps.copyableToOtherNote(copied)
            if kept.count < copied.count {
                printStderr("sempere: warning: \(copied.count - kept.count) audio item(s) not copied: their recordings belong to this note")
            }
            copied = kept
            guard !copied.isEmpty else { throw CLIError.failure("nothing to copy: audio items stay with their note's recordings") }
            for ref in NoteOps.blobs(of: copied) { try vault.copyBlob(ref, from: source, to: target) }
        }
        let r = try editNote(vault, target) { state in
            try requireLive(state)
            return try NoteOps.copyItems(copied, to: try pageNumbered(page, of: state)).ops
        }
        try reportEdit(vault, target, r, output: output, done: "Copied \(copied.count) item(s)", unchanged: "No item copied.")
    }
}

struct ItemsMath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "math",
        abstract: "Change an equation: its source, style, size, colour or rendering (one delta).",
        discussion: """
            Writes the item's whole `math` value (format.md §8.2.8). Changing the source, style, size or colour \
            drops the stored rendering (the CLI cannot typeset; exports then draw the source until the app \
            typesets it), unless --render gives a one-page PDF typeset elsewhere for the new value; with a new \
            rendering the frame keeps its top-left corner and its scale. --render alone replaces the rendering \
            of an unchanged equation. Nothing is written when nothing changes.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Item id or prefix.", valueName: "item"))
    var item: String

    @OptionGroup var source: LatexInput

    @Flag(name: .long, inversion: .prefixedNo, help: "Display style (--display) or text style (--no-display).")
    var display: Bool?

    @Option(name: .long, help: ArgumentHelp("Font size in points.", valueName: "pt"))
    var size: Double?

    @Option(name: .long, help: ArgumentHelp("Colour as #RRGGBB or #RRGGBBAA.", valueName: "hex"))
    var color: ColorArgument?

    @Option(name: .long, help: ArgumentHelp("A one-page PDF of the typeset equation, stored as its rendering.", valueName: "file"))
    var render: String?

    @Option(name: .long, help: ArgumentHelp("What typeset --render (informational).", valueName: "name"))
    var engine: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        try source.validate(required: false)
        if let size, !(size.isFinite && size > 0 && size <= TextContent.Limits.size) {
            throw ValidationError("--size must be greater than 0 and at most \(Int(TextContent.Limits.size))")
        }
        if engine != nil && render == nil { throw ValidationError("--engine names what made --render") }
        if !source.given && display == nil && size == nil && color == nil && render == nil {
            throw ValidationError("nothing to change: give --latex, --display/--no-display, --size, --color or --render")
        }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let latex = try source.read()
        let rendering = try render.map { try MathRenderInput(path: $0) }
        if let rendering {
            try storeBlob(vault, id, rendering.data, type: MathContent.renderType, expect: rendering.ref)
        }
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            guard found.kind == .math, let old = found.math else { throw CLIError.failure("\(item) is not an equation") }
            var new = try translating {
                try NoteOps.math(latex ?? old.latex, display: display ?? old.display, size: size ?? old.size,
                                 color: color?.color ?? old.color)
            }
            if let rendering {
                new = rendering.content(new, engine: engine)
            } else if new.typesetsLike(old) {
                new = old   // the same equation: its rendering still belongs to it
            }
            return try translating { try NoteOps.setMath(found.id, to: new, on: page)?.ops ?? [] }
        }
        try reportEdit(vault, id, r, output: output, done: "Changed the equation", unchanged: "The equation already is that way.")
    }
}

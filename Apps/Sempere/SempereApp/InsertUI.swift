import PhotosUI
import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which ways of adding images and PDFs the editor offers (pure, tested on
/// each platform): the camera only where there is one and never on a Mac,
/// PDF pages only on a paged note (a pageless note has one infinite page:
/// import the PDF as a new note instead).
enum InsertOptions {
    static func offersCamera(isMac: Bool, cameraAvailable: Bool) -> Bool { !isMac && cameraAvailable }

    static func offersPDFPages(pageless: Bool) -> Bool { !pageless }

    /// What the Insert menu's PDF entry picks: on a pageless note the switch
    /// to pages waits for the PDF (`EditorInsert.preparePages`), so a
    /// cancelled picker leaves the note as it was.
    static func pdfImport(pageless: Bool) -> EditorFileImport { pageless ? .pdfSwitchingToPages : .pdf }

    /// The Insert menu's PDF entry, saying where the pages go: after the
    /// current page (`pageIndex`, 0-based) of a paged note; a pageless note
    /// is switched to pages first (its one page stays the first).
    static func pdfPagesTitle(pageless: Bool, pageIndex: Int, pageCount: Int) -> String {
        if pageless { return String(localized: "Switch to Pages and Insert PDF…") }
        if pageCount <= 0 { return String(localized: "Insert PDF Pages…") }
        let n = min(max(pageIndex, 0), pageCount - 1) + 1
        return n == pageCount ? String(localized: "Insert PDF Pages at the End…") : String(localized: "Insert PDF Pages After Page \(n)…")
    }

    /// The camera on this device.
    @MainActor static var camera: Bool {
        offersCamera(isMac: Platform.isMac, cameraAvailable: UIImagePickerController.isSourceTypeAvailable(.camera))
    }

    /// Where the `index`-th of several images added at once goes: each a
    /// little further down and right, so none hides another.
    static func cascade(_ point: CGPoint?, index: Int) -> CGPoint? {
        point.map { CGPoint(x: $0.x + CGFloat(index) * 20, y: $0.y + CGFloat(index) * 20) }
    }
}

/// What a drop or a paste brings: image bytes, or a PDF or video clip copied into a work folder.
enum CanvasDrop {
    enum Content: Sendable {
        case image(Data)
        case pdf(URL)
        /// A clip (format.md §8.2.7), copied into a work folder.
        case video(URL)
        /// Something that could not be read (too large, unreadable): why.
        case failed(String)
    }

    /// The types the canvas takes.
    static let typeIdentifiers = [UTType.pdf.identifier, UTType.movie.identifier, UTType.image.identifier]

    /// Loads what the providers hold, in order; anything else is skipped.
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> [Content] {
        var out: [Content] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let url = await pdfCopy(provider) { out.append(.pdf(url)) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                out.append(await videoCopy(provider))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                out.append(await imageData(provider))
            }
        }
        return out
    }

    /// Read from the provider's file with a bound (`ImagePreparation.readInput`),
    /// never loaded whole into memory first: a dropped file can be any size.
    @MainActor
    private static func imageData(_ provider: NSItemProvider) async -> Content {
        await withCheckedContinuation { (done: CheckedContinuation<Content, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { return done.resume(returning: .failed(ImagePreparation.Failure.unreadable.description)) }
                do {
                    done.resume(returning: .image(try ImagePreparation.readInput(url)))
                } catch {
                    done.resume(returning: .failed(AppModel.describe(error)))
                }
            }
        }
    }

    /// A dropped clip: the provider's file is only there during the callback, so it is copied out at once.
    @MainActor
    private static func videoCopy(_ provider: NSItemProvider) async -> Content {
        await withCheckedContinuation { (done: CheckedContinuation<Content, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url, let copy = try? VideoPreparation.copyPicked(url) else {
                    return done.resume(returning: .failed(VideoPreparation.Failure.unreadable.description))
                }
                done.resume(returning: .video(copy))
            }
        }
    }

    /// The provider's file is only there during the callback: it is copied out at once.
    @MainActor
    private static func pdfCopy(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                done.resume(returning: url.flatMap { try? PDFPreparation.copyPicked($0) })
            }
        }
    }
}

/// The editor's Insert state: which picker is up, and the item being cropped.
@MainActor
@Observable
final class InsertState {
    var pickingPhotos = false
    var photoSelection: [PhotosPickerItem] = []
    /// The camera, taking a photo or recording a clip.
    var camera: CameraMode?
    /// The file importer is up, choosing `fileImport`.
    var pickingFile = false
    var fileImport = EditorFileImport.pdf
    var cropping: CropRequest?
    /// The image Replace Image is picking a picture for.
    var replacing: ReplaceRequest?
    var pickingReplacementPhoto = false
    var replacementSelection: [PhotosPickerItem] = []
    /// The video item playing (format.md §8.2.7).
    var playing: VideoPlayRequest?
    /// The equation being added or edited (`MathEditorView`).
    var editingMath: MathRequest?
    /// Something is being added (a spinner in the menu's place).
    var working = 0

    /// Opens the picker for `request`: the Insert menu's items and the File
    /// menu's Insert Photo… and Insert PDF Pages… (`WindowUI.insertRequest`).
    /// A pageless note's PDF pick switches it to pages once a PDF is chosen
    /// (`InsertOptions.pdfImport`), as the Insert menu's entry does.
    func open(_ request: InsertRequest, pageless: Bool = false) {
        switch request {
        case .photos:
            pickingPhotos = true
        case .pdfPages:
            fileImport = InsertOptions.pdfImport(pageless: pageless)
            pickingFile = true
        }
    }
}

/// What the camera is for.
enum CameraMode: String, Identifiable {
    case photo, video
    var id: String { rawValue }
}

/// An item to crop and how to write the result (one undo step).
struct CropRequest: Identifiable {
    let id = UUID()
    let item: Item
    let page: UUID
    let note: UUID
    let actions: ItemActions
}

/// An image to replace and how to record the result (one undo step), then
/// what to do with the new image (select it).
struct ReplaceRequest {
    let item: Item
    let page: UUID
    let actions: ItemActions
    let done: @MainActor (Item) -> Void
}

/// The editor toolbar's Insert menu, in groups: pictures and video (Photos,
/// the camera, paste, a video file), a text box (the text tool), pages of a
/// PDF (the entry says where they go), and an equation.
struct InsertMenu: View {
    let editor: NoteEditor
    let state: InsertState
    /// Turns the text tool on.
    var onAddText: () -> Void = {}
    let onPaste: ([NSItemProvider]) -> Void
    @AppStorage(MathRecognitionPreference.key) private var mathRecognition = MathRecognitionPreference.defaultValue

    var body: some View {
        Menu {
            Section("Pictures and Video") {
                Button("Photos and Videos…", systemImage: "photo.on.rectangle") { state.open(.photos) }
                if InsertOptions.camera {
                    Button("Take Photo…", systemImage: "camera") { state.camera = .photo }
                    Button("Record Video…", systemImage: "video") { state.camera = .video }
                }
                PasteButton(supportedContentTypes: [.image], payloadAction: onPaste)
                Button("Video File…", systemImage: "film") {
                    state.fileImport = .video
                    state.pickingFile = true
                }
            }
            Section("Text") {
                Button("Text Box", systemImage: "character.textbox", action: onAddText)
            }
            Section("PDF") {
                Button(InsertOptions.pdfPagesTitle(pageless: editor.isPageless, pageIndex: editor.pageIndex,
                                                   pageCount: editor.pages.count),
                       systemImage: "doc.badge.plus") {
                    state.open(.pdfPages, pageless: editor.isPageless)
                }
            }
            Section("Equation") {
                Button("Equation…", systemImage: "function") {
                    guard let page = editor.currentPage?.id else { return }
                    state.editingMath = MathRequest(editor: editor, page: page, item: nil, actions: nil,
                                                    visible: editor.canvasTarget?.visibleRect(ofPage: page))
                }
                // Settings ▸ Handwritten Math, with a model on this device (docs/attachments.md §14 G1 part 2).
                if mathRecognition && MathModels.shared.isAvailable {
                    Button("Equation from Handwriting…", systemImage: "pencil.and.scribble") { editor.beginMathLasso() }
                }
            }
        } label: {
            Label("Insert", systemImage: state.working > 0 ? "hourglass" : "plus.circle")
        }
        .help("Add photos, videos, a picture from the clipboard, a text box, pages of a PDF, or an equation")
        .disabled(editor.isReadOnly || editor.currentPage == nil)
    }
}

/// The pickers, the camera and the crop sheet of the editor, and what each
/// adds: every addition goes through `AppModel.insertImage` or `importPDF`.
struct EditorInsert: ViewModifier {
    let editor: NoteEditor
    let state: InsertState
    let ui: WindowUI
    @AppModelEnvironment private var model

    func body(content: Content) -> some View {
        @Bindable var state = state
        content
            .photosPicker(isPresented: $state.pickingPhotos, selection: $state.photoSelection, maxSelectionCount: 20,
                          selectionBehavior: .ordered, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: state.photoSelection) { _, picked in
                guard !picked.isEmpty else { return }
                state.photoSelection = []
                addPhotos(picked)
            }
            .photosPicker(isPresented: $state.pickingReplacementPhoto, selection: $state.replacementSelection,
                          maxSelectionCount: 1, matching: .images, preferredItemEncoding: .current)
            .onChange(of: state.replacementSelection) { _, picked in
                guard let first = picked.first else { return }
                state.replacementSelection = []
                replaceWithPhoto(first)
            }
            .fullScreenCover(item: $state.camera) { mode in
                switch mode {
                case .photo:
                    CameraPicker { image in
                        state.camera = nil
                        if let image { addCameraPhoto(image) }
                    }
                    .ignoresSafeArea()
                case .video:
                    VideoCameraPicker { url in
                        state.camera = nil
                        if let url { addVideo(url) }
                    }
                    .ignoresSafeArea()
                }
            }
            .fileImporter(isPresented: $state.pickingFile,
                          allowedContentTypes: Self.types(state.fileImport)) { result in
                guard case .success(let url) = result else { return }
                switch state.fileImport {
                case .pdf: importPDF(url)
                case .pdfSwitchingToPages: importPDF(url, switchingToPages: true)
                case .video: addVideoFile(url)
                case .image: replaceWithFile(url)
                }
            }
            .sheet(item: $state.cropping) { request in
                CropView(request: request, cache: model.attachmentCache())
            }
            .fullScreenCover(item: $state.playing) { request in
                VideoPlayerSheet(request: request)
            }
            .sheet(item: $state.editingMath) { request in
                MathEditorView(request: request)
            }
            .sheet(item: Binding(get: { editor.mathConversion }, set: { editor.mathConversion = $0 })) { conversion in
                MathEditorView(request: MathRequest(editor: editor, page: conversion.page, item: nil, actions: nil,
                                                    visible: nil, conversion: conversion))
            }
            .overlay(alignment: .top) {
                if editor.mathLassoActive { MathLassoBanner(editor: editor).padding(.top, 8) }
            }
    }

    private var visible: CGRect? { editor.canvasTarget?.visiblePageRect }

    /// Switches a pageless note to pages before PDF pages go in (one delta,
    /// `NoteEditor.setLayout`), only once a PDF was picked. Whether the
    /// note has pages now.
    @MainActor static func preparePages(_ editor: NoteEditor) async -> Bool {
        if editor.isPageless { await editor.setLayout(pageless: false) }
        return !editor.isPageless
    }

    static func types(_ kind: EditorFileImport) -> [UTType] {
        switch kind {
        case .pdf, .pdfSwitchingToPages: return [.pdf]
        case .video: return [.movie]
        case .image: return [.image]
        }
    }

    /// Replace Image from Photos: the picked picture's bytes.
    private func replaceWithPhoto(_ picked: PhotosPickerItem) {
        guard let request = state.replacing else { return }
        state.replacing = nil
        state.working += 1
        Task {
            defer { state.working -= 1 }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else { return }
                await replace(request, with: data)
            } catch {
                model.errorMessage = String(localized: "Could not load the photo: \(error.localizedDescription)")
            }
        }
    }

    /// Replace Image from Files (security-scoped: read within its scope, with a size bound).
    private func replaceWithFile(_ url: URL) {
        guard let request = state.replacing else { return }
        state.replacing = nil
        state.working += 1
        Task {
            defer { state.working -= 1 }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try ImagePreparation.readInput(url)
                }.value
                await replace(request, with: data)
            } catch {
                model.errorMessage = String(localized: "Could not read the picture. \(AppModel.describe(error))")
            }
        }
    }

    private func replace(_ request: ReplaceRequest, with data: Data) async {
        if let new = await model.replaceImage(request.item.id, on: request.page, with: data, in: editor, actions: request.actions) {
            request.done(new)
        }
    }

    private func addPhotos(_ picked: [PhotosPickerItem]) {
        let editor = self.editor, visible = self.visible
        state.working += 1
        Task {
            defer { state.working -= 1 }
            for item in picked {
                do {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { continue }
                        await model.insertVideo(file: movie.url, into: editor, visible: visible)
                        continue
                    }
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    await model.insertImage(data, into: editor, visible: visible)
                } catch {
                    model.errorMessage = String(localized: "Could not load the photo or video: \(error.localizedDescription)")
                }
            }
        }
    }

    private func addCameraPhoto(_ image: UIImage) {
        let editor = self.editor, visible = self.visible
        state.working += 1
        Task {
            defer { state.working -= 1 }
            do {
                let data = try ImagePreparation.jpeg(from: image)
                await model.insertImage(data, into: editor, visible: visible)
            } catch {
                model.errorMessage = String(localized: "Could not add the photo. \(AppModel.describe(error))")
            }
        }
    }

    /// A recorded clip (already a work copy).
    private func addVideo(_ url: URL) {
        let editor = self.editor, visible = self.visible
        state.working += 1
        Task {
            defer { state.working -= 1 }
            await model.insertVideo(file: url, into: editor, visible: visible)
        }
    }

    /// A clip picked in Files (security-scoped: copied first).
    private func addVideoFile(_ url: URL) {
        let editor = self.editor, visible = self.visible
        state.working += 1
        Task {
            defer { state.working -= 1 }
            do {
                let copy = try await Task.detached(priority: .userInitiated) { try VideoPreparation.copyPicked(url) }.value
                await model.insertVideo(file: copy, into: editor, visible: visible)
            } catch {
                model.errorMessage = String(localized: "Could not add the video. \(AppModel.describe(error))", comment: "The value is a sentence saying why")
            }
        }
    }

    private func importPDF(_ url: URL, switchingToPages: Bool = false) {
        let editor = self.editor
        state.working += 1
        Task {
            defer { state.working -= 1 }
            if switchingToPages {
                guard await Self.preparePages(editor) else {
                    model.errorMessage = String(localized: "Could not switch the note to pages, so the PDF was not inserted.")
                    return
                }
            }
            let after = editor.pages.isEmpty ? 0 : editor.pageIndex + 1
            if case .needsPassword(let request) = await model.importPDF(picked: url, to: .insert(editor, after: after)) {
                ui.pdfPassword = request
            }
        }
    }
}

extension EditorInsert {
    /// Adds what was pasted or dropped: images at `point` (cascaded) or on
    /// screen, PDFs as pages after `page`.
    @MainActor
    static func add(_ providers: [NSItemProvider], to editor: NoteEditor, page: UUID?, at point: CGPoint?,
                    model: AppModel, ui: WindowUI, state: InsertState) {
        // A drop on a page of the paged stack: that page's visible part, not the current page's.
        let visible = page.flatMap { editor.canvasTarget?.visibleRect(ofPage: $0) } ?? editor.canvasTarget?.visiblePageRect
        state.working += 1
        Task {
            defer { state.working -= 1 }
            var images = 0
            for content in await CanvasDrop.load(providers) {
                switch content {
                case .image(let data):
                    await model.insertImage(data, into: editor, page: page, visible: visible,
                                            at: InsertOptions.cascade(point, index: images))
                    images += 1
                case .video(let url):
                    await model.insertVideo(file: url, into: editor, page: page, visible: visible,
                                            at: InsertOptions.cascade(point, index: images))
                    images += 1
                case .failed(let why):
                    model.errorMessage = String(localized: "Could not add the attachment. \(why)")
                case .pdf(let url):
                    let index = page.flatMap { id in editor.pages.firstIndex { $0.id == id } } ?? editor.pageIndex
                    if case .needsPassword(let request) = await model.importPDF(copy: url, to: .insert(editor, after: index + 1),
                                                                               password: nil) {
                        ui.pdfPassword = request
                    }
                }
            }
        }
    }
}

/// The camera (`UIImagePickerController`), for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// Crops an image or PDF page: the whole source with the crop rectangle on
/// it; drag a corner to resize it, inside to move it. Done writes one delta
/// (`ItemActions.setCrop`: the part that stays keeps its place on the page).
struct CropView: View {
    let request: CropRequest
    let cache: BlobCache?
    @Environment(\.dismiss) private var dismiss
    @State private var crop: Rect
    @State private var image: CGImage?
    @State private var failed = false
    @State private var drag: (start: Rect, handle: ItemCrop.Handle)?
    private let bounds: Rect

    init(request: CropRequest, cache: BlobCache?) {
        self.request = request
        self.cache = cache
        let bounds = request.item.cropBounds ?? Rect(x: 0, y: 0, w: 1, h: 1)
        self.bounds = bounds
        _crop = State(initialValue: request.item.shownCrop ?? bounds)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let k = CropView.scale(bounds: bounds, in: geo.size)
                let size = CGSize(width: bounds.w * k, height: bounds.h * k)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: size.width, height: size.height)
                            .overlay { if failed { Image(systemName: "exclamationmark.triangle") } else { ProgressView() } }
                    }
                    CropShade(crop: crop, bounds: bounds, k: k)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if drag == nil {
                        let p = ItemFrames.Point(x: Double(v.startLocation.x) / k, y: Double(v.startLocation.y) / k)
                        guard let handle = ItemCrop.handle(at: p, crop: crop, scale: k) else { return }
                        drag = (crop, handle)
                    }
                    guard let d = drag else { return }
                    crop = ItemCrop.dragged(d.start, d.handle, dx: Double(v.translation.width) / k,
                                            dy: Double(v.translation.height) / k, bounds: bounds,
                                            minSize: max(ItemCrop.minSide, 24 / k))
                }.onEnded { _ in drag = nil })
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .accessibilityIdentifier("cropArea")
            }
            .padding()
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        request.actions.setCrop(request.item.id, to: crop, on: request.page)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") { crop = bounds }.disabled(crop == bounds)
                }
            }
            .task { await load() }
        }
    }

    /// View points per source unit: the source fitted into `size`.
    static func scale(bounds: Rect, in size: CGSize) -> Double {
        guard bounds.w > 0, bounds.h > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(Double(size.width) / bounds.w, Double(size.height) / bounds.h)
    }

    /// The whole source, upright and uncropped, drawn as the canvas draws items.
    private func load() async {
        var whole = request.item
        whole.crop = nil
        whole.rotation = nil
        let fitted = NoteOps.fit(Size(w: bounds.w, h: bounds.h), into: Size(w: 1024, h: 1024), upscale: true)
        whole.frame = Rect(x: 0, y: 0, w: fitted.w, h: fitted.h)
        let key = ItemRenderKey(whole, scale: 2, paper: .blank)
        switch await ItemRendering.render(key, note: request.note, cache: cache) {
        case .image(let cg, _): image = cg
        case .placeholder: failed = true
        }
    }
}

/// The crop rectangle over the source: the rest dimmed, an outline and corner handles.
private struct CropShade: View {
    let crop: Rect
    let bounds: Rect
    let k: Double

    var body: some View {
        let r = CGRect(x: crop.x * k, y: crop.y * k, width: crop.w * k, height: crop.h * k)
        let all = CGRect(x: 0, y: 0, width: bounds.w * k, height: bounds.h * k)
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(all); p.addRect(r) }
                .fill(SwiftUI.Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Path { p in p.addRect(r) }.stroke(SwiftUI.Color.white, lineWidth: 2)
            ForEach(0..<4, id: \.self) { i in
                let x = i == 0 || i == 3 ? r.minX : r.maxX, y = i < 2 ? r.minY : r.maxY
                Rectangle().fill(SwiftUI.Color.white).frame(width: 14, height: 14).position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}


/// The hint shown while "Convert to Math" picks ink, with Cancel.
struct MathLassoBanner: View {
    let editor: NoteEditor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lasso").accessibilityHidden(true)
            Text(editor.mathLassoMessage ?? String(localized: "Circle the handwritten equation to convert it.",
                                                   comment: "Convert to Math: the lasso's hint"))
                .font(.callout)
            Button("Cancel") { editor.endMathLasso() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityIdentifier("mathLassoBanner")
    }
}

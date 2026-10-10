import SempereRender
import SwiftUI
import UIKit

/// The export sheet: format and options, progress with Cancel, then Share and
/// Save to Files for the result.
struct ExportSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest
    @State private var job = ExportJob()
    @State private var options: ShareOptions
    @State private var handOff = ExportHandOffState()

    init(request: ExportRequest) {
        self.request = request
        _options = State(initialValue: ShareOptions(format: request.format))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch job.state {
                case .idle:
                    settings
                case .running(let progress):
                    Section {
                        ProgressView(value: progress.fraction)
                        Text(progress.description).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Cancel Export", role: .destructive) { job.cancel() }
                    }
                case .finished(let outcome):
                    result(outcome)
                case .failed(let message):
                    Section {
                        Label("Export failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.callout)
                    }
                    Section { Button("Try Again") { job.discard() } }
                }
            }
            .accessibilityIdentifier("exportSheet")
            .navigationTitle(Text("Export \(request.noteIDs.count) Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if job.isRunning { job.cancel() } else { dismiss() }
                    } label: {
                        if job.isRunning { Text("Stop", comment: "Button: stop a running export") } else { Text("Close") }
                    }
                }
            }
        }
        .interactiveDismissDisabled(job.isRunning)
        .onDisappear { job.discard() }
        .exportHandOff($handOff)
    }

    @ViewBuilder
    private var settings: some View {
        Section("Format") {
            Picker("Format", selection: $options.format) {
                ForEach(ExportCommand.formats) { format in
                    Text(format.localizedTitle).tag(format)
                        .disabled(!model.canExport(format, ids: request.noteIDs))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section {
            if options.format != .media {
                Toggle("Paper Background and Ruling", isOn: $options.paper)
            }
            if options.format == .png || (options.format == .markdown && options.markdownImages == .png) {
                ResolutionPicker(dpi: $options.dpi)
            }
            if options.format == .pdf {
                // "PDF" and "PDF + attachments" side by side (docs/attachments.md §13 "Export options").
                Picker("PDF", selection: $options.pdfAttachments) {
                    Text("PDF").tag(false)
                    Text("PDF + attachments").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if options.format == .pdf && request.noteIDs.count > 1 {
                Toggle("One PDF for All Notes", isOn: $options.mergePDF)
            }
            if options.format == .markdown {
                Toggle("Include the PDF", isOn: $options.markdownPDF)
                Toggle("Add a PNG for Each Page", isOn: Binding(get: { options.markdownImages == .png },
                                                                set: { options.markdownImages = $0 ? .png : .none }))
            }
        } header: {
            Text("Options")
        } footer: {
            Text(verbatim: Self.shape(of: options, count: request.noteIDs.count)
                 + Self.recordingsNote(options, count: recordingCount))
        }
        Section {
            Button("Export", systemImage: ExportCommand.menuImage) {
                job.start(model: model, ids: request.noteIDs, options: options)
            }
        } footer: {
            Label("Exports are not encrypted. Anyone who receives the files can read the notes.", systemImage: "lock.open")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func result(_ outcome: ExportJob.Outcome) -> some View {
        Section {
            Label("\(outcome.exported) notes exported", systemImage: "checkmark.circle").foregroundStyle(.green)
            if outcome.recordingsAttached > 0 {
                Label("\(outcome.recordingsAttached) recordings attached", systemImage: "waveform")
            } else if outcome.recordingsOmitted > 0 {
                Label("\(outcome.recordingsOmitted) recordings not included", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
            }
            if outcome.videosAttached > 0 {
                Label("\(outcome.videosAttached) videos attached", systemImage: "film")
            }
            if outcome.mediaFiles > 0 {
                Label("\(outcome.mediaFiles) media files", systemImage: "paperclip")
            }
            if outcome.withoutMedia > 0 {
                Label("\(outcome.withoutMedia) notes without media", systemImage: "paperclip")
                    .foregroundStyle(.secondary)
            }
            ForEach(outcome.items, id: \.self) { Text($0.lastPathComponent).font(.callout) }
        }
        if !outcome.failures.isEmpty {
            Section("Not exported") {
                ForEach(outcome.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
        }
        if !outcome.warnings.isEmpty {
            Section("Left out or kept as stored") {
                ForEach(outcome.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
        }
        Section {
            ExportHandOffButtons(state: $handOff, items: outcome.items)
        } footer: {
            Text("The files are deleted from the app when you close this sheet.")
        }
    }

    /// Recordings in the notes being exported (from their summaries).
    private var recordingCount: Int {
        let ids = Set(request.noteIDs)
        return model.notes.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.recordings }
    }

    /// " 2 recordings not included." for PDF, or what "PDF + attachments" adds.
    static func recordingsNote(_ options: ShareOptions, count: Int) -> String {
        guard count > 0 else { return "" }
        // A leading space: the sentence follows `shape(of:)` in the same footer.
        let sentence: String
        if options.format == .media {
            sentence = String(localized: "\(count) recordings and their transcripts included.")
        } else if options.format == .pdf && options.pdfAttachments {
            sentence = String(localized: "\(count) recordings and their transcripts attached to the PDF.")
        } else if options.format == .pdf {
            sentence = String(localized: "\(count) recordings not included (PDF + attachments includes them).")
        } else {
            sentence = String(localized: "\(count) recordings not included.", comment: "Export: recordings left out of the export")
        }
        return " " + sentence
    }

    /// One sentence on what the export will contain.
    static func shape(of options: ShareOptions, count: Int) -> String {
        let many = count > 1
        switch options.format {
        case .pdf:
            if many && options.mergePDF { return String(localized: "One PDF with every note.") }
            return many ? String(localized: "One PDF per note.") : String(localized: "A PDF with one page per note page.")
        case .png:
            return many ? String(localized: "A folder of PNG images per note.") : String(localized: "One PNG image per page.")
        case .markdown:
            if many {
                return options.markdownPDF
                    ? String(localized: "A folder tree like your notebooks, one Markdown file and PDF per note, with the recognized text.")
                    : String(localized: "A folder tree like your notebooks, one Markdown file per note, with the recognized text.")
            }
            if options.markdownPDF { return String(localized: "A folder with a Markdown file of the recognized text and PDF.") }
            return options.markdownImages != .none
                ? String(localized: "A folder with a Markdown file of the recognized text.")
                : String(localized: "A Markdown file with the recognized handwriting, page by page.")
        case .html:
            return many ? String(localized: "A folder with one self-contained HTML file per note and an index.")
                : String(localized: "One self-contained HTML file.")
        case .media:
            return many ? String(localized: "A folder per note with its recordings, transcripts, videos, images and PDFs as files.")
                : String(localized: "A folder with the note's recordings, transcripts, videos, images and PDFs as files.")
        }
    }
}

extension ShareFormat {
    /// The format's name in the export sheet's picker (`title` is the library's English name).
    var localizedTitle: String {
        switch self {
        case .pdf: return String(localized: "PDF", comment: "Export format: PDF document")
        case .png: return String(localized: "PNG Pages", comment: "Export format: one PNG image per page")
        case .markdown: return String(localized: "Text (Markdown)", comment: "Export format: Markdown text")
        case .html: return String(localized: "HTML", comment: "Export format: HTML page")
        case .media: return String(localized: "Media", comment: "Export format: recordings, videos, images and PDFs as files")
        }
    }
}

/// The system share sheet (AirDrop, Messages, Mail, Save to Files, ...) for files and folders.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let callback = MainCallback(done)
        controller.completionWithItemsHandler = ExportHandOff.completion { callback.run() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Save to Files": the document picker in export mode, copying `items` to the folder the user picks.
struct SaveToFiles: UIViewControllerRepresentable {
    let items: [URL]
    let done: () -> Void

    func makeCoordinator() -> Coordinator {
        let callback = MainCallback(done)
        return Coordinator { callback.run() }
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: items, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: @MainActor @Sendable () -> Void
        init(done: @escaping @MainActor @Sendable () -> Void) { self.done = done }
        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            ExportHandOff.onMain(done)
        }
        nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            ExportHandOff.onMain(done)
        }
    }
}

/// Share… and Save… for finished export files, as the export sheets offer
/// them (`ExportHandOff`): the files handed off, whether the SwiftUI share
/// sheet or Save to Files is up, and the Mac's anchor.
@MainActor
struct ExportHandOffState {
    /// The files the share sheet or the export picker were handed: theirs
    /// until they report back, whatever the export does meanwhile.
    var items: [URL] = []
    var sharing = false
    var saving = false
    /// The view the Mac's share picker and save panel are presented from.
    let anchor = PresentationAnchor.Box()
}

extension View {
    /// The `ShareSheet` and `SaveToFiles` sheets of `state` (the iPad's; a
    /// Mac presents from the anchor instead).
    func exportHandOff(_ state: Binding<ExportHandOffState>) -> some View {
        sheet(isPresented: state.sharing) {
            let items = state.wrappedValue.items
            if !items.isEmpty { ShareSheet(items: items) { state.wrappedValue.sharing = false } }
        }
        .sheet(isPresented: state.saving) {
            let items = state.wrappedValue.items
            if !items.isEmpty { SaveToFiles(items: items) { state.wrappedValue.saving = false } }
        }
    }
}

/// The Share… and Save… buttons for `items`. On a Mac the system's share
/// picker and save panel are presented by UIKit from the Share… button
/// (`ExportHandOff`): hosted inside a SwiftUI sheet, as on the iPad, they
/// have no anchor there (TestFlight build 7: the export of a note with a
/// recording crashed on the Mac when it was shared or saved, #103).
struct ExportHandOffButtons: View {
    @Binding var state: ExportHandOffState
    let items: [URL]

    var body: some View {
        Button("Share…", systemImage: "square.and.arrow.up") { deliver(save: false) }
            .background(PresentationAnchor(box: state.anchor))
        Button(Platform.isMac ? LocalizedStringKey("Save…") : LocalizedStringKey("Save to Files…"),
               systemImage: "folder") { deliver(save: true) }
    }

    private func deliver(save: Bool) {
        state.items = items
        ExportHandOff.deliver(items, save: save, anchor: state.anchor) { save in
            if save { state.saving = true } else { state.sharing = true }
        }
    }
}

/// The PNG resolution of the export sheets.
struct ResolutionPicker: View {
    @Binding var dpi: Double

    static let resolutions: [Double] = [72, 144, 216, 300]

    var body: some View {
        Picker("Resolution", selection: $dpi) {
            ForEach(Self.resolutions, id: \.self) { Text("\(Int($0)) dpi").tag($0) }
        }
    }
}

/// A main-actor callback carried through a `@Sendable` closure: it is only
/// ever run on the main actor (`ExportHandOff.onMain`).
struct MainCallback: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// Handing a finished export to the system (docs/mac.md "Export").
///
/// The share sheet's completion handler and the document picker's delegate
/// may be called off the main thread (on a Mac the share picker is a sharing
/// service in another process). A closure written in a main-actor view is
/// main-actor isolated in Swift 6, and calling it from another thread stops
/// the app (`dispatch_assert_queue`), so these callbacks are `@Sendable`, not
/// isolated, and hop to the main actor themselves.
///
/// On a Mac the share picker and the save panel are presented by UIKit from a
/// view of the export sheet (a popover anchored to it; the picker modally),
/// never hosted inside a SwiftUI sheet.
@MainActor
enum ExportHandOff {
    /// A share sheet's completion handler that is safe on any thread: `done` runs on the main actor.
    nonisolated static func completion(_ done: @escaping @MainActor @Sendable () -> Void)
        -> UIActivityViewController.CompletionWithItemsHandler {
        { @Sendable _, _, _, _ in onMain(done) }
    }

    /// Runs `done` on the main actor, from any thread.
    nonisolated static func onMain(_ done: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in done() }
    }

    /// Share… or Save… for finished export files: on a Mac, by UIKit from
    /// `anchor`'s view; elsewhere (or before the anchor exists) `inSheet` is
    /// called to show the SwiftUI sheet (`ShareSheet` / `SaveToFiles`).
    /// Returns whether UIKit presented it.
    @discardableResult
    static func deliver(_ items: [URL], save: Bool, anchor: PresentationAnchor.Box, isMac: Bool = Platform.isMac,
                        inSheet: (_ save: Bool) -> Void) -> Bool {
        guard isMac, let view = anchor.view else {
            inSheet(save)
            return false
        }
        if save {
            ExportHandOff.save(items, from: view) {}
        } else {
            ExportHandOff.share(items, from: view) {}
        }
        return true
    }

    /// The view controller that shows `view` (the export sheet's), to present from.
    static func presenter(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let controller = r as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
                return top
            }
            responder = r.next
        }
        return nil
    }

    /// The share picker for `items`, anchored to `view`.
    static func share(_ items: [URL], from view: UIView, done: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter = presenter(of: view) else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = completion(done)
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        presenter.present(controller, animated: true)
    }

    /// The save panel (the document picker exporting copies of `items`), presented modally.
    static func save(_ items: [URL], from view: UIView, done: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter = presenter(of: view) else { return }
        let picker = UIDocumentPickerViewController(forExporting: items, asCopy: true)
        // The picker holds its delegate weakly: keep it until the picker reports back.
        let key = ObjectIdentifier(picker)
        let delegate = SaveToFiles.Coordinator(done: {
            ExportHandOff.pickerDelegates[key] = nil
            done()
        })
        pickerDelegates[key] = delegate
        picker.delegate = delegate
        if let popover = picker.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        presenter.present(picker, animated: true)
    }

    /// Delegates of the save panels on screen.
    static var pickerDelegates: [ObjectIdentifier: SaveToFiles.Coordinator] = [:]
}

/// A zero-size view in the SwiftUI hierarchy whose `UIView` UIKit presents from.
struct PresentationAnchor: UIViewRepresentable {
    /// Holds the view once SwiftUI made it.
    @MainActor
    final class Box {
        weak var view: UIView?
    }

    let box: Box

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

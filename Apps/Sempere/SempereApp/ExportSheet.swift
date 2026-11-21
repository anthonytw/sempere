import Sempere
import SempereRender
import SwiftUI
import UIKit
import SempereAppCore

/// The export sheet: format and options, progress with Cancel, then Share and
/// Save to Files for the result.
struct ExportSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest
    @State private var job = ExportJob()
    @State private var options: ShareOptions
    @State private var handOff = ExportHandOffState()
    /// A web page's passphrase: generated for this sheet, never stored (design §3.4); the user may type their own.
    @State private var generatedPassphrase = GeneratedPassphrase.make()
    @State private var useOwnPassphrase = false
    @State private var ownPassphrase = ""

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
                case .failed(let failure):
                    Section {
                        Label("Export failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(failure.text).font(.callout)
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
                        .help("Export this note")
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
        if options.format == .webPage { passphraseSection }
        Section {
            if options.format == .webPage {
                if recordingCount > 0 { Toggle("Include Recordings", isOn: $options.webShare.includeAudio) }
                Toggle("Include Recognized Text", isOn: $options.webShare.includeText)
            }
            if options.format != .media && options.format != .webPage {
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
                var run = options
                if run.format == .webPage { run.webSharePassphrase = passphrase }
                job.start(model: model, ids: request.noteIDs, options: run)
            }
            .disabled(options.format == .webPage && passphrase.isEmpty)
        } footer: {
            if options.format == .webPage {
                Label("Anyone who has the file and the passphrase can read the note. Send them in different ways.", systemImage: "lock")
                    .font(.footnote)
            } else {
                Label("Exports are not encrypted. Anyone who receives the files can read the notes.", systemImage: "lock.open")
                    .font(.footnote)
            }
        }
    }

    /// The passphrase the page is encrypted with: seven generated words, or the user's own.
    private var passphrase: String { useOwnPassphrase ? ownPassphrase : generatedPassphrase }

    /// The page's passphrase: generated, with Copy (this device only, gone after two minutes) and "Use my own".
    @ViewBuilder
    private var passphraseSection: some View {
        Section {
            if useOwnPassphrase {
                SecureField("Your Passphrase", text: $ownPassphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                Text(verbatim: generatedPassphrase).font(.body.monospaced()).accessibilityIdentifier("sharePassphrase")
                CopyPassphraseButton(passphrase: generatedPassphrase)
            }
            Toggle("Use My Own Passphrase", isOn: $useOwnPassphrase)
        } header: {
            Text("Passphrase for the Page")
        } footer: {
            if useOwnPassphrase && Self.isShort(ownPassphrase) {
                Text("A short passphrase can be guessed. Use the generated one if you can.")
            }
        }
    }

    /// A copied passphrase stays on this device's pasteboard for two minutes.
    static let passphraseLifetime: TimeInterval = 120

    /// Under 12 characters or four words: a warning, never a refusal (design §3.4).
    static func isShort(_ passphrase: String) -> Bool {
        guard !passphrase.isEmpty else { return false }
        let words = passphrase.split(whereSeparator: { " -_".contains($0) }).count
        return passphrase.count < 12 || words < 4
    }

    /// A web page made: its size line, and the passphrase until the sheet closes (the app keeps it nowhere else).
    @ViewBuilder
    private func webPageResult(_ outcome: ExportJob.Outcome, _ sections: WebShareSections) -> some View {
        Section {
            Label("Web page made", systemImage: "checkmark.circle").foregroundStyle(.green)
            ForEach(outcome.items, id: \.self) { Text($0.lastPathComponent).font(.callout) }
            Text(verbatim: Self.sizeLine(sections)).font(.callout).foregroundStyle(.secondary)
        } footer: {
            Text("The page opens in a web browser. Mail's preview and most chat apps' previews do not open it: send the file as an attachment.")
        }
        // Right under the file, not at the bottom of the sheet: the share sheet opens by itself and these stay as the way back.
        handOffSection(outcome)
        Section {
            Text(verbatim: passphrase).font(.body.monospaced())
            CopyPassphraseButton(passphrase: passphrase)
        } header: {
            Text("Passphrase for the Page")
        } footer: {
            Text("Send the passphrase in a different way than the file. The app keeps it nowhere: it is gone when you close this sheet.")
        }
    }

    /// "4.2 MB in all: ink 0.9 MB, pictures 2.6 MB, audio 0 KB, viewer 0.7 MB".
    static func sizeLine(_ s: WebShareSections) -> String {
        func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        return String(localized: "\(size(s.total)) in all: ink \(size(s.ink)), pictures \(size(s.images)), audio \(size(s.audio)), viewer \(size(s.template))",
                      comment: "Export web page: where the file's bytes went, the sizes already worded")
    }

    @ViewBuilder
    private func result(_ outcome: ExportJob.Outcome) -> some View {
        if options.format == .webPage, let sections = outcome.webShareSections {
            webPageResult(outcome, sections)
        } else {
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
        if !(options.format == .webPage && outcome.webShareSections != nil) { handOffSection(outcome) }
    }

    /// Share… and Save…; the share sheet is up as soon as the files are made (`ExportHandOffButtons.autoShare`),
    /// unless something was left out or not exported: the sheet would cover what the sections above say.
    private func handOffSection(_ outcome: ExportJob.Outcome) -> some View {
        Section {
            ExportHandOffButtons(state: $handOff, items: outcome.items,
                                 autoShare: outcome.failures.isEmpty && outcome.warnings.isEmpty)
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
        if options.format == .webPage && options.webShare.includeAudio {
            sentence = String(localized: "\(count) recordings and their transcripts included, as far as they fit.",
                              comment: "Export web page: recordings included while they fit in the size limit")
        } else if options.format == .media {
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
        case .webPage:
            return String(localized: "One page that opens in any web browser, encrypted with a passphrase.",
                          comment: "Export web page: what the export contains")
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
        case .webPage: return String(localized: "Web Page (Encrypted)", comment: "Export format: one note as an encrypted web page")
        }
    }
}

/// The system share sheet (AirDrop, Messages, Mail, Save to Files, ...) for files and folders.
/// `secret` (a vault key): without the system's Copy, which would put it on the general pasteboard with no
/// expiry and send it to the user's other devices; a Copy that still shows (iOS 27 and the Mac's share menu list
/// one whatever `excludedActivityTypes` says) copies through `SecretPasteboard` instead (`SecretSharing`).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var secret = false
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let callback = MainCallback(done)
        if secret { return SecretSharing.controller(items: items) { callback.run() } }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = ExportHandOff.completion { callback.run() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Sharing a secret key (its text or its key file): the share sheet is asked to leave Copy out, and a Copy that is
/// listed anyway is handed nothing (`SecretItem`) and answered by `SecretPasteboard` (local only, expiring) when
/// it finishes, so it works instead of copying nothing (TestFlight 1.3.0 build 111). The key's text is never
/// selectable: a selection's ⌘C would be the system's copy, with no expiry and open to Universal Clipboard.
@MainActor
enum SecretSharing {
    /// Activities a secret is never handed to.
    static let excluded: [UIActivity.ActivityType] = [.copyToPasteboard]

    /// A share sheet for `items` without the `excluded` activities. On a Mac the share menu
    /// (macOS 27) lists Copy whatever `excludedActivityTypes` says, so each item is also handed
    /// out through `SecretItem`, which gives a copy activity nothing. When a copy activity completes, the text
    /// items go to `SecretPasteboard`. `done` runs on the main actor when the sheet finishes (shared, copied or
    /// canceled); it must only close the share sheet, never the screen under it.
    static func controller(items: [Any], done: @escaping @MainActor @Sendable () -> Void = {})
        -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items.map(SecretItem.init), applicationActivities: nil)
        controller.excludedActivityTypes = excluded
        let texts = items.compactMap { $0 as? String }
        controller.completionWithItemsHandler = { @Sendable type, completed, _, _ in
            ExportHandOff.onMain {
                if completed, copies(type), let text = texts.first { SecretPasteboard.copy(text) }
                done()
            }
        }
        return controller
    }

    /// The share sheet for a secret, presented by UIKit over the topmost screen of `view` (a popover from it on an
    /// iPad or a Mac): finishing it dismisses only itself. Hosted as the root of a second SwiftUI sheet it took the
    /// new-vault sheet with it when its Copy finished (owner, build 111), so the receipt is never left.
    /// Returns false when `view` has no screen yet, or its screen is busy presenting or dismissing (`isBusy`): UIKit
    /// would refuse the presentation and never run `done`, so the caller shows `ShareSheet` in a sheet instead and
    /// its dismissal unstages what was staged.
    @discardableResult
    static func present(_ items: [Any], from view: UIView, done: @escaping () -> Void) -> Bool {
        guard let presenter = ExportHandOff.presenter(of: view), !isBusy(presenter) else { return false }
        let callback = MainCallback(done)
        let controller = controller(items: items) { callback.run() }
        if view.traitCollection.userInterfaceIdiom != .phone { controller.modalPresentationStyle = .popover }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        presenter.present(controller, animated: true)
        return true
    }

    /// Whether a share sheet is already up over `view`'s screen, or a presentation is on its way in or out there (a
    /// second tap on Share… while the first sheet appears). Callers ignore such a tap before staging anything: a
    /// second `KeyShareFile.stage` would remove the file the first sheet is sharing.
    static func isBusy(_ view: UIView) -> Bool {
        guard let presenter = ExportHandOff.presenter(of: view) else { return false }
        return isBusy(presenter)
    }

    private static func isBusy(_ presenter: UIViewController) -> Bool {
        presenter is UIActivityViewController || presenter.isBeingPresented || presenter.isBeingDismissed
            || presenter.presentedViewController != nil
    }

    /// Whether `type` copies to the pasteboard: UIKit's own, or a Mac sharing service named so.
    nonisolated static func copies(_ type: UIActivity.ActivityType?) -> Bool {
        guard let type else { return false }
        return type == .copyToPasteboard || type.rawValue.localizedCaseInsensitiveContains("copy")
    }
}

/// One shared secret item: the item itself for every activity except a copy (`SecretSharing.copies`).
final class SecretItem: NSObject, UIActivityItemSource {
    let item: Any
    init(_ item: Any) { self.item = item }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { item }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        SecretSharing.copies(type) ? nil : item
    }
}

/// "Save to Files": the document picker in export mode, copying `items` to the folder the user picks. The picker
/// cannot refuse a folder before it copies: a copy it left inside a vault or a backup is removed at once and
/// `refused` says why (`ExportHandOff.removeRefused`).
struct SaveToFiles: UIViewControllerRepresentable {
    let items: [URL]
    var refused: @MainActor @Sendable (String) -> Void = { _ in }
    let done: () -> Void

    func makeCoordinator() -> Coordinator {
        let callback = MainCallback(done)
        return Coordinator(refused: refused) { callback.run() }
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: items, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: @MainActor @Sendable () -> Void
        let refused: @MainActor @Sendable (String) -> Void
        init(refused: @escaping @MainActor @Sendable (String) -> Void = { _ in },
             done: @escaping @MainActor @Sendable () -> Void) {
            self.refused = refused
            self.done = done
        }
        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let reason = ExportHandOff.removeRefused(urls)
            let refused = refused, done = done
            ExportHandOff.onMain {
                if let reason { refused(reason) }
                done()
            }
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
    /// The files last shared on their own (`ExportHandOffButtons.autoShare`): each export's files are shared
    /// once, however often the buttons reappear (a Form row scrolled out and back reruns its `.task`, and a
    /// Mac's picker is presented from the anchor without `sharing`, so it is no guard).
    var autoShared: [URL]?
    /// Why the last Save to Files was undone (a folder inside a vault or a backup), shown as an alert.
    var refusal: String?
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
            if !items.isEmpty {
                SaveToFiles(items: items, refused: { state.wrappedValue.refusal = $0 }) { state.wrappedValue.saving = false }
            }
        }
        .alert(String(localized: "Choose Another Folder", comment: "Title of the alert when a folder pick is refused"),
               isPresented: Binding(get: { state.wrappedValue.refusal != nil },
                                    set: { if !$0 { state.wrappedValue.refusal = nil } })) {
            Button("OK") { state.wrappedValue.refusal = nil }
        } message: {
            Text(state.wrappedValue.refusal ?? "")
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
    /// Present the share sheet (which offers Save to Files) as soon as the buttons appear, once per set of files
    /// (`ExportHandOffState.autoShared`); the buttons stay as
    /// the way back after it is dismissed (owner, build 112: the file was made at the top and Share was below).
    var autoShare = false

    // help-lint: titled (placed in a Form section, where the titles show)
    var body: some View {
        Button("Share…", systemImage: "square.and.arrow.up") { deliver(save: false) }
            .background(PresentationAnchor(box: state.anchor))
            .task(id: items) {
                guard autoShare, !items.isEmpty, state.autoShared != items else { return }
                // The anchor needs a moment to be in a window (a Mac presents from it).
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, !state.sharing, !state.saving, state.autoShared != items else { return }
                state.autoShared = items
                deliver(save: false)
            }
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

/// Copy for a web page's passphrase: "Copied" after a tap, until the passphrase changes.
struct CopyPassphraseButton: View {
    let passphrase: String
    @State private var copiedPassphrase: String?

    var body: some View {
        let copied = copiedPassphrase == passphrase
        Button(copied ? String(localized: "Copied", comment: "Button after the secret key was copied")
                      : String(localized: "Copy Passphrase"),
               systemImage: copied ? "checkmark" : "doc.on.doc") {
            SecretPasteboard.copy(passphrase, lifetime: ExportSheet.passphraseLifetime)
            copiedPassphrase = passphrase
        }
        .help("Copy the passphrase to the clipboard")
        .accessibilityIdentifier("copyPassphrase")
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

    /// Save… on a Mac: AppKit's save panel for one file (`MacSavePanel`), the folder panel for several
    /// (`MacFolderPanel`, `.exportFolder`), and the app copies them; never into a vault or a backup, refused in the
    /// panel itself (owner's test of build 12: UIKit's export picker saved into a `.sempere-backup`, and into a
    /// `.sempere` it froze the app). Without AppKit, the document picker exporting copies of `items`.
    static func save(_ items: [URL], from view: UIView, done: @escaping @MainActor @Sendable () -> Void) {
        let report: @MainActor (String, String) -> Void = { alert($0, $1, from: view) }
        if items.count == 1, let item = items.first,
           MacSavePanel.run(fileName: item.lastPathComponent, { url in
               guard let url else { return done() }
               place(checking: [url], scope: url, report: report, pairs: { [(item, url)] }, done: done)
           }) {
            return
        }
        if items.count > 1, MacFolderPanel.run(purpose: .exportFolder, { dir in
            guard let dir else { return done() }
            // The names are chosen under the folder's grant, just before the copy (`destinations`).
            place(checking: items.map { dir.appendingPathComponent($0.lastPathComponent) }, scope: dir, report: report,
                  pairs: { destinations(for: items, in: dir) }, done: done)
        }) {
            return
        }
        pickToExport(items, from: view, done: done)
    }

    /// Each of `items` in `dir` under its own name, or the next free "Name 2.ext" when that name is taken (the folder
    /// panel asks nothing before replacing).
    nonisolated static func destinations(for items: [URL], in dir: URL, fileManager fm: FileManager = .default) -> [(URL, URL)] {
        var taken = Set<String>()
        return items.map { item in
            let base = item.deletingPathExtension().lastPathComponent, ext = item.pathExtension
            var name = item.lastPathComponent
            var n = 2
            while taken.contains(name.lowercased()) || fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(name.lowercased())
            return (item, dir.appendingPathComponent(name))
        }
    }

    /// Copies the files `pairs` names (source, destination; made off the main actor under `scope`'s grant, just
    /// before the copy) to their destinations, replacing a file there (the save panel asked first). The destinations
    /// `checked` are refused first when one is in a vault or a backup (the panel checks them too). A copy that fails
    /// leaves no partial file; `report` gets a refusal or a failure (title, message), on the main actor.
    static func place(checking checked: [URL], scope: URL, report: @escaping @MainActor (String, String) -> Void,
                      pairs: @escaping @Sendable () -> [(URL, URL)], done: @escaping @MainActor () -> Void) {
        if let problem = checked.lazy.compactMap({ PickedFolderRules.saveProblem($0) }).first {
            report(String(localized: "Choose Another Folder", comment: "Title of the alert when a folder pick is refused"),
                   problem)
            return done()
        }
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                let scoped = scope.startAccessingSecurityScopedResource()
                defer { if scoped { scope.stopAccessingSecurityScopedResource() } }
                return copy(pairs())
            }.value
            if let failure {
                report(String(localized: "File Not Saved", comment: "Title of the alert when an exported file could not be saved"),
                       failure)
            }
            done()
        }
    }

    /// Copies each pair's file over its destination; nil when all were copied, else why, with the destination that
    /// failed removed (no partial file is left).
    nonisolated static func copy(_ pairs: [(URL, URL)], fileManager fm: FileManager = .default) -> String? {
        for (from, to) in pairs {
            do {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            } catch {
                try? fm.removeItem(at: to)
                return error.localizedDescription
            }
        }
        return nil
    }

    /// An alert presented from `view`'s top view controller (after the panel closed, so never behind it).
    static func alert(_ title: String, _ message: String, from view: UIView) {
        guard let presenter = presenter(of: view) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        presenter.present(alert, animated: true)
    }

    /// The copies `urls` (where the Files export picker just saved) that are in a vault or a backup
    /// (`PickedFolderRules.saveProblem`): removed at once; the first reason, nil when there were none.
    nonisolated static func removeRefused(_ urls: [URL]) -> String? {
        var reason: String?
        for url in urls {
            guard let problem = PickedFolderRules.saveProblem(url) else { continue }
            reason = reason ?? problem
            let scoped = url.startAccessingSecurityScopedResource()
            try? FileManager.default.removeItem(at: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return reason
    }

    /// The document picker exporting copies of `items`, presented modally (no AppKit panel).
    static func pickToExport(_ items: [URL], from view: UIView, done: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter = presenter(of: view) else { return }
        let picker = UIDocumentPickerViewController(forExporting: items, asCopy: true)
        // The picker holds its delegate weakly: keep it until the picker reports back.
        let key = ObjectIdentifier(picker)
        let delegate = SaveToFiles.Coordinator(refused: { reason in
            alert(String(localized: "Choose Another Folder", comment: "Title of the alert when a folder pick is refused"),
                  reason, from: view)
        }, done: {
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

import Sempere
import SwiftUI

/// The Settings panel (docs/attachments.md §15): one screen, a sheet from the
/// sidebar's gear button on iPad and iPhone and a window (Settings…, ⌘,) on
/// the Mac. Every setting is kept on the device (`UserDefaults`, see
/// `DeviceSettings`); with Sync Settings with This Vault on, the open vault's
/// shared settings are applied to them (docs/settings-sync.md, `SettingsSyncSection`). Settings of a feature that is not in this
/// build yet (recording, transcription) are stored all the same and read by
/// that feature when it lands.
struct SettingsView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    /// False in the Mac window, which has its own close button.
    var showsDone = true
    /// A section to scroll to when the panel opens (`QuickCaptureSettingsSection.anchor`).
    var scrollTo: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    SettingsSyncSection()
                    GeneralSettings()
                    AppIconSettingsSection().id(model.settingsAppliedRevision)
                    // Sections that hold copies of their values reload them when values arrive from the vault.
                    NewNoteSettingsSection().id(model.settingsAppliedRevision)
                    RecordingSettingsSection().id(model.settingsAppliedRevision)
                    TranscriptionSettingsSection().id(model.settingsAppliedRevision)
                    EditorSettingsSection()
                    MathRecognitionSettingsSection()
                    QuickCaptureSettingsSection()
                    PhotoSettingsSection()
                    HistorySettingsSection()
                    BackupSettingsSection().id(model.settingsAppliedRevision)
                    DeviceKeySettingsSection().id(model.settingsAppliedRevision)
                    StorageSettingsSection()
                    AboutSettingsSection()
                }
                .task {
                    guard let scrollTo else { return }
                    // After the first layout, or the Form has no rows to scroll to yet.
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(scrollTo, anchor: .top) }
                }
            }
            .accessibilityIdentifier("settingsForm")
            .voiceNoteBanner()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppModelEnvironment private var model
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue
    @AppStorage(RecognitionPreference.key) private var recognize = RecognitionPreference.defaultValue
    @AppStorage(MouseSmoothing.key) private var mouseSmoothing = MouseSmoothing.defaultLevel
    @AppStorage(StatusItemPreference.key) private var showMenuBarItem = StatusItemPreference.defaultValue

    var body: some View {
        Section {
            Toggle("Keep Screen On", isOn: $keepScreenOn)
                .syncedSetting("editor.keepScreenOn")
            Toggle("Recognize Handwriting", isOn: Binding(
                get: { recognize },
                set: { recognize = $0; model.setHandwritingRecognition($0) }))
                .syncedSetting("handwriting.recognize")
            if Platform.isMac {
                Picker("Smooth Mouse Strokes", selection: $mouseSmoothing) {
                    Text("Off").tag(StrokeSmoothing.Level.off)
                    Text("Light", comment: "Smooth Mouse Strokes setting").tag(StrokeSmoothing.Level.light)
                    Text("Strong", comment: "Smooth Mouse Strokes setting").tag(StrokeSmoothing.Level.strong)
                }
                .accessibilityIdentifier("mouseSmoothing")
                .syncedSetting("mouse.smoothing")
                Toggle("Show in Menu Bar", isOn: $showMenuBarItem)
                    .accessibilityIdentifier("showMenuBarItem")
            }
        } header: {
            Text("General")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Screen On stops the screen from locking while a note is open. Handwriting recognition makes handwriting searchable; it runs on this device and nothing leaves it.")
                if Platform.isMac {
                    Text("Smooth Mouse Strokes evens out lines drawn with a mouse or trackpad; Strong rounds them more. Strokes drawn with the ruler are not smoothed.")
                    Text("Show in Menu Bar puts a Sempere icon in the menu bar with Quick Voice Note and New Note, while Sempere is running.")
                }
            }
        }
    }
}

// MARK: - Editor

/// Tool choices the editor also changes (its eraser and palette menus), here so
/// that each can be kept on this device when settings sync (docs/settings-sync.md §5).
private struct EditorSettingsSection: View {
    @AppModelEnvironment private var model
    @AppStorage(EraserPreference.defaultsKey) private var eraserName = "object"
    @AppStorage(ObjectEraserSize.defaultsKey) private var eraserRadius = ObjectEraserSize.defaultRadius
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false

    var body: some View {
        Section {
            Picker("Eraser", selection: Binding(
                get: { eraserName == "pixel" || eraserName == "pixelFixedWidth" ? "pixel" : "object" },
                set: { eraserName = $0 == "pixel" ? "pixelFixedWidth" : "object" })) {
                Text("Object Eraser").tag("object")
                Text("Pixel Eraser").tag("pixel")
            }
            .syncedSetting("eraser.mode")
            Picker("Object Eraser Size", selection: $eraserRadius) {
                ForEach(ObjectEraserSize.radii, id: \.self) { Text(ObjectEraserSize.name(of: $0)).tag($0) }
            }
            .syncedSetting("eraser.objectRadius")
            Toggle("Compact Palette", isOn: $paletteCompact)
                .syncedSetting("editor.compactPalette")
            Toggle("Search Recording Transcripts", isOn: Binding(get: { model.searchTranscripts },
                                                                 set: { model.setSearchTranscripts($0) }))
                .syncedSetting("search.transcripts")
        } header: {
            Text("Editor", comment: "Settings section: tools of the note editor")
        } footer: {
            Text("The editor's own menus change these too. Searching recording transcripts reads and decrypts every transcript of the notes searched, on this device.")
        }
    }
}

// MARK: - New notes

private struct NewNoteSettingsSection: View {
    @State private var format = NewNoteSettings.titleFormat()
    /// The custom pattern as typed (stored only while it checks).
    @State private var pattern = NewNoteSettings.titlePattern()
    @State private var paper = PaperPreference.load()
    @State private var layout = NewNoteLayout.load()
    @State private var choosingPaper = false

    var body: some View {
        Section {
            Picker("Title", selection: $format) {
                ForEach(NewNoteSettings.TitleFormat.allCases) { f in
                    // Each preset with what it gives today (a menu shows the second line as its subtitle).
                    if f == .custom || f == .blank {
                        Text(f.title).tag(f)
                    } else {
                        VStack(alignment: .leading) {
                            Text(f.title)
                            Text(NewNoteSettings.title(f)).foregroundStyle(.secondary)
                        }
                        .tag(f)
                    }
                }
            }
            .onChange(of: format) { NewNoteSettings.setTitleFormat(format) }
            .syncedSetting("newNote.titleFormat")
            if format == .custom {
                TitlePatternField(pattern: $pattern)
                    .syncedSetting("newNote.titlePattern")
            }
            Button { choosingPaper = true } label: {
                HStack {
                    Text("Paper").foregroundStyle(.primary)
                    Spacer()
                    Text(paper.kind.localizedTitle).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .syncedSetting("editor.defaultPaper")
            .sheet(isPresented: $choosingPaper) {
                PaperPickerView(paper: paper, purpose: .newNote) { chosen, _ in
                    paper = chosen
                    PaperPreference.save(chosen)
                }
            }
            Picker("Layout", selection: $layout) {
                ForEach(NewNoteLayout.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: layout) { NewNoteLayout.save(layout) }
            .syncedSetting("editor.defaultLayout")
        } header: {
            Text("New Notes")
        } footer: {
            Text("A new note whose title you leave empty is named \(sample).")
        }
    }

    private var sample: String {
        let t = NewNoteSettings.title(format, pattern: NewNoteSettings.titlePattern())
        return t.isEmpty ? String(localized: "“Untitled”", comment: "Settings ▸ New Notes footer: how a note with no title is shown, in quotes") : "“\(t)”"
    }
}

/// The custom title pattern: a monospaced field checked as it is typed
/// (`DefaultTitle.check`, the rules `notes new --title-format` applies), with
/// the title it gives now or the reason it cannot be used, and a menu of
/// fields to insert. Only a pattern that checks is stored.
struct TitlePatternField: View {
    @Binding var pattern: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Pattern", text: $pattern, prompt: Text(NewNoteSettings.defaultTitlePattern))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: pattern) { NewNoteSettings.setTitlePattern(pattern) }
                    .accessibilityLabel("Title pattern")
                Menu("Insert", systemImage: "plus.circle") {
                    ForEach(TitlePatternField.fields, id: \.self) { field in
                        Button("\(field.name) (\(DefaultTitle.title(at: Date(), format: field.pattern)))") {
                            pattern += (pattern.isEmpty || pattern.hasSuffix(" ") ? "" : " ") + field.pattern
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .help("Insert a date field into the pattern")
            }
            switch TitlePatternField.status(of: pattern) {
            case .preview(let title):
                Label(title, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preview: \(title)")
            case .problem(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text("Letters are date fields (yyyy year, MM month, d day, EEEE weekday, HH:mm time); put other text in single quotes, e.g. 'Lecture' d MMM. strftime works too: %Y-%m-%d %H:%M.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    struct Field: Hashable, Sendable {
        let name: String
        let pattern: String
    }

    /// The fields the Insert menu offers.
    static let fields: [Field] = [
        Field(name: String(localized: "Year", comment: "Title pattern Insert menu: the year field"), pattern: "yyyy"),
        Field(name: String(localized: "Month", comment: "Title pattern Insert menu: the month name"), pattern: "MMMM"),
        Field(name: String(localized: "Month (number)", comment: "Title pattern Insert menu: the month as a number"), pattern: "MM"),
        Field(name: String(localized: "Day", comment: "Title pattern Insert menu: the day of the month"), pattern: "d"),
        Field(name: String(localized: "Weekday", comment: "Title pattern Insert menu: the weekday name"), pattern: "EEEE"),
        Field(name: String(localized: "Time", comment: "Title pattern Insert menu: 24-hour time"), pattern: "HH:mm"),
        Field(name: String(localized: "Time (12-hour)", comment: "Title pattern Insert menu: 12-hour time"), pattern: "h:mm a"),
        Field(name: String(localized: "Text", comment: "Title pattern Insert menu: literal text in quotes"), pattern: "'Note'"),
    ]

    enum Status: Equatable {
        case preview(String)
        case problem(String)
    }

    /// `problem` for the screen (`DefaultTitle.Problem.description` is the CLI's English).
    static func message(_ problem: DefaultTitle.Problem) -> String {
        switch problem {
        case .tooLong:
            let limit = String(DefaultTitle.maxFormatLength)
            return String(localized: "The format is too long: at most \(limit) characters.",
                          comment: "Title pattern field: the pattern is too long; the limit is always 200 [not-plural]")
        case .unclosedQuote:
            return String(localized: "A quote (') opens text that is never closed. Put literal text in single quotes, and write '' for a quote.",
                          comment: "Title pattern field: unbalanced single quote")
        case .unknownLetter(let c):
            let letter = String(c)
            return String(localized: "“\(letter)” is not a date field. Put literal text in single quotes, e.g. 'Lecture' d MMM.",
                          comment: "Title pattern field: a letter outside quotes that is no date field")
        case .unknownDirective(let d):
            return String(localized: "“\(d)” is not a strftime directive.",
                          comment: "Title pattern field: an unknown % directive")
        case .blank:
            return String(localized: "The format gives no text.", comment: "Title pattern field: the pattern produces only spaces")
        }
    }

    /// What the field shows under `pattern` at `now`. Pure, tested.
    static func status(of pattern: String, now: Date = Date(), locale: Locale = .current,
                       timeZone: TimeZone = .current) -> Status {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .problem(String(localized: "Type a pattern, e.g. \(NewNoteSettings.defaultTitlePattern).",
                                   comment: "Title pattern field: the field is empty"))
        }
        if let problem = DefaultTitle.check(pattern, at: now, locale: locale, timeZone: timeZone) {
            return .problem(message(problem))
        }
        return .preview(DefaultTitle.title(at: now, format: pattern, locale: locale, timeZone: timeZone))
    }
}

// MARK: - Recording

private struct RecordingSettingsSection: View {
    @State private var settings = RecordingSettings.load()

    var body: some View {
        Section {
            Picker("Format", selection: $settings.codec) {
                ForEach(RecordingSettings.Codec.allCases) { Text($0.title).tag($0) }
            }
            .syncedSetting("recording.codec")
            if settings.codec.hasBitRate {
                Picker("Quality", selection: $settings.bitRate) {
                    ForEach(RecordingSettings.bitRates(for: settings.codec), id: \.self) {
                        Text(RecordingSettings.label(bitRate: $0)).tag($0)
                    }
                }
                .syncedSetting("recording.bitRate")
            }
            Picker("Sample Rate", selection: $settings.sampleRate) {
                ForEach(RecordingSettings.sampleRates(for: settings.codec), id: \.self) {
                    Text(RecordingSettings.label(sampleRate: $0)).tag($0)
                }
            }
            .syncedSetting("recording.sampleRate")
            Picker("Channels", selection: $settings.channels) {
                ForEach(RecordingSettings.Channels.allCases) { Text($0.title).tag($0) }
            }
            .syncedSetting("recording.channels")
            LabeledContent("Size", value: settings.sizePerHourText())
        } header: {
            Text("Recording")
        } footer: {
            Text("Stereo is used only when the microphone has two channels. Apple Lossless is a size estimate for speech. Changes apply to new recordings; recordings already made keep their format.")
        }
        .onChange(of: settings) {
            // A codec change can make the bit rate or sample rate invalid: show the corrected value.
            let fixed = settings.normalized()
            if fixed != settings { settings = fixed }
            settings.save()
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettingsSection: View {
    @State private var enabled = TranscriptionSettings.isEnabled()
    @State private var locale = TranscriptionSettings.localeIdentifier()
    @State private var status = TranscriptionSettings.ModelStatus.unavailable
    @State private var engines: [TranscriptionSettings.EngineLine] = []
    @State private var downloading = false
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle("Transcribe Recordings on This Device", isOn: $enabled)
                .onChange(of: enabled) { TranscriptionSettings.setEnabled(enabled) }
                .syncedSetting("transcription.enabled")
            if enabled {
                Picker("Language", selection: $locale) {
                    Text("Same as Device").tag(String?.none)
                    ForEach(TranscriptionSettings.offeredLocales(), id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(String?.some(id))
                    }
                }
                .onChange(of: locale) { TranscriptionSettings.setLocaleIdentifier(locale) }
                .syncedSetting("transcription.language")
                LabeledContent("Language Model", value: status.text)
                LabeledContent("Engine in Use", value: engines.first(where: \.isUsed)?.title
                               ?? String(localized: "None available", comment: "Settings ▸ Transcription: no speech engine can transcribe the chosen language"))
                ForEach(engines, id: \.title) { engine in
                    LabeledContent(engine.title, value: engine.state)
                        .font(.footnote)
                        .foregroundStyle(engine.available ? Color.primary : Color.secondary)
                }
                if TranscriptionSettings.offersDownload(status, hasDownloader: TranscriptionSettings.downloader != nil) {
                    Button(LocalizedStringKey(downloading ? "Downloading…" : "Download Language Model")) { Task { await download() } }
                        .disabled(downloading)
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            if let failure {
                Text(failure)
            } else {
                Text("Off by default. Transcripts are made on this device and stored encrypted in the note; no audio or text is sent anywhere.")
            }
        }
        .task(id: "\(enabled)|\(locale ?? "")") { await refresh() }
    }

    private func refresh() async {
        guard enabled else { return }
        status = await TranscriptionSettings.statusProvider(locale)
        engines = await TranscriptionSettings.enginesProvider(locale)
    }

    private func download() async {
        guard let download = TranscriptionSettings.downloader else { return }
        downloading = true
        failure = nil
        status = .downloading(fraction: nil)
        defer { downloading = false }
        do { try await download(locale) } catch {
            failure = String(localized: "The language model could not be downloaded: \(String(describing: error))",
                             comment: "Settings ▸ Transcription; the error text follows (English)")
        }
        await refresh()
    }
}

// MARK: - Photos

private struct PhotoSettingsSection: View {
    @AppStorage(PhotoPrivacy.key) private var photoPrivacy = PhotoPrivacy.defaultValue

    var body: some View {
        Section {
            Toggle("Remove Location and Camera Data", isOn: $photoPrivacy)
                .syncedSetting("photos.removeMetadata")
        } header: {
            Text("Photos")
        } footer: {
            if photoPrivacy {
                Text("Photos you add are stored without location and camera data, and HEIC photos are converted to JPEG. Exports never include location data.")
            } else {
                Text("Photos are stored as picked, with their location and camera data, and HEIC photos stay HEIC. Exports still leave location data out.")
            }
        }
    }
}

// MARK: - Version history

private struct HistorySettingsSection: View {
    @AppModelEnvironment private var model
    @AppStorage(ThinningPreference.key) private var days = ThinningPreference.defaultDays
    @State private var preview: PreviewBox?
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        Group {
            Section {
                Picker("Thin Autosaves Older Than", selection: $days) {
                    ForEach(ThinningPreference.choices, id: \.self) { Text(ThinningPreference.label($0)).tag($0) }
                }
                .syncedSetting("history.thinAfterDays")
            } header: {
                Text("Version History")
            } footer: {
                if days > 0 {
                    Text("Once a day, autosaves older than \(ThinningPreference.label(days)) are removed from this vault on every device. Saved versions and the last autosave of each editing session are always kept, and stay restorable. With Sync Settings on, every device that syncs with this vault uses the same setting.")
                } else {
                    Text("Autosaves are never removed by this device. Another device with thinning on still thins the vault.")
                }
            }
            Section {
                Button {
                    Task { await makePreview(.olderThan(days: days)) }
                } label: {
                    if days > 0 {
                        Text(ThinningRule.olderThan(days: days).localizedButtonTitle)
                    } else {
                        Text("Thin Now…")
                    }
                }
                .disabled(days <= 0 || working || model.phase != .unlocked)
                Button(role: .destructive) {
                    Task { await makePreview(.allButCheckpoints) }
                } label: {
                    Text(ThinningRule.allButCheckpoints.localizedButtonTitle)
                }
                .disabled(working || model.phase != .unlocked)
                if let progress = model.thinningProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fractionCompleted)
                        Text(progress.headline).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Thin Now")
            } footer: {
                Text("The first applies the setting above; the second ignores it and removes every autosave except the newest save of each editing session. Both keep every saved and imported version, and show what they would remove before anything is.")
            }
        }
        .sheet(item: $preview) { box in
            ThinningPreviewView(report: box.report) {
                preview = nil
                Task { await thin(box.report.rule, now: box.report.now) }
            } cancel: {
                preview = nil
            }
        }
        .alert("Thinning", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK") {}
        } message: {
            Text(outcome ?? "")
        }
    }

    private func makePreview(_ rule: ThinningRule) async {
        working = true
        defer { working = false }
        do {
            preview = PreviewBox(report: try await model.thinVault(rule: rule, dryRun: true))
        } catch is CancellationError {
        } catch {
            outcome = String(localized: "Could not check the vault: \(String(describing: error))",
                             comment: "Settings alert; the error text follows (English)")
        }
    }

    /// Runs `rule` as of `now`, the preview's time (nil: the current time).
    private func thin(_ rule: ThinningRule, now: Date?) async {
        working = true
        defer { working = false }
        do {
            let done = try await model.thinVault(rule: rule, dryRun: false, now: now ?? Date())
            outcome = ThinningPreviewView.sentence(done, done: true)
        } catch is CancellationError {
        } catch {
            outcome = String(localized: "Could not thin the vault: \(String(describing: error))",
                             comment: "Settings alert; the error text follows (English)")
        }
    }

    private struct PreviewBox: Identifiable {
        let report: ThinningReport
        let id = UUID()
    }
}

// MARK: - Device keys

private struct DeviceKeySettingsSection: View {
    @AppModelEnvironment private var model
    @State private var onAdd = RewrapSettings.onAdd()
    @State private var onRemove = RewrapSettings.onRemoveOrUpgrade()
    @State private var confirming = false
    @State private var savingKey = false
    @State private var creatingKey = false

    var body: some View {
        Section {
            Button("Save Key…", systemImage: "key") { savingKey = true }
                .disabled(model.phase != .unlocked || model.heldIdentity == nil)
            Button("New Key…", systemImage: "key.badge.plus") { creatingKey = true }
                .disabled(model.phase != .unlocked)
            Picker("When Adding a Device", selection: $onAdd) {
                ForEach(RewrapMethod.allCases, id: \.self) { Text(RewrapSettings.title($0)).tag($0) }
            }
            .onChange(of: onAdd) { RewrapSettings.setOnAdd(onAdd) }
            .syncedSetting("rewrap.onAdd")
            Picker("When Removing a Device or Upgrading to Post-Quantum Keys", selection: Binding(
                get: { onRemove },
                set: { chosen in
                    switch RewrapSettings.removalStep(choosing: chosen, current: onRemove) {
                    case .confirm:
                        confirming = true
                    case .apply:
                        onRemove = chosen
                        RewrapSettings.setOnRemoveOrUpgrade(chosen)
                    }
                })) {
                ForEach(RewrapMethod.allCases, id: \.self) { Text(RewrapSettings.title($0)).tag($0) }
            }
            .syncedSetting("rewrap.onRemove")
        } header: {
            Text("Device Keys")
        } footer: {
            Text("Save Key exports this device's key, after \(RememberedKeys.biometryPhrase), to Files or a password manager, with its paper recovery kit. New Key makes a key for another device and encrypts the vault to it. Devices here are the keys this vault is encrypted to (this iPad, that Mac, the paper backup), not people: to share a note, export it. “Rewrite headers only” is fast but leaves old copies of an attachment openable with a key that was removed. “Re-encrypt everything” takes longer in a vault with many attachments.")
        }
        .sheet(isPresented: $savingKey) { SaveKeyView() }
        .sheet(isPresented: $creatingKey) { NewKeyView() }
        .confirmationDialog("Rewrite headers only after a removal?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Rewrite Headers Only", role: .destructive) {
                onRemove = .headerOnly
                RewrapSettings.setOnRemoveOrUpgrade(.headerOnly)
            }
            Button("Keep Re-encrypting Everything", role: .cancel) {}
        } message: {
            Text("A removed device key, or a copy of the vault from before an upgrade, could still open attachments it could open before. Only choose this if you accept that.")
        }
    }
}

// MARK: - Storage

private struct StorageSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var sizes = CacheSizes()

    var body: some View {
        Section {
            if model.phase == .unlocked {
                // Re-derived whenever the index changes.
                let _ = model.attachmentIndexVersion
                let report = model.attachmentStorage()
                NavigationLink {
                    UnusedAttachmentsView()
                } label: {
                    LabeledContent("Unused Attachments", value: StorageText.items(report.unused.count, bytes: report.unusedBytes))
                }
                LabeledContent("Held by History", value: StorageText.items(report.held.count, bytes: report.heldBytes))
                if model.attachmentIndexPending > 0 {
                    HStack {
                        Text("Checking \(model.attachmentIndexPending) notes…", comment: "Settings ▸ Storage: the attachment index is being updated")
                        Spacer()
                        ProgressView()
                    }
                } else if model.notesWithoutAttachmentIndex > 0 {
                    let n = model.notesWithoutAttachmentIndex
                    Button("Check \(n) More Notes") { Task { await model.indexAttachments() } }
                }
            } else {
                Text("Unlock a vault to see its unused attachments.").foregroundStyle(.secondary)
            }
            LabeledContent("Drawing Cache", value: StorageText.bytes(sizes.drawings))
            LabeledContent("Attachment Cache", value: StorageText.bytes(sizes.attachments))
            Button("Clear Caches", role: .destructive) {
                Task {
                    await model.clearCaches()
                    sizes = await model.cacheSizes()
                }
            }
            .disabled(sizes.total == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text(Self.footer)
        }
        .task {
            sizes = await model.cacheSizes()
            await model.loadAttachmentIndex()
        }
    }

    static let footer = String(localized: "Unused attachments are files no version of their note uses; they can be deleted 30 days after this device first found them unused. Held by history: files only older versions show, freed when those versions are thinned. Caches speed up opening notes and can be rebuilt from the vault.", comment: "Settings ▸ Storage footer")
}

/// Settings → Storage → Unused Attachments: by note, each with a preview,
/// what it was, since when it is unused and when it may be deleted, a link
/// to the note's history, and Delete (only once the 30 days have passed);
/// then the attachments only history still uses.
struct UnusedAttachmentsView: View {
    @AppModelEnvironment private var model
    @State private var deleting = false
    @State private var confirmAll = false
    @State private var message: String?
    @State private var history: HistoryLink?

    /// A note's history to show, at a restore point if one is given.
    struct HistoryLink: Identifiable {
        var note: UUID
        var revision: String?
        var id: String { note.uuidString + (revision ?? "") }
    }

    var body: some View {
        let _ = model.attachmentIndexVersion
        let report = model.attachmentStorage()
        let now = model.attachmentNow()
        let eligible = report.eligible(at: now)
        List {
            Section {
                Button(role: .destructive) {
                    confirmAll = true
                } label: {
                    HStack {
                        Text("Delete All Eligible (\(StorageText.items(eligible.count, bytes: report.eligibleBytes(at: now))))")
                        if deleting { Spacer(); ProgressView() }
                    }
                }
                .disabled(eligible.isEmpty || deleting)
            } footer: {
                Text(message ?? String(localized: "An attachment can be deleted 30 days after this device first found it unused. Deleting reads its note again first and keeps anything a version still uses."))
            }
            if report.unused.isEmpty {
                Text("No unused attachments.").foregroundStyle(.secondary)
            }
            ForEach(UnusedAttachmentGroups.group(report.unused, title: model.noteTitle)) { group in
                Section {
                    ForEach(group.items) { item in
                        UnusedAttachmentRow(item: item, now: now, deleting: deleting) {
                            Task { await delete([item]) }
                        } showHistory: {
                            history = HistoryLink(note: item.note, revision: item.lastUse?.revision)
                        }
                    }
                } header: {
                    HStack {
                        Text(NoteTitle.display(group.title)).lineLimit(1)
                        Spacer()
                        Button("History") { history = HistoryLink(note: group.note, revision: nil) }
                            .font(.caption).textCase(nil)
                    }
                }
            }
            if !report.held.isEmpty {
                Section {
                    ForEach(report.held) { item in
                        Button {
                            history = HistoryLink(note: item.note, revision: item.lastUse?.revision)
                        } label: {
                            HStack {
                                AttachmentThumbnail(note: item.note, fileName: item.fileName, kind: item.kind)
                                VStack(alignment: .leading) {
                                    Text(NoteTitle.display(model.noteTitle(item.note))).lineLimit(1)
                                    Text(StorageText.describe(kind: item.kind, lastUse: item.lastUse) + " · " + StorageText.versions(item.revisions.count))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(StorageText.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Held by History (\(StorageText.items(report.held.count, bytes: report.heldBytes)))")
                } footer: {
                    Text("Only older versions of these notes show these attachments. They are freed when those versions are thinned (Settings → Version History).")
                }
            }
            if !report.unchecked.isEmpty {
                Section {
                } footer: {
                    Text("\(report.unchecked.count) notes were not checked: a version could not be read, or is not downloaded yet.")
                }
            }
        }
        .navigationTitle("Unused Attachments")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(StorageText.items(eligible.count, bytes: report.eligibleBytes(at: now)))?",
                            isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(eligible) } }
        } message: {
            Text("These attachments have been unused for at least 30 days. This cannot be undone.")
        }
        .sheet(item: $history) { link in
            HistoryView(noteID: link.note, revealing: link.revision)
        }
        .task { await model.loadAttachmentIndex() }
    }

    private func delete(_ items: [AttachmentStorageReport.Unused]) async {
        deleting = true
        defer { deleting = false }
        do {
            let r = try await model.deleteUnusedAttachments(items)
            var text = String(localized: "Deleted \(StorageText.items(r.deleted, bytes: r.bytes)).")
            if !r.problems.isEmpty { text += " " + r.problems.joined(separator: " ") }
            message = text
        } catch is CancellationError {
        } catch {
            message = String(localized: "Could not delete: \(String(describing: error))", comment: "the error text follows (English)")
        }
    }
}

/// One unused attachment: preview, what it was, the window, Delete.
private struct UnusedAttachmentRow: View {
    let item: AttachmentStorageReport.Unused
    let now: Date
    let deleting: Bool
    let delete: () -> Void
    let showHistory: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            AttachmentThumbnail(note: item.note, fileName: item.fileName, kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(StorageText.describe(kind: item.kind, lastUse: item.lastUse))
                Text(StorageText.window(item, now: now)).font(.caption).foregroundStyle(.secondary)
                if let used = item.lastUse {
                    Button(used.wall.map { String(localized: "Last used \(StorageText.day($0))") } ?? String(localized: "Last used in an earlier version"),
                           action: showHistory)
                        .font(.caption).buttonStyle(.borderless)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(StorageText.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                Button("Delete", role: .destructive, action: delete)
                    .buttonStyle(.borderless)
                    .disabled(deleting || !item.isEligible(at: now))
            }
        }
    }
}

/// What "Thin Now" will remove, note by note, with the button that does it.
struct ThinningPreviewView: View {
    let report: ThinningReport
    let thin: () -> Void
    let cancel: () -> Void

    /// "Removes 120 old autosaves (1.2 MB) from 4 notes and adds 6 snapshots (3.4 MB) …".
    static func sentence(_ r: ThinningReport, done: Bool) -> String {
        guard !r.isEmpty else {
            if case .allButCheckpoints = r.rule {
                return String(localized: "Nothing to remove: every note keeps only checkpoints and the newest save of each editing session.")
            }
            return String(localized: "Nothing to remove: no autosave is old enough to be thinned.")
        }
        // Two counts in one sentence: each is its own (plural) noun phrase.
        let deletedSize = StorageText.bytes(Int64(r.bytesDeleted))
        let files = String(localized: "\(r.deletions) old autosaves (\(deletedSize))",
                           comment: "Thinning summary: noun phrase, number of autosaves removed and their size; used in “Removes %@ from %@.”")
        let notes = String(localized: "\(r.notes.count) notes",
                           comment: "Thinning summary: noun phrase, number of notes; used in “Removes %@ from %@.”")
        var s = done
            ? String(localized: "Removed \(files) from \(notes).", comment: "Thinning done: “Removed 120 old autosaves (1.2 MB) from 4 notes.”")
            : String(localized: "Removes \(files) from \(notes).", comment: "Thinning preview: “Removes 120 old autosaves (1.2 MB) from 4 notes.”")
        if r.snapshots > 0 {
            let addedSize = StorageText.bytes(Int64(r.bytesAdded))
            s += " " + (done
                ? String(localized: "To keep saved versions and the last autosave of each session restorable, \(r.snapshots) snapshots (\(addedSize)) were added.")
                : String(localized: "To keep saved versions and the last autosave of each session restorable, \(r.snapshots) snapshots (\(addedSize)) will be added."))
        }
        if !r.skipped.isEmpty {
            s += " " + String(localized: "\(r.skipped.count) notes were left as they are (open, not downloaded or unreadable).")
        }
        return s
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.sentence(report, done: false))
                } footer: {
                    Text(report.rule.localizedExplanation)
                }
                if !report.notes.isEmpty {
                    Section("Notes") {
                        ForEach(report.notes) { n in
                            HStack {
                                Text(NoteTitle.display(n.title)).lineLimit(1)
                                Spacer()
                                Text("\(n.deletions) autosaves", comment: "Thinning preview: autosaves removed from one note")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle(report.rule.localizedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Thin", role: .destructive, action: thin).disabled(report.isEmpty)
                }
            }
        }
    }
}

/// The thinning rules' wording in the interface language (`ThinningRule.title`
/// and `explanation` are the library's English, also printed by the CLI).
extension ThinningRule {
    /// "Thin versions older than 30 days" / "Thin everything except checkpoints".
    var localizedTitle: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Thin versions older than \(age)", comment: "Thinning rule; the value is “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Thin everything except checkpoints", comment: "Thinning rule")
        }
    }

    /// `localizedTitle` as a button that opens a preview ("…").
    var localizedButtonTitle: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Thin versions older than \(age)…", comment: "Button; the value is “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Thin everything except checkpoints…", comment: "Button")
        }
    }

    /// The rule and what it keeps, in one sentence.
    var localizedExplanation: String {
        switch self {
        case .olderThan(let days):
            let age = ThinningPreference.label(days)
            return String(localized: "Removes autosaves older than \(age). Keeps every checkpoint (saved and imported versions), the newest save of each editing session, the note's newest version and everything from the last \(age).",
                          comment: "Thinning rule explanation; both values are the same age, “30 days”, “1 year”…")
        case .allButCheckpoints:
            return String(localized: "Removes every autosave, however recent, except the newest save of each editing session. Keeps every checkpoint (saved and imported versions) and the note's newest version.")
        }
    }
}


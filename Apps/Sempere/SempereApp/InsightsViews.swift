import Sempere
import SempereAppCore
import SempereInsights
import SwiftUI

// Note Insights in the app (docs/design/1.2-note-insights.md §6, D4, D12-D15; Insights PR 2): Settings ▸ Note
// Insights, the one-time offer card and the note's Note Insights sheet; the map and its list form are
// `InsightsMapView.swift`, topic summaries `InsightsTopicViews.swift` (PR 3). The model's half is `AppModel+Insights`
// (SempereAppCore); these views only word and lay it out.

extension View {
    /// A setting of the vault itself (Note Insights' `insights.*`): kept in `settings.age` for every device and never
    /// per device, so it has no settings-sync badge. Names the key for `testCatalogMatchesWhereTheAppShowsEachSetting`.
    func vaultSetting(_ key: String) -> some View {
        accessibilityIdentifier("vaultSetting.\(key)")
    }
}

/// The words of Note Insights' values.
enum InsightsText {
    static func problem(_ p: InsightsProblem) -> String {
        switch p {
        case .readOnly: return String(localized: "This vault is read-only here, so Note Insights cannot be changed.")
        case .failed(let why): return String(localized: "Note Insights could not be saved: \(why)", comment: "%@ is the reason")
        }
    }

    /// Why this device makes no summaries (`ModelAvailability`).
    static func modelReason(_ a: ModelAvailability?) -> String {
        switch a {
        case .available?: return String(localized: "Apple Intelligence is available on this device.")
        case .disabled?: return String(localized: "Turn on Apple Intelligence in Settings to make summaries on this device.")
        // Apple says "not ready" both while the model downloads and, for ever, while the Siri language does not match the
        // device's language and region exactly (es-ES and es-US differ): an app cannot tell which (1.2 owner report).
        case .notReady?: return String(localized: "Apple Intelligence is not ready on this device. It may still be downloading, or its language does not match this device's language and region.")
        case .deviceNotEligible?: return String(localized: "This device cannot run Apple Intelligence: it shows the summaries other devices make.")
        case .unsupported?, nil: return String(localized: "Summaries cannot be made on this device: it shows the summaries other devices make.")
        }
    }

    /// Why the last pass on this device made nothing (`InsightsPassOutcome`), under "Process Now".
    static func outcome(_ o: InsightsPassOutcome) -> String {
        switch o {
        case .modelUnavailable(let a): return modelReason(a)
        case .failed(let count, let reason):
            return String(localized: "\(count) notes could not be summarized: \(reason)", comment: "Note Insights pass outcome; %@ is the first error")
        case .backedOff(let count, let reason?):
            return String(localized: "\(count) notes are waiting after an earlier failure: \(reason). Process Now tries them again.",
                          comment: "Note Insights pass outcome; %@ is the first error")
        case .backedOff(let count, nil):
            return String(localized: "\(count) notes are waiting after an earlier failure. Process Now tries them again.",
                          comment: "Note Insights pass outcome")
        case .waitingToSettle(let count):
            return String(localized: "\(count) notes were edited in the last 10 minutes. Process Now does them at once.",
                          comment: "Note Insights pass outcome")
        case .noteOpen(let count):
            return String(localized: "\(count) notes are open in an editor and are processed once closed.", comment: "Note Insights pass outcome")
        case .nothingToDo:
            return String(localized: "Every note with text has a summary.", comment: "Note Insights pass outcome")
        case .readOnly:
            return String(localized: "This vault is read-only here, so this device cannot process notes.", comment: "Note Insights pass outcome")
        case .notListed:
            return String(localized: "This device is not in the vault's device list, so it cannot process notes.",
                          comment: "Note Insights pass outcome")
        case .cannotWrite(let why):
            return String(localized: "This device cannot process notes now: \(why)", comment: "Note Insights pass outcome; %@ is the reason")
        }
    }

    /// How this device stands to the shared map (`MapCompatibility.rawValue`).
    static func compatibility(_ raw: String) -> String {
        switch MapCompatibility(rawValue: raw) {
        case .compatible?: return String(localized: "Compatible: this device places its new notes in the map at once.", comment: "Note Insights map status")
        case .incompatible?: return String(localized: "This device's numbers differ from the shared map's, so it builds its own map.",
                                           comment: "Note Insights map status")
        case .vectorReader?: return String(localized: "This device reads the shared map; its new notes join it once another device processes them.",
                                           comment: "Note Insights map status")
        case .noMap?, nil: return String(localized: "No map yet.", comment: "Note Insights map status")
        }
    }

    /// A device's name for the status and the picker.
    static func deviceName(_ d: InsightsReader.DeviceStatus) -> String {
        d.name ?? String(localized: "Device \(d.device)", comment: "%@ is a short device id")
    }

    /// What a device can do (D15, D21): from its record, never a role.
    static func capability(_ d: InsightsReader.DeviceStatus) -> String {
        guard d.modelAvailable != nil else { return String(localized: "no record yet", comment: "Note Insights: a device that has not written its record") }
        let summaries = d.modelAvailable == true
        let embeds = d.supportsPin ?? (d.supported?.values.contains { !$0.isEmpty } ?? false)
        switch (summaries, embeds) {
        case (true, true): return String(localized: "summaries, related notes and map", comment: "Note Insights: what a device can do")
        case (true, false): return String(localized: "summaries only", comment: "Note Insights: what a device can do")
        case (false, true): return String(localized: "related notes and map only", comment: "Note Insights: what a device can do")
        case (false, false): return String(localized: "nothing yet", comment: "Note Insights: a device that can do no insights work")
        }
    }

    static func lastSeen(_ date: Date?) -> String {
        guard let date else { return String(localized: "nothing written yet", comment: "Note Insights: a device that has written nothing") }
        return date.formatted(.relative(presentation: .named))
    }

    /// Today's date and time as a voice note's title shows them (`YYYY-MM-DD`, `HH.mm`, design D14).
    static func previewStamp(_ now: Date = Date()) -> (date: String, time: String) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return (String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                String(format: "%02d.%02d", c.hour ?? 0, c.minute ?? 0))
    }

    /// The preview of `format`, or why it is not a format.
    static func titlePreview(_ format: String) -> (title: String?, problem: String?) {
        if VoiceNoteTitleFormat.check(format) != nil {
            return (nil, String(localized: "Use text and {date}, {time} and {slug} only.", comment: "Voice-note title format problem; keep the tokens as they are"))
        }
        let stamp = previewStamp()
        let slug = String(localized: "Spring Lab Results", comment: "An example of a voice note's generated title words")
        return (VoiceNoteTitleFormat.render(format, date: stamp.date, time: stamp.time, slug: slug), nil)
    }
}

// MARK: - How to Fix (Apple Intelligence)

/// "How to Fix", beside a reason Apple Intelligence cannot make summaries here that the user can change: turned off, or not
/// ready (which is also what a language mismatch looks like, and never ends by itself). A sheet of steps: iOS has no public
/// link into those settings.
struct AppleIntelligenceHelpButton: View {
    let availability: ModelAvailability?
    @State private var showing = false

    var body: some View {
        if availability == .notReady || availability == .disabled {
            Button("How to Fix", systemImage: "questionmark.circle") { showing = true }
                .font(.footnote)
                .help("Show how to turn on Apple Intelligence and match its language to this device's")
                .accessibilityIdentifier("insights.howToFix")
                .sheet(isPresented: $showing) { AppleIntelligenceHelpSheet() }
        }
    }
}

struct AppleIntelligenceHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    #if targetEnvironment(macCatalyst)
                    Text("1. Open System Settings ▸ Apple Intelligence & Siri and turn on Apple Intelligence.")
                    Text("2. Check its Language there, and the Mac's language in System Settings ▸ General ▸ Language & Region.")
                    #else
                    Text("1. Open Settings ▸ Apple Intelligence & Siri and turn on Apple Intelligence.")
                    Text("2. Check its Language there, and the device's language in Settings ▸ General ▸ Language & Region.")
                    #endif
                    Text("3. Make them the same, including the region: Spanish (Spain) for both, not Spanish (Spain) and Spanish (United States).")
                    Text("4. Leave the device on Wi-Fi and power for a while: the model downloads in the background.")
                } footer: {
                    Text("Apple reports \"not ready\" both while the model downloads and while the languages differ, so Sempere cannot tell which. Your notes can be in any language: the setting is the device's, not the notes'.")
                }
            }
            .navigationTitle("Turn On Apple Intelligence")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Settings ▸ Note Insights

/// Settings ▸ Note Insights: the vault's switch (off by default, D4), voice-note titles (D14), the devices and what each can
/// do (D15, D21: no device is designated), the embedding model (D12), and what has been processed where.
struct InsightsSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var confirmingOff = false
    @State private var titleFormat = ""
    @State private var pinMove: InsightsSettingsWrite.PinMove?
    /// The language chosen in the picker while its confirmation shows ("" is Same as Note); nil: none waiting.
    @State private var pendingLanguage: String?

    private var state: InsightsModelState { model.insights }
    private var on: Bool { state.mode == .on }
    private var writable: Bool { model.phase == .unlocked && !model.isVaultReadOnly }

    var body: some View {
        Section {
            Toggle("Note Insights", isOn: Binding(get: { on }, set: { new in
                if new { Task { await model.setInsightsEnabled(true) } } else { confirmingOff = true }
            }))
            .disabled(!writable)
            .vaultSetting("insights.enabled")
            Text(InsightsText.modelReason(state.capability.model))
                .font(.footnote)
                .foregroundStyle(.secondary)
            AppleIntelligenceHelpButton(availability: state.capability.model)
            if let problem = state.problem {
                Label(InsightsText.problem(problem), systemImage: "exclamationmark.triangle").font(.footnote)
            }
        } header: {
            Text("Note Insights")
        } footer: {
            Text("Summaries, keywords and related notes, made on your devices only with Apple's on-device model. They are stored in the vault, encrypted like your notes. Turning Note Insights off deletes them on every device.")
        }
        .confirmationDialog("Turn off Note Insights?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off and Delete Insights", role: .destructive) { Task { await model.setInsightsEnabled(false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every summary, keyword and related-note link of this vault is deleted on all its devices. Your notes are not changed.")
        }
        if on {
            statusSection
            devicesSection
            languageSection
            titleSection
            embeddingSection
        }
    }

    // MARK: Status

    @ViewBuilder private var statusSection: some View {
        Section("Status") {
            if let s = state.status {
                LabeledContent("Processed") {
                    Text("\(s.processed) of \(s.notes)", comment: "Note Insights: notes processed of all notes")
                }
                if s.stale > 0 {
                    LabeledContent("Out of date") { Text(s.stale, format: .number) }
                }
                let makers = s.devices.filter { $0.current > 0 }.map(InsightsText.deviceName)
                if !makers.isEmpty {
                    LabeledContent("Made on") { Text(makers.joined(separator: ", ")) }
                }
                if let m = s.map {
                    LabeledContent("Notes in the Map") { Text(m.notes, format: .number) }
                    LabeledContent("Groups") { Text(m.clusters, format: .number) }
                } else {
                    LabeledContent("Map") { Text("Not built yet", comment: "Note Insights map") }
                }
                Text(InsightsText.compatibility(s.compatibility)).font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if state.isWorking {
                Label("Processing notes on this device…", systemImage: "gearshape.2").foregroundStyle(.secondary)
            } else if model.insightsBusy {
                Label("Making a topic summary…", systemImage: "text.quote").foregroundStyle(.secondary)
            }
            if model.insightsHasRole {
                Button("Process Now", systemImage: "play.circle") { model.requestInsightsPass(force: true) }
                    .disabled(model.insightsBusy || !writable)
                    .help("Process notes on this device now, without waiting for it to charge")
            }
            if let outcome = state.passOutcome, !model.insightsBusy {
                Text(InsightsText.outcome(outcome)).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("insights.passOutcome")
            } else if !state.capability.generates {
                // Said beside the button and the counts: this device adds related notes and the map at most.
                Text(InsightsText.modelReason(state.capability.model)).font(.footnote).foregroundStyle(.secondary)
            }
            if case .modelUnavailable? = state.passOutcome { AppleIntelligenceHelpButton(availability: state.capability.model) }
            NavigationLink {
                InsightsMapScreen { model.selectedNoteID = $0 }
            } label: {
                Label("Map of Related Notes", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(model.insightsMap.isEmpty)
            .accessibilityIdentifier("insights.mapLink")
            NavigationLink {
                InsightsTopicsList()
            } label: {
                Label("Topic Summaries", systemImage: "text.quote")
            }
            .accessibilityIdentifier("insights.topicsLink")
        }
        .onAppear { model.refreshInsightsCapability() }
    }

    // MARK: Devices (D15, D21)

    @ViewBuilder private var devicesSection: some View {
        if let s = state.status {
            let devices = s.devices.filter(\.listed)
            Section {
                ForEach(devices, id: \.device) { d in
                    LabeledContent(InsightsText.deviceName(d)) {
                        VStack(alignment: .trailing) {
                            Text(InsightsText.capability(d))
                            Text(InsightsText.lastSeen(d.lastSeen)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Every device with Apple Intelligence makes the summaries and keywords no device has made yet: an iPhone or iPad while charging, or right away with Process Now. Any device that can also builds the map of related notes and names voice notes.")
            }
        }
    }

    // MARK: Insight language (1.3)

    private var languageChoices: [String] {
        var tags = InsightsLanguage.choices
        if let set = state.settings.language, !tags.contains(set) { tags.append(set) }
        return tags
    }

    @ViewBuilder private var languageSection: some View {
        Section {
            Picker("Summary and Title Language", selection: Binding(
                get: { state.settings.language ?? "" },
                set: { new in chooseLanguage(new) })) {
                Text("Same as Note").tag("")
                ForEach(languageChoices, id: \.self) { tag in
                    Text(verbatim: Locale.current.localizedString(forIdentifier: tag) ?? tag).tag(tag)
                }
            }
            .disabled(!writable)
            .vaultSetting("insights.language")
            .accessibilityIdentifier("insights.language")
        } header: {
            Text("Insight Language")
        } footer: {
            Text("The language of generated summaries and voice-note titles. Same as Note writes each in the language of its note. Changing it makes the summaries and titles again, a few at a time, on every device of this vault; keywords stay in the note's language.")
        }
        .alert("Make Summaries and Titles Again?", isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } })) {
            Button("Change Language") {
                if let new = pendingLanguage { Task { await model.setInsightsLanguage(new.isEmpty ? nil : new) } }
                pendingLanguage = nil
            }
            Button("Cancel", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("\(summarizedNotes) summaries and titles will be made again on your devices, a few at a time while charging.",
                 comment: "Insight language change confirmation: %lld is how many notes have a summary")
        }
    }

    /// The notes whose summary (and title) the new language replaces.
    private var summarizedNotes: Int { (state.status?.processed ?? 0) + (state.status?.stale ?? 0) }

    /// A language picked in the picker: applied at once when no note has a summary, else after a confirmation (Cancel keeps
    /// the old value, since the picker reads the setting).
    private func chooseLanguage(_ new: String) {
        guard new != (state.settings.language ?? "") else { return }
        if summarizedNotes > 0 { pendingLanguage = new } else { Task { await model.setInsightsLanguage(new.isEmpty ? nil : new) } }
    }

    // MARK: Voice-note titles (D14)

    @ViewBuilder private var titleSection: some View {
        let preview = InsightsText.titlePreview(titleFormat)
        Section {
            TextField("Title format", text: $titleFormat)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveTitle)
                .disabled(!writable)
                .vaultSetting("insights.voiceNoteTitle")
            if let title = preview.title {
                LabeledContent("Preview") { Text(verbatim: title) }
            } else if let problem = preview.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote)
            }
            HStack {
                Button("Save") { saveTitle() }
                    .disabled(!writable || preview.problem != nil || titleFormat == state.settings.voiceNoteTitle)
                Spacer()
                Button("Use Default") {
                    titleFormat = VoiceNoteTitleFormat.defaultFormat
                    Task { await model.setInsightsVoiceNoteTitle(nil) }
                }
                .disabled(!writable || state.settings.voiceNoteTitle == VoiceNoteTitleFormat.defaultFormat)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Voice Note Titles")
        } footer: {
            Text("Quick voice notes without a title of their own are shown with one made from their transcript. {date} and {time} are when the note was recorded, {slug} a few words from the model. A title you set yourself is always the one shown, and the generated one is never written into the note.")
        }
        .onAppear { titleFormat = state.settings.voiceNoteTitle }
        .onChange(of: state.settings.voiceNoteTitle) { _, new in titleFormat = new }
    }

    private func saveTitle() {
        let f = titleFormat
        Task { await model.setInsightsVoiceNoteTitle(f) }
    }

    // MARK: Embedding model (D12)

    @ViewBuilder private var embeddingSection: some View {
        if let s = state.status {
            Section {
                LabeledContent("Embedding Model") {
                    if let pin = s.pin {
                        Text("Revision \(pin)", comment: "The pinned embedding model revision")
                    } else {
                        Text("Not chosen yet", comment: "No embedding model revision yet")
                    }
                }
                .vaultSetting("insights.embeddingRevision")
                if s.upgradeOffer != nil {
                    Button("Use the Newer Embedding Model…") { Task { pinMove = await model.insightsPinMove() } }
                        .disabled(!writable)
                }
            } footer: {
                Text("Every device compares notes with the same embedding model. A newer one is used only when you choose it.")
            }
            .confirmationDialog("Use the newer embedding model?", isPresented: Binding(get: { pinMove != nil }, set: { if !$0 { pinMove = nil } }),
                                titleVisibility: .visible, presenting: pinMove) { move in
                Button("Use Revision \(move.revision)") { Task { await model.applyInsightsPinMove(move) } }
                Button("Cancel", role: .cancel) {}
            } message: { move in
                Text(pinMessage(move))
            }
        }
    }

    private func pinMessage(_ move: InsightsSettingsWrite.PinMove) -> String {
        let names = Dictionary((state.status?.devices ?? []).map { ($0.device, InsightsText.deviceName($0)) }, uniquingKeysWith: { a, _ in a })
        var parts = [String(localized: "Notes are embedded again (a few minutes for hundreds of notes).")]
        if !move.leftOut.isEmpty {
            let left = move.leftOut.map { names[$0.rawValue] ?? $0.rawValue }.joined(separator: ", ")
            parts.append(String(localized: "\(left) cannot use it: they stop placing new notes until another device processes them.",
                                comment: "%@ is a list of device names"))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - The offer card

/// The one-time offer on a device that can make summaries (design §6 item 6, D4): Turn On, or Not Now (never again for
/// this vault on this device).
struct InsightsOfferCard: View {
    @AppModelEnvironment private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Summarize and connect your notes", systemImage: "sparkles").font(.headline)
            Text("Note Insights writes a short summary and keywords for each note and finds related notes, on your devices only. About an hour of charging for 500 notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Turn On") { Task { await model.setInsightsEnabled(true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("insightsOffer.turnOn")
                Button("Not Now") { model.answerInsightsOffer() }
                    .accessibilityIdentifier("insightsOffer.notNow")
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("insightsOffer")
    }
}

// MARK: - A note's insights

/// A note's Note Insights (design §6 item 1): its summary (which device made it, when; stale when the note changed
/// since), keyword chips (a tap searches), and related notes with why (a tap opens one).
struct NoteInsightsSheet: View {
    @AppModelEnvironment private var model
    @Environment(WindowUI.self) private var ui
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    var body: some View {
        NavigationStack {
            List {
                if let panel = model.insightsPanel(for: noteID) {
                    summarySection(panel)
                    relatedSection(panel)
                } else {
                    Text("Note Insights is off for this vault.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(model.notesByID[noteID].map { NoteTitle.display(model.displayTitle($0)) } ?? String(localized: "Note Insights"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .id(model.insights.revision)
        }
        .accessibilityIdentifier("noteInsights")
    }

    @ViewBuilder private func summarySection(_ panel: NoteInsightsPanel) -> some View {
        Section {
            if let summary = panel.shown?.summary {
                Text(verbatim: summary)
                    .foregroundStyle(panel.stale ? .secondary : .primary)
                    .textSelection(.enabled)
            } else if panel.missing {
                Text("The summary appears after a device with Apple Intelligence has processed this note.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No summary for this note: its keywords only.").foregroundStyle(.secondary)
            }
            if panel.stale {
                Label("The note changed since this was made; it is made again soon.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
            }
            if let keywords = panel.shown?.keywords, !keywords.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(keywords, id: \.t) { k in
                            Button {
                                model.searchText = k.t
                                ui.searchPresented = true
                                dismiss()
                            } label: {
                                Text(verbatim: k.t)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Search for this keyword")
                        }
                    }
                }
            }
            if let concepts = panel.shown?.concepts, !concepts.isEmpty {
                Text(verbatim: concepts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
            if let made = madeLine(panel.shown) {
                Text(made).font(.caption).foregroundStyle(.secondary)
            }
            regenerateRow
        } header: {
            Text("Summary")
        }
    }

    /// "Regenerate": this note's summary and keywords made again now on this device (a bad transcript fixed, a model that
    /// did better since), when this device makes summaries; why not, when it cannot.
    @ViewBuilder private var regenerateRow: some View {
        if model.insights.capability.generates, model.insightsHasRole {
            if model.noteInsightsPending(noteID) {
                Label("Regenerating…", systemImage: "gearshape.2").foregroundStyle(.secondary)
                    .accessibilityIdentifier("noteInsights.regenerating")
            } else {
                Button("Regenerate", systemImage: "arrow.clockwise") { model.regenerateNoteInsights(noteID) }
                    .disabled(model.phase != .unlocked || model.isVaultReadOnly)
                    .help("Make this note's summary and keywords again on this device")
                    .accessibilityIdentifier("noteInsights.regenerate")
            }
        } else {
            Text(InsightsText.modelReason(model.insights.capability.model)).font(.footnote).foregroundStyle(.secondary)
            AppleIntelligenceHelpButton(availability: model.insights.capability.model)
        }
    }

    private func madeLine(_ shown: InsightsReader.Shown?) -> String? {
        guard let shown, shown.device != nil else { return nil }
        let name = shown.deviceName ?? shown.device ?? ""
        let when = shown.written?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return String(localized: "Generated on \(name), \(when)", comment: "Note Insights: device name, date")
    }

    @ViewBuilder private func relatedSection(_ panel: NoteInsightsPanel) -> some View {
        Section {
            if let bound = panel.outsideGraph {
                Text("This device compares only the \(bound) most recently changed notes, and this note is not one of them.",
                     comment: "Note Insights: the related-notes bound of this device")
                    .foregroundStyle(.secondary)
            } else if panel.related.isEmpty {
                Text("No related notes yet.").foregroundStyle(.secondary)
            }
            ForEach(panel.related, id: \.note) { r in
                Button {
                    if let id = UUID(uuidString: r.note) { model.selectedNoteID = id }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: NoteTitle.display(r.title)).foregroundStyle(.primary)
                        Text(r.shared.isEmpty ? String(localized: "similar wording", comment: "Why two notes are related")
                             : r.shared.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .overlay(alignment: .trailing) {
                        if r.placed {
                            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                                .accessibilityLabel("Placed on this device")
                        }
                    }
                }
                .help("Open this note")
            }
        } header: {
            Text("Related Notes")
        } footer: {
            if let cluster = panel.cluster, !cluster.isEmpty {
                Text("In the group “\(cluster.joined(separator: ", "))”.", comment: "%@ is a group's label words")
            }
        }
    }
}

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
        case .notReady?: return String(localized: "Apple Intelligence is still getting ready on this device.")
        case .deviceNotEligible?: return String(localized: "This device cannot run Apple Intelligence: it shows the summaries other devices make.")
        case .unsupported?, nil: return String(localized: "Summaries cannot be made on this device: it shows the summaries other devices make.")
        }
    }

    /// How this device stands to the work device's map (`MapCompatibility.rawValue`).
    static func compatibility(_ raw: String) -> String {
        switch MapCompatibility(rawValue: raw) {
        case .workDevice?: return String(localized: "This is the work device.", comment: "Note Insights map status")
        case .compatible?: return String(localized: "Compatible: this device places its new notes in the map at once.", comment: "Note Insights map status")
        case .incompatible?: return String(localized: "This device's numbers differ from the work device's, so it builds its own map.",
                                           comment: "Note Insights map status")
        case .vectorReader?: return String(localized: "This device reads the shared map; its new notes join it once the work device processes them.",
                                           comment: "Note Insights map status")
        case .noMap?, nil: return String(localized: "No map yet.", comment: "Note Insights map status")
        }
    }

    /// A device's name for the status and the picker.
    static func deviceName(_ d: InsightsReader.DeviceStatus) -> String {
        d.name ?? String(localized: "Device \(d.device)", comment: "%@ is a short device id")
    }

    /// "related notes and map only" for a device that cannot make summaries (D13).
    static func role(_ d: InsightsReader.DeviceStatus) -> String? {
        d.modelAvailable == true ? nil : String(localized: "related notes and map only", comment: "Note Insights work device picker")
    }

    static func lastSeen(_ date: Date?) -> String {
        guard let date else { return String(localized: "nothing written yet", comment: "Note Insights work device") }
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

// MARK: - Settings ▸ Note Insights

/// Settings ▸ Note Insights: the vault's switch (off by default, D4), voice-note titles (D14), the work device (D13),
/// the embedding model (D12), and what has been processed where (D15).
struct InsightsSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var confirmingOff = false
    @State private var titleFormat = ""
    @State private var pinMove: InsightsSettingsWrite.PinMove?

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
            workDeviceSection
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
            }
            if model.insightsHasRole {
                Button("Process Now", systemImage: "play.circle") { model.requestInsightsPass(force: true) }
                    .disabled(state.isWorking || !writable)
                    .help("Make this device's summaries, keywords and related notes now, without waiting for it to charge")
            }
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
    }

    // MARK: Work device (D13)

    private var capableDevices: [InsightsReader.DeviceStatus] {
        guard let s = state.status else { return [] }
        let capable = Set(s.capableDevices)
        return s.devices.filter { $0.listed && (capable.contains($0.device) || $0.isWorkDevice) }
    }

    @ViewBuilder private var workDeviceSection: some View {
        Section {
            let devices = capableDevices
            Picker("Work Device", selection: Binding(get: { state.settings.workDevice?.rawValue ?? "" }, set: { raw in
                Task { await model.setInsightsWorkDevice(DeviceID(raw)) }
            })) {
                if state.settings.workDevice == nil { Text("None yet").tag("") }
                ForEach(devices, id: \.device) { d in
                    if let role = InsightsText.role(d) {
                        Text("\(InsightsText.deviceName(d)) (\(role))", comment: "A device and what it can do").tag(d.device)
                    } else {
                        Text(InsightsText.deviceName(d)).tag(d.device)
                    }
                }
            }
            .disabled(!writable || devices.isEmpty)
            .vaultSetting("insights.workDevice")
            if let s = state.status, s.workDevice != nil {
                LabeledContent("Last seen") { Text(InsightsText.lastSeen(s.workDeviceLastSeen)) }
                if s.workDeviceNotSeen {
                    Label("The work device has not been seen for 14 days. Summaries pause until it returns or another device does the work.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
            if state.settings.workDevice != model.vault?.writerDevice, state.capability.canWork {
                Button("Use This Device", systemImage: "iphone.and.arrow.forward") { Task { await model.claimInsightsWorkDevice() } }
                    .disabled(!writable)
                    .help("Make this device the one that makes summaries and builds the map")
                Toggle("Also Process on This Kind of Device", isOn: Binding(get: { state.settings.computeAuto }, set: { on in
                    Task { await model.setInsightsComputeHere(on) }
                }))
                .disabled(!writable)
                .vaultSetting("insights.compute")
            }
        } header: {
            Text("Work Device")
        } footer: {
            Text("One device makes the summaries, keywords and voice-note titles, and builds the map of related notes; the others show what it made. Any device that can run the models can do the work. On an iPhone or iPad it works while charging.")
        }
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
            Text("Quick voice notes are named from their transcript while they keep the title they were recorded with. {date} and {time} are when the note was recorded, {slug} a few words from the model. A title you set yourself is never replaced.")
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
        var parts = [String(localized: "The work device embeds every note again (a few minutes for hundreds of notes).")]
        if !move.leftOut.isEmpty {
            let left = move.leftOut.map { names[$0.rawValue] ?? $0.rawValue }.joined(separator: ", ")
            parts.append(String(localized: "\(left) cannot use it: they stop placing new notes until the work device processes them.",
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
            .navigationTitle(model.notesByID[noteID].map { NoteTitle.display($0.title) } ?? String(localized: "Note Insights"))
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
        } header: {
            Text("Summary")
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

import Sempere
import SwiftUI

// The views of `Expectations.swift`: the key notice, the quick tour, the
// About screen and the Settings ▸ About section, and the window modifier
// that shows them (from the menus, and by themselves once).

/// A notice or screen a window shows as a sheet (`WindowUI.expectations`).
enum ExpectationsSheet: Identifiable, Hashable {
    case about
    /// `firstRun`: shown by itself (`OnboardingPolicy`), not asked for.
    case tour(firstRun: Bool)
    case keyNotice(firstRun: Bool)

    var id: String {
        switch self {
        case .about: return "about"
        case .tour(let first): return "tour-\(first)"
        case .keyNotice(let first): return "keyNotice-\(first)"
        }
    }
}

/// Sheets that must not be covered by a notice that shows by itself (the
/// new-vault sheet: its key receipt comes first). Counted, so nested holders work.
@MainActor
@Observable
final class OnboardingHold {
    static let shared = OnboardingHold()
    var count = 0
}

extension View {
    /// While this view is on screen no notice shows by itself.
    @MainActor
    func holdsOnboarding() -> some View {
        onAppear { OnboardingHold.shared.count += 1 }
            .onDisappear { OnboardingHold.shared.count = max(0, OnboardingHold.shared.count - 1) }
    }
}

/// Presents `WindowUI.expectations`, and in the window that hosts the canvas
/// decides when the key notice and the tour show by themselves.
struct ExpectationsSheets: ViewModifier {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    let ui: WindowUI
    /// The sheet that is on screen (its content appeared), to tell a presentation SwiftUI dropped.
    @State private var shown = ShownSheet()

    @MainActor
    private final class ShownSheet {
        var sheet: ExpectationsSheet?
    }

    private struct Trigger: Equatable {
        var ready: Bool
        var vault: UUID? = nil
        var recipient: String? = nil
    }

    private var trigger: Trigger {
        let ready = model.phase == .unlocked && !keys.holdsUnlockSheet(model) && model.canvasWindow == ui.id
            && ui.expectations == nil && OnboardingHold.shared.count == 0 && !model.holdsOnboardingForVaultNotice
        // The public key is derived from the identity (X-Wing): only when it is needed.
        guard ready else { return Trigger(ready: false) }
        return Trigger(ready: true, vault: model.vault?.vaultId, recipient: model.heldDeviceKey)
    }

    func body(content: Content) -> some View {
        @Bindable var ui = ui
        content
            .sheet(item: $ui.expectations) { sheet in
                Group {
                    switch sheet {
                    case .about:
                        NavigationStack { AboutView(showsDone: true) }
                    case .tour(let firstRun):
                        QuickTourView(firstRun: firstRun)
                    case .keyNotice(let firstRun):
                        if firstRun { FirstRunFlow() } else { KeyNoticeView(firstRun: false) }
                    }
                }
                .onAppear { shown.sheet = sheet }
                .onDisappear { if shown.sheet == sheet { shown.sheet = nil } }
            }
            .task(id: trigger) {
                guard trigger.ready else { return }
                // Let a sheet that just closed (unlock, new vault) finish its animation.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, trigger.ready else { return }
                switch OnboardingPolicy.next(unlocked: true, vault: trigger.vault, recipient: trigger.recipient,
                                             memory: OnboardingMemory(), automatic: OnboardingPolicy.automatic) {
                case .keyNotice: present(.keyNotice(firstRun: true))
                case .tour: present(.tour(firstRun: true))
                case nil: break
                }
            }
    }

    /// Shows `sheet` by itself. SwiftUI drops a presentation that arrives while
    /// another sheet is still closing and leaves the item set with nothing on
    /// screen; then the item is cleared again, so the trigger tries once more.
    private func present(_ sheet: ExpectationsSheet) {
        ui.expectations = sheet
        let ui = ui, shown = shown
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if ui.expectations == sheet, shown.sheet != sheet { ui.expectations = nil }
        }
    }

}

/// The first-run sheet: About Your Key, then (when it is due) the quick tour in
/// the same sheet. One presentation: a second sheet presented as the first
/// closed was dropped on the iPad simulator in CI, and swapping the item did
/// not show it either.
private struct FirstRunFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingTour = false

    var body: some View {
        if showingTour {
            QuickTourView(firstRun: true)
        } else {
            KeyNoticeView(firstRun: true) {
                if OnboardingPolicy.automatic && !OnboardingMemory().tourSeen {
                    showingTour = true
                } else {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - About Your Key

/// What the key means: only it opens the notes; lose every copy and nobody
/// can open them; save the recovery kit; keep backups. Shown once per vault
/// and key on this device, when it is first unlocked (a new vault included),
/// and from About and the tour. The first time only "I Understand" closes it.
struct KeyNoticeView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    /// Shown by itself: it needs an explicit "I Understand".
    var firstRun: Bool
    /// Called after "I Understand" instead of closing the sheet (`ExpectationsSheets` shows the tour next).
    var onUnderstood: (() -> Void)?
    @State private var showingBackups = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    point(Text("Only your key opens these notes"), symbol: "key.horizontal")
                    Text("Your notes are encrypted with a key that stays with you: on your devices, on paper, or wherever you saved it. Sempere has no server and never receives it. If you chose a passphrase, the copy of the key it protects opens the notes too.")
                }
                Section {
                    point(Text("If every copy of the key is lost, so are the notes"), symbol: "exclamationmark.triangle")
                    Text("Nobody can recover them then, including the developer. There is no reset and no recovery service.")
                }
                Section {
                    point(Text("Keep the recovery kit"), symbol: "printer")
                    Text("The vault's recovery key was shown once, when the vault was created: keep its printed kit, or the key in a password manager, somewhere apart from this device. No device keeps it. It opens the vault read-only, and if the device that manages devices is lost, it takes over.")
                }
                Section {
                    point(Text("Keep backups"), symbol: "externaldrive")
                    Text("A backup copies the encrypted vault to another place. It helps when a folder is lost or damaged; it does not replace the key.")
                    Button("Backup Settings…", systemImage: "gearshape") { showingBackups = true }
                        .disabled(model.vault == nil)
                } footer: {
                    Text("Sempere is free software and comes with no warranty.")
                }
            }
            .accessibilityIdentifier("keyNotice")
            .safeAreaInset(edge: .bottom) {
                // Always in view (not a row at the end of a long form): the first time it is the only way out.
                if firstRun {
                    Button {
                        acknowledge()
                    } label: {
                        Text("I Understand").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("keyNoticeUnderstand")
                    .padding()
                    .background(.bar)
                }
            }
            .navigationTitle("About Your Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !firstRun {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(firstRun)
        .sheet(isPresented: $showingBackups) { BackupSettingsSheet() }
    }

    private func point(_ title: Text, symbol: String) -> some View {
        Label {
            title.font(.headline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func acknowledge() {
        if let vault = model.vault?.vaultId {
            OnboardingMemory().acknowledgeKeyNotice(vault: vault, recipient: model.heldDeviceKey)
        }
        if let onUnderstood { onUnderstood() } else { dismiss() }
    }
}

/// Settings ▸ Backups on its own, for the key notice's pointer.
private struct BackupSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            Form { BackupSettingsSection(restoring: $restoring) }
                .sheet(isPresented: $restoring) { RestoreBackupView() }
                .navigationTitle("Backups")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// MARK: - Quick tour

/// Six pages, each a symbol, a title and two lines. Swipe, the arrow buttons
/// or the arrow keys page; Skip (or Done on the last page) closes it at any
/// point. Seen once per device (`OnboardingMemory`).
struct QuickTourView: View {
    @Environment(\.dismiss) private var dismiss
    var firstRun: Bool
    @State private var index = 0
    @State private var showingKeyNotice = false
    private let pages = QuickTour.pages(isMac: Platform.isMac)

    private var isLast: Bool { index >= pages.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                        TourPageView(page: page, number: offset + 1, count: pages.count) {
                            showingKeyNotice = true
                        }
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                // On the pages only: an identifier on the whole stack replaced the buttons' own.
                .accessibilityIdentifier("quickTour")
                controls
            }
            .navigationTitle("Quick Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { isLast ? Text("Done") : Text("Skip") }
                        .accessibilityIdentifier("quickTourSkip")
                        .help("Close the tour")
                }
            }
        }
        .onAppear { OnboardingMemory().markTourSeen() }
        .sheet(isPresented: $showingKeyNotice) { KeyNoticeView(firstRun: false) }
    }

    /// Back and Next, also on the arrow keys (Mac, hardware keyboards).
    private var controls: some View {
        HStack {
            Button {
                withAnimation { index = max(0, index - 1) }
            } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .help("Previous Page")
            .accessibilityLabel("Previous Page")
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(index == 0)
            Spacer()
            if isLast {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("quickTourDone")
            } else {
                Button("Next") { withAnimation { index = min(pages.count - 1, index + 1) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("quickTourNext")
            }
            Spacer()
            Button {
                withAnimation { index = min(pages.count - 1, index + 1) }
            } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .help("Next Page")
            .accessibilityLabel("Next Page")
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(isLast)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct TourPageView: View {
    let page: TourPage
    let number: Int
    let count: Int
    let showKeyNotice: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 56

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: page.symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 32)
                VStack(spacing: 12) {
                    Text(page.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    ForEach(page.lines, id: \.self) { line in
                        Text(line).font(.body)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("Page \(number) of \(count)"))
                if page.offersKeyNotice {
                    Button("About Your Key", systemImage: "key.horizontal", action: showKeyNotice)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("quickTourKeyNotice")
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("quickTourPage-\(page.id)")
    }
}

// MARK: - About

/// The version, the license notice and the copyright: the top of About Sempere, and of Settings ▸ About
/// itself (TestFlight build 8: "should live on the main About page, without having to click into" it).
struct AboutVersionBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Version", value: AboutInfo.versionText())
            Text("Sempere is free software under the GNU GPL v3. It comes with no warranty.")
            Text(verbatim: SempereAbout.copyright)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aboutVersionBlock")
    }
}

/// Settings ▸ About: version, the license notice and the copyright, and the way to the rest.
struct AboutSettingsSection: View {
    @State private var showingTour = false
    @State private var showingKeyNotice = false
    /// Mac: an Option-click (or five clicks) on the version shows the drag diagnostics (`DragTestSection`, bug 7).
    @State private var showingDragTest = Platform.isMac && DragTestSection.isActive

    var body: some View {
        // The version block is a section of its own (build 10: it ran into the links below it).
        Section {
            AboutVersionBlock()
                .modifier(DragTestReveal(enabled: Platform.isMac) { showingDragTest = true })
        } header: {
            Text("About")
        }
        Section {
            NavigationLink("About Sempere") { AboutView(showsDone: false) }
                .accessibilityIdentifier("settingsAboutSempere")
            Link("Sempere Website", destination: SempereAbout.websiteURL)
            NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                .accessibilityIdentifier("settingsPrivacyPolicy")
            // Each sheet on its button, not the section: a section's modifier is on each of its
            // rows, and several rows presenting at once can close it again on Mac Catalyst 27.
            Button("Show Quick Tour") { showingTour = true }
                .sheet(isPresented: $showingTour) { QuickTourView(firstRun: false) }
            Button("About Your Key") { showingKeyNotice = true }
                .sheet(isPresented: $showingKeyNotice) { KeyNoticeView(firstRun: false) }
        }
        if showingDragTest {
            DragTestSection()
        }
    }
}

/// About Sempere: version and build, the license and its text, the security
/// links, the source, third-party licenses, and the tour and key notice.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    /// True in a sheet of its own (Sempere ▸ About Sempere); false pushed from Settings.
    var showsDone: Bool
    @State private var showingTour = false
    @State private var showingKeyNotice = false

    var body: some View {
        Form {
            Section {
                AboutVersionBlock()
            }
            Section {
                NavigationLink("License") { BundledTextView(documents: [.license, .exception]) }
                    .accessibilityIdentifier("aboutLicense")
                Link("The GNU GPL v3 on gnu.org", destination: SempereAbout.licenseURL)
            } header: {
                Text("License")
            } footer: {
                Text("You may use, study, share and change Sempere under the GPL v3 or any later version. An App Store exception lets the app be distributed under the App Store's terms.")
            }
            Section {
                Link("Sempere Website", destination: SempereAbout.websiteURL)
                NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                    .accessibilityIdentifier("aboutPrivacyPolicy")
            } header: {
                Text("Website and Privacy")
            } footer: {
                Text("Sempere collects no data. The privacy policy says what that means.")
            }
            Section {
                Link("Security Design and Limits", destination: SempereAbout.securityDesignURL)
                Link("Report a Vulnerability", destination: SempereAbout.reportVulnerabilityURL)
                Link("Source Code", destination: SempereAbout.sourceURL)
            } header: {
                Text("Security and Source")
            } footer: {
                Text("Vulnerabilities are reported privately on GitHub, as the security policy (SECURITY.md) describes.")
            }
            Section {
                ForEach(SempereAbout.components(for: .app), id: \.name) { component in
                    Link(destination: component.url) {
                        LabeledContent {
                            Text(verbatim: component.license)
                        } label: {
                            Text(verbatim: component.name)
                        }
                    }
                }
                NavigationLink("Third-Party Licenses") { BundledTextView(documents: [.thirdParty]) }
            } header: {
                Text("Acknowledgments")
            }
            Section {
                Button("Show Quick Tour") { showingTour = true }
                Button("About Your Key") { showingKeyNotice = true }
            }
        }
        .accessibilityIdentifier("aboutView")
        .navigationTitle("About Sempere")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("aboutDone")
                }
            }
        }
        .sheet(isPresented: $showingTour) { QuickTourView(firstRun: false) }
        .sheet(isPresented: $showingKeyNotice) { KeyNoticeView(firstRun: false) }
    }
}

/// The privacy policy as it ships in the app (offline audit A-P6: it reads without a network), with the link to the
/// published one, which is the same text.
struct PrivacyPolicyView: View {
    @State private var paragraphs: [String]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Link("Read It on the Website", destination: SempereAbout.privacyPolicyURL)
                if let paragraphs {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Self.paragraph(paragraph)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .accessibilityIdentifier("privacyPolicy")
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let missing = String(localized: "This text is not in this build. Read it at \(SempereAbout.privacyPolicyURL.absoluteString).",
                                 comment: "About: the bundled privacy policy is missing; %@ is a web address")
            paragraphs = await Task.detached {
                AboutInfo.text(of: .privacyPolicy).map(AboutInfo.privacyPolicyParagraphs) ?? [missing]
            }.value
        }
    }

    /// One Markdown paragraph (the policy is written in English): a heading, a list (`- ` items, continued by
    /// indented lines) or running text, each line's inline Markdown (bold, links) rendered.
    @ViewBuilder static func paragraph(_ source: String) -> some View {
        if source.hasPrefix("#") {
            Text(verbatim: source.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                .font(source.hasPrefix("##") ? .headline : .title2.bold())
        } else if let items = AboutInfo.listItems(source) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").font(.callout)
                        inline(item)
                    }
                }
            }
        } else {
            inline(source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        }
    }

    private static func inline(_ source: String) -> Text {
        if let text = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnly)) {
            return Text(text).font(.callout)
        }
        return Text(verbatim: source).font(.callout)
    }
}

/// Bundled texts (the license, third-party notices), read as they ship.
struct BundledTextView: View {
    let documents: [AboutInfo.Document]
    @State private var paragraphs: [String]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let paragraphs {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .accessibilityIdentifier("bundledText")
        .navigationTitle(documents == [.thirdParty] ? String(localized: "Third-Party Licenses") : String(localized: "License"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let docs = documents
            let missing = String(localized: "This text is not in this build. Read it at \(SempereAbout.repositoryLicenseURL.absoluteString).",
                                 comment: "About: a bundled license text is missing; %@ is a web address")
            paragraphs = await Task.detached {
                docs.flatMap { doc in AboutInfo.text(of: doc).map(AboutInfo.paragraphs) ?? [missing] }
            }.value
        }
    }
}

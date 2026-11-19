import Foundation
import Sempere
import SempereInsights

// MARK: - Ask your notes in the app (docs/design/1.3-ask.md §3.6, §3.7, §5)
//
// The model's half: what the search field does (Search or Ask), the question and the answer on screen, one Ask at a
// time (a new one cancels the old), opening a cited note through `NoteLink`. The pipeline is the package's `AskEngine`
// (the same code as `sempere ask`). Everything here is memory: the question never reaches `searchText`, the recent
// searches or any store (D9), and closing or locking the vault drops it.

/// What the search field does.
public enum AskTarget: String, CaseIterable, Sendable {
    case search, ask
}

/// Where an Ask stands.
public enum AskPhase: Equatable, Sendable {
    case idle
    /// Looking for notes (retrieval is well under a second).
    case retrieving
    /// The notes are in (`result`) and the model is reading them: "Reading 6 notes".
    case reading(notes: Int)
    case done
}

/// A line the Ask screen shows above the notes: what is missing or was skipped. The app words each.
public enum AskBanner: Equatable, Sendable {
    /// The model cannot answer here: `kind` is `AskResult.missingKind` (`noModel`, `disabled`, `notReady`,
    /// `deviceNotEligible`, `unsupported`).
    case modelUnavailable(kind: String)
    /// The model does not support the question's language (BCP 47 primary tag).
    case languageUnsupported(String)
    /// The model's call failed or took too long.
    case modelFailed
    /// Vector matching was skipped (`AskResult.vectors`: `language`, `incompatible`, `noMap`, `noVectors`, `noEmbedder`).
    case vectorsSkipped(kind: String)
    /// Note Insights is off: only the question's words were matched (the screen offers turning it on, once).
    case insightsOff
}

/// What the Ask screen reads (observed: `AppModel.ask`).
public struct AskModelState: Equatable, Sendable {
    public var phase = AskPhase.idle
    /// The latest result: retrieval's notes at once, then the answer over them.
    public var result: AskResult?
    /// The "Turn on Note Insights" offer was answered for this vault on this device.
    public var offerAnswered = false

    public init() {}

    /// The banners for `result`, most important first.
    public var banners: [AskBanner] {
        guard let r = result else { return [] }
        var out: [AskBanner] = []
        if r.mode != .answer, let kind = r.missingKind {
            switch kind {
            case "language": out.append(.languageUnsupported(r.lang))
            case "failed": out.append(.modelFailed)
            case "notFound": break
            default: out.append(.modelUnavailable(kind: kind))
            }
        }
        switch r.vectors {
        case "used", "none": break
        case "off": out.append(.insightsOff)
        default: out.append(.vectorsSkipped(kind: r.vectors))
        }
        return out
    }
}

extension AppModelCore {
    /// Offered on the Ask screen: Note Insights is off or never set up and the offer was not answered here.
    public var showsAskInsightsOffer: Bool {
        phase == .unlocked && !isVaultReadOnly && insights.mode != .on && !ask.offerAnswered && ask.banners.contains(.insightsOff)
    }

    nonisolated static func askOfferKey(_ vaultId: UUID) -> String { "Sempere.askInsightsOffer.\(vaultId.uuidString.lowercased())" }

    /// The Ask screen's offer was answered (turned on, or dismissed): not shown again for this vault on this device.
    public func answerAskInsightsOffer(turnOn: Bool) async {
        guard let vault else { return }
        services.settings.set(true, forKey: Self.askOfferKey(vault.vaultId))
        ask.offerAnswered = true
        if turnOn { await setInsightsEnabled(true) }
    }

    /// The Ask field's text is not empty and an Ask can start.
    public var canSubmitAsk: Bool {
        phase == .unlocked && listLoaded && !askQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Asks `askQuestion` (Return in the field). A new Ask cancels the one running; the notes show as soon as retrieval
    /// has them and the answer fills in above them.
    public func submitAsk() {
        guard canSubmitAsk, let vault else { return }
        let question = askQuestion
        askTask?.cancel()
        askSerial += 1
        let serial = askSerial
        let gen = generation
        let type = settingsDeviceType
        let summaries = insightsSummaries
        // Results name notes as the list does (a voice note's derived or default title).
        let titles = Dictionary(summaries.map { ($0.id, displayTitle($0)) }, uniquingKeysWith: { a, _ in a })
        // A voice note's default title (made up, or stored before 1.3) is no label word.
        let defaultTitled = Set(summaries.filter { $0.hasUnchosenTitle(generated: insightsIndex.shown[$0.id]?.generatedTitle) }.map(\.id))
        refreshInsightsCapability()
        let model = insightsRuntime.model, embedder = insightsRuntime.embedder
        let me = vault.writerDevice
        let detect = insightsServices.detectLanguage
        let offerKey = Self.askOfferKey(vault.vaultId)
        ask.phase = .retrieving
        ask.result = nil
        ask.offerAnswered = services.settings.bool(forKey: offerKey)
        askTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> AskResult in
                let settings = InsightsSettings.read(vault, type: type)
                let reader = InsightsReader(vault: vault, snapshot: InsightsStore(vault: vault).snapshot(), settings: settings)
                let notes = AskNote.notes(vault, summaries: summaries, titles: titles, defaultTitled: defaultTitled)
                var options = AskOptions()
                options.detectLanguage = detect
                options.onRetrieved = { first in
                    Task { @MainActor in self?.askRetrieved(first, serial: serial, generation: gen) }
                }
                return await AskEngine(reader: reader, notes: notes, me: me, model: model, embedder: embedder)
                    .ask(question, options: options)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            // The question in the field may have changed since (typing does not cancel): the result is this Ask's, and the
            // answer names its question (`AskResult.question`). A newer Ask or a closed vault cancels it instead.
            guard let self, !Task.isCancelled, self.generation == gen, self.askSerial == serial else { return }
            self.ask.result = result
            self.ask.phase = .done
        }
    }

    private func askRetrieved(_ first: AskResult, serial: Int, generation gen: Int) {
        guard generation == gen, askSerial == serial, ask.phase == .retrieving else { return }
        ask.result = first
        ask.phase = .reading(notes: min(first.notes.count, AskRetriever.sourceCount))
    }

    /// Stops the Ask in progress ("Cancel"); what was found stays.
    public func cancelAsk() {
        askTask?.cancel(); askTask = nil
        if ask.phase != .done { ask.phase = ask.result == nil ? .idle : .done }
    }

    /// Clears the question and the answer (the field's clear button, leaving Ask).
    public func clearAsk() {
        askTask?.cancel(); askTask = nil
        askQuestion = ""
        ask = AskModelState(offerAnswered: ask.offerAnswered)
    }

    /// The vault closed or locked: nothing of an Ask stays (D9).
    func stopAsk() {
        askTask?.cancel(); askTask = nil
        askQuestion = ""
        ask = AskModelState()
    }

    /// The note link for a result row or chip: the note, at `page` (1-based, as the result gives it) when it has one.
    public func askLink(note id: String, page: Int?) -> NoteLink? {
        guard let vault, let noteId = UUID(uuidString: id) else { return nil }
        let pageId = page.flatMap { number in notesByID[noteId]?.pageTexts.first { $0.number == number }?.pageId }
        return NoteLink(vaultId: vault.vaultId, noteId: noteId, page: pageId)
    }

    /// Opens a cited note in this window, at `page` when given.
    @discardableResult
    public func openAskNote(_ id: String, page: Int?) -> NoteLinkOutcome? {
        askLink(note: id, page: page).map { open($0) }
    }
}

extension AskModelState {
    init(offerAnswered: Bool) { self.init(); self.offerAnswered = offerAnswered }
}

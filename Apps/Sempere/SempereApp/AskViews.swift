import Sempere
import SempereAppCore
import SempereInsights
import SwiftUI
import UIKit

// MARK: - Ask your notes (docs/design/1.3-ask.md §3.6)
//
// The search field's second state: a question typed in it is answered from the notes on this device. The answer is drawn
// as plain text (no markdown, no links), each sentence followed by numbered chips that open the note it came from at its
// page; below it the notes used, then "Other matching notes". Without the model or vectors the same rows are headed "Best
// matches", each with its matching passage and why it matched. Nothing is stored: the question lives in the model's
// memory until the vault closes (D9).

/// Search | Ask, under the search field.
struct AskTargetPicker: View {
    @AppModelEnvironment private var model

    var body: some View {
        @Bindable var model = model
        Picker("Search or Ask", selection: $model.askTarget) {
            Text("Search", comment: "Segment under the search field: search the notes' words").tag(AskTarget.search)
            Text("Ask", comment: "Segment under the search field: ask the notes a question").tag(AskTarget.ask)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityIdentifier("ask.target")
        .help("Search matches words; Ask answers a question from your notes, on this device")
    }
}

/// What the list shows while the field is in Ask mode.
struct AskResultsView: View {
    @AppModelEnvironment private var model

    var body: some View {
        let ask = model.ask
        List {
            if ask.result == nil, ask.phase == .idle {
                ContentUnavailableView {
                    Label("Ask Your Notes", systemImage: "questionmark.bubble")
                } description: {
                    Text("Type a question and press Return. The answer is written on this device from your notes, and each sentence shows where it came from. Check the source.")
                }
                .listRowBackground(SwiftUI.Color.clear)
                .accessibilityIdentifier("ask.empty")
            }
            ForEach(Array(ask.banners.enumerated()), id: \.offset) { _, banner in
                AskBannerRow(banner: banner)
            }
            if model.showsAskInsightsOffer { AskInsightsOffer() }
            progress(ask)
            if let result = ask.result {
                if result.mode == .answer, !result.answer.isEmpty {
                    AskAnswerCard(result: result)
                }
                rows(result)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("ask.results")
    }

    @ViewBuilder
    private func progress(_ ask: AskModelState) -> some View {
        switch ask.phase {
        case .retrieving:
            HStack {
                ProgressView()
                Text("Looking through your notes…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelAsk() }
            }
            .accessibilityIdentifier("ask.progress")
        case .reading(let notes):
            HStack {
                ProgressView()
                Text("Reading \(notes) notes").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelAsk() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ask.progress")
        case .idle, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rows(_ result: AskResult) -> some View {
        let used = result.notes.filter(\.used)
        let other = result.notes.filter { !$0.used }
        let numbers = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1.note, $0 + 1) })
        if !used.isEmpty {
            Section("Notes Used") {
                ForEach(used, id: \.note) { n in AskNoteRow(note: n, number: numbers[n.note], question: result.question, showsPassage: false) }
            }
        }
        if !other.isEmpty {
            Section {
                ForEach(other, id: \.note) { n in
                    AskNoteRow(note: n, number: nil, question: result.question, showsPassage: result.mode != .answer)
                }
            } header: {
                Text(result.mode == .answer ? String(localized: "Other Matching Notes") : String(localized: "Best Matches"))
            }
        }
        if result.notes.isEmpty, model.ask.phase == .done {
            Text("I couldn't find that in your notes.").foregroundStyle(.secondary).accessibilityIdentifier("ask.notFound")
        }
    }
}

/// The answer in a card: each sentence with its chips, the label, a Copy button.
struct AskAnswerCard: View {
    @AppModelEnvironment private var model
    let result: AskResult

    private var numbers: [String: Int] {
        var out: [String: Int] = [:]
        for n in result.notes where n.used { out[n.note] = out.count + 1 }
        return out
    }

    var body: some View {
        let numbers = numbers
        let titles = Dictionary(result.notes.map { ($0.note, $0) }, uniquingKeysWith: { a, _ in a })
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(result.answer.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: s.text).textSelection(.enabled)
                        HStack(spacing: 6) {
                            ForEach(s.sources, id: \.self) { id in
                                if let n = numbers[id], let note = titles[id] {
                                    chip(n, note)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Label("Generated on this device from your notes", systemImage: "apple.intelligence")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = result.answer.map(\.text).joined(separator: " ")
                    }
                    .font(.caption)
                    .accessibilityIdentifier("ask.copy")
                }
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("ask.answer")
        }
    }

    private func chip(_ number: Int, _ note: AskNoteResult) -> some View {
        Button("\(number)") { model.openAskNote(note.note, page: note.pages.first) }
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .accessibilityLabel(AskWording.chipLabel(number: number, title: note.title, page: note.pages.first))
            .accessibilityIdentifier("ask.chip.\(number)")
    }
}

/// A note of the result: title, notebook, pages and date; in `retrieval` and `keyword` its matching passage with the
/// matched words in bold, and why it matched. A tap opens the note at its first page.
struct AskNoteRow: View {
    @AppModelEnvironment private var model
    let note: AskNoteResult
    let number: Int?
    let question: String
    let showsPassage: Bool

    /// The title the note list shows for it now (a voice note's derived or default title), else the result's.
    private var shownTitle: String {
        UUID(uuidString: note.note).flatMap { model.notesByID[$0] }.map { model.displayTitle($0) } ?? note.title
    }

    var body: some View {
        Button { model.openAskNote(note.note, page: note.pages.first) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    if let number { Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary) }
                    Text(shownTitle.isEmpty ? String(localized: "Untitled note") : shownTitle).font(.headline)
                }
                Text(AskWording.detail(note)).font(.caption).foregroundStyle(.secondary)
                if showsPassage, let best = note.passages.first {
                    Text(AskWording.highlighted(best.text, question: question)).font(.subheadline).lineLimit(4)
                    Text(AskWording.why(note.why)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the note"))
        .accessibilityIdentifier("ask.note")
    }
}

/// A line above the notes saying what is missing or was skipped, with How to Fix where the person can change it.
struct AskBannerRow: View {
    @AppModelEnvironment private var model
    let banner: AskBanner

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(AskWording.text(banner)).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if case .modelUnavailable(let kind) = banner, kind == "disabled" || kind == "notReady" {
                AppleIntelligenceHelpButton(availability: kind == "disabled" ? .disabled : .notReady)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.banner")
    }
}

/// "Turn on Note Insights for better matches", once.
struct AskInsightsOffer: View {
    @AppModelEnvironment private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turn on Note Insights for better matches").font(.subheadline.bold())
            Text("Matching by meaning needs Note Insights, which runs on your devices and keeps nothing outside your vault.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Turn On") { Task { await model.answerAskInsightsOffer(turnOn: true) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("ask.offer.on")
                Button("Not Now") { Task { await model.answerAskInsightsOffer(turnOn: false) } }
                    .controlSize(.small)
                    .accessibilityIdentifier("ask.offer.dismiss")
            }
        }
        .accessibilityIdentifier("ask.offer")
    }
}

/// The words of the Ask screen that are built in code.
@MainActor
enum AskWording {
    static func text(_ banner: AskBanner) -> String {
        switch banner {
        case .modelUnavailable(let kind):
            let device = RememberedKeys.deviceName
            switch kind {
            case "disabled": return String(localized: "Apple Intelligence is off on \(device).")
            case "notReady": return String(localized: "Apple Intelligence is not ready on \(device).")
            default: return String(localized: "Apple Intelligence is not available on \(device).")
            }
        case .languageUnsupported:
            return String(localized: "The on-device model does not support the language of this question.")
        case .modelFailed:
            return String(localized: "The answer could not be written. These are the best matches.")
        case .vectorsSkipped(let kind):
            return kind == "language"
                ? String(localized: "Matching by meaning was skipped: Note Insights is not set up for the language of this question.")
                : String(localized: "Matching by meaning was skipped, so only your words were matched.")
        case .insightsOff:
            return String(localized: "Note Insights is off, so only your words were matched.")
        }
    }

    static func chipLabel(number: Int, title: String, page: Int?) -> String {
        let name = title.isEmpty ? String(localized: "Untitled note") : title
        guard let page else { return String(localized: "Source \(number), \(name)") }
        return String(localized: "Source \(number), \(name), page \(page)")
    }

    /// Notebook, pages and date of a note row.
    static func detail(_ n: AskNoteResult) -> String {
        var parts: [String] = []
        if let book = n.notebook, !book.isEmpty { parts.append(book) }
        if let first = n.pages.first {
            parts.append(n.pages.count == 1 ? String(localized: "Page \(first)")
                         : String(localized: "Pages \(n.pages.map(String.init).joined(separator: ", "))"))
        }
        if let m = n.modified { parts.append(m.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    static func why(_ why: [String]) -> String {
        why.map { $0 == "keywords" ? String(localized: "Your words") : String(localized: "Similar topic") }.joined(separator: ", ")
    }

    /// `text` with the question's words in bold.
    static func highlighted(_ text: String, question: String) -> AttributedString {
        var out = AttributedString(text)
        for r in AskText.matchRanges(in: text, question: question) {
            guard let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out)
            else { continue }
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }
}

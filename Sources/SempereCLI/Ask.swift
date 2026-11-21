import ArgumentParser
import Foundation
import Sempere
import SempereInsights
import SempereInsightsApple

// `sempere ask` (docs/cli.md "Ask your notes"; docs/design/1.3-ask.md §3.5): a question in words, an answer from the
// notes written on this machine by Apple's on-device model, the notes it used listed under it. Retrieval reads what Note
// Insights has; nothing is written or stored, and a machine without the model still gets the best-matching notes.

struct AskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask your notes a question: a short answer from them, with the notes it used.",
        discussion: """
            Retrieval combines vector matches (from Note Insights, when this machine's embeddings match the vault's) \
            with keyword matches, picks the best passages, and has Apple's on-device model (macOS 26 with Apple \
            Intelligence) write an answer from those passages only. Each sentence is checked against the notes it \
            cites; one that is not supported is dropped. Without the model, or when the answer fails the check, you \
            get the best notes with the passages that matched (mode retrieval, or keyword when there are no vectors). \
            The first line of the text output is the mode. Nothing leaves this machine and nothing is stored: no \
            question, answer or history is written to the vault or anywhere else. --retrieve-only never calls the model; \
            --require-model exits 3 when it cannot run; --explain shows each candidate's ranks, the passages sent \
            and each dropped sentence with the reason. A question in a language none of the notes is written in is \
            translated by the model into the notes' language to search them (one more call); the answer is written and \
            checked in the notes' language, then translated back, and its numbers, codes and names are checked again \
            against the notes. Linux has no model and no embedder: keyword mode, exit 0.
            """
    )

    @Argument(help: ArgumentHelp("The question, in words (at most 400 characters are used).", valueName: "question")) var question: String
    @Option(name: .long, help: ArgumentHelp("Notes to list (default 6; the answer reads at most 6).", valueName: "n")) var limit = 6
    @Option(name: .long, help: ArgumentHelp("Only notes in this notebook or below it.", valueName: "path")) var notebook: String?
    @Option(name: .long, help: ArgumentHelp("Only notes with this tag.", valueName: "tag")) var tag: String?
    @Option(name: .long, help: ArgumentHelp("Only notes modified on or after this date (YYYY-MM-DD, local, or RFC 3339).", valueName: "date")) var since: String?
    @Option(name: .long, help: ArgumentHelp("Only notes modified on or before this date.", valueName: "date")) var until: String?
    @Option(name: .long, help: ArgumentHelp("The question's language (BCP 47); default: detected, else the vault's.", valueName: "tag")) var lang: String?
    @Flag(name: .customLong("retrieve-only"), help: "Never call the model: list the best notes and passages.") var retrieveOnly = false
    @Flag(name: .customLong("require-model"), help: "Exit 3 with the reason when the on-device model cannot run.") var requireModel = false
    @Flag(name: .long, help: "Show the candidates' ranks, the passages sent and every dropped sentence.") var explain = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError("the question is empty") }
        if limit < 1 { throw ValidationError("--limit must be at least 1") }
        if retrieveOnly && requireModel { throw ValidationError("--retrieve-only and --require-model contradict each other") }
    }

    /// `YYYY-MM-DD` (local midnight, or the end of that day for an upper bound) or RFC 3339.
    static func date(_ text: String, endOfDay: Bool, option: String) throws -> Date {
        if let d = RFC3339.parse(text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let day = f.date(from: text) else { throw CLIError.usage("\(option) is not a date (YYYY-MM-DD or RFC 3339): \(text)") }
        return endOfDay ? day.addingTimeInterval(86_400 - 0.001) : day
    }

    func run() throws {
        let p = InsightsCLI.providers()
        if requireModel {
            let tag = lang.map { InsightsLanguage.primary($0) }
            guard let model = p.model, model.availability.isAvailable, tag.map(model.supports(language:)) ?? true else {
                throw InsightsCLI.unavailable(p.model.flatMap { m in
                    m.availability.isAvailable ? tag.map { "the model does not support \($0)" } : nil
                } ?? InsightsCLI.modelReason(p.model))
            }
        }
        var filter = AskFilter(notebook: notebook, tag: tag)
        if let since { filter.since = try Self.date(since, endOfDay: false, option: "--since") }
        if let until { filter.until = try Self.date(until, endOfDay: true, option: "--until") }
        let vault = try access.openVault(.required)
        OpenedVaults.shared.markUnchanged(vault.url)
        try vault.requireCompleteCopy()
        let summaries = try vault.summaries(of: nil, cache: cache.cache(for: vault))
        let notes = AskNote.notes(vault, summaries: summaries, titles: NoteTitles.display(summaries, in: vault),
                              defaultTitled: NoteTitles.defaultTitled(summaries, in: vault))
        let engine = AskEngine(reader: InsightsReader(vault: vault), notes: notes, me: vault.writerDevice,
                               model: retrieveOnly ? nil : p.model, embedder: p.embedder)
        var o = AskOptions()
        o.limit = limit; o.filter = filter; o.language = lang; o.retrieveOnly = retrieveOnly; o.explain = explain
        o.detectLanguage = { AppleInsightsProviders.detectLanguage($0, among: $1) }
        let options = o
        let q = question
        let result = try blockingThrowing { await engine.ask(q, options: options) }
        if output.json { return try output.emitJSON(result) }
        Self.print(result, explain: explain, quiet: output.quiet)
    }

    static func print(_ r: AskResult, explain: Bool, quiet: Bool) {
        Swift.print("mode: \(r.mode.rawValue)" + (r.mode == .answer ? "" : r.missing.map { "  (\($0))" } ?? ""))
        for n in r.notices { printStderr("note: \(n)") }
        if let q = r.searchedAs { printStderr("note: searched as (\(r.searchLang ?? "?")): \(q)") }
        var number: [String: Int] = [:]
        for n in r.notes where n.used { number[n.note] = number.count + 1 }
        if r.mode == .answer {
            Swift.print("")
            Swift.print(r.answer.map { s in
                s.text + s.sources.compactMap { number[$0] }.map { " [\($0)]" }.joined()
            }.joined(separator: " "))
        } else if r.notes.isEmpty {
            Swift.print("")
            Swift.print(r.missing ?? "I couldn't find that in your notes")
        }
        func line(_ n: AskNoteResult) -> String {
            let title = n.title.isEmpty ? "(untitled)" : n.title
            let pages = n.pages.isEmpty ? "" : "  p" + n.pages.map(String.init).joined(separator: ",")
            let book = n.notebook.map { "  [\($0)]" } ?? ""
            return "\(title)\(book)\(pages)  \(n.note.prefix(8))"
        }
        let used = r.notes.filter(\.used), other = r.notes.filter { !$0.used }
        if !used.isEmpty {
            Swift.print("")
            Swift.print("Notes used:")
            for n in used { Swift.print("  [\(number[n.note] ?? 0)] \(line(n))") }
        }
        if !other.isEmpty {
            Swift.print("")
            Swift.print(r.mode == .answer ? "Other matching notes:" : "Best matches:")
            for n in other {
                Swift.print("  \(line(n))  (" + n.why.map { $0 == "keywords" ? "your words" : "similar topic" }.joined(separator: ", ") + ")")
                if r.mode != .answer, let best = n.passages.first {
                    Swift.print("      " + best.text.prefix(200).replacingOccurrences(of: "\n", with: " ")
                                + (best.text.count > 200 ? "..." : ""))
                }
            }
        }
        guard explain, let e = r.explain else { return }
        Swift.print("")
        Swift.print("Candidates (vector rank, keyword rank, score):")
        for c in e.candidates {
            let scores = "v=\(c.vectorScore.map { String($0) } ?? "-") k=\(c.keywordScore.map { String($0) } ?? "-")"
            Swift.print("  \(c.note.prefix(8))  v\(c.vectorRank.map(String.init) ?? "-")  k\(c.keywordRank.map(String.init) ?? "-")  \(c.score)  (\(scores))  \(c.title)")
        }
        Swift.print("Sent to the model (\(e.evidenceTokens) tokens):")
        for s in e.sent { Swift.print("  \(s.source)  \(s.note.prefix(8))  \(s.page.map { "p\($0)" } ?? "transcript")  ~\(s.tokens) tokens") }
        Swift.print("Dropped sentences (\(e.droppedSentences.count)):")
        for d in e.droppedSentences { Swift.print("  \(d.reason): \(d.text)") }
    }
}

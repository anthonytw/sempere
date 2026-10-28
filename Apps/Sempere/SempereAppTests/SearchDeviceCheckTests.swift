import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Device check c15 (search under load), automated: stepping through the matches of a large note,
/// typing a query while Recognize All runs and notes arrive from another device, and searching
/// more than 500 transcripts. Results must be current (the same as a fresh search of the list as
/// it is now) and arrive within generous bounds.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct SearchDeviceCheckTests {
    static let words = ["eigenvalue", "momentum", "lattice", "harbor", "quill", "cobalt", "meadow", "prism"]

    /// A 300-page note whose every page has recognized text with `momentum` three times.
    static func largeNote(in vault: Vault) throws -> UUID {
        let note = UUID()
        var ops: [Op] = [.setMeta(.title("Large")), .setMeta(.pageSize(.letter))]
        var order: String?
        var ink = SyntheticInk(seed: 21, options: .init(pointsPerStroke: 8))
        for k in 0..<300 {
            order = PageOrder.between(order, nil)
            let page = Page(order: order ?? "a0")
            ops.append(.addPage(page))
            let strokes = ink.strokes(6)
            ops += strokes.map { .addStroke(page: page.id, stroke: $0) }
            let text = "page \(k) momentum lattice momentum harbor momentum"
            let digest = RecognitionBasis.digest(of: strokes.map(\.id))
            let words = text.split(separator: " ").enumerated().map { i, w in
                Recognition.Word(text: String(w), box: .init(x: 40 + Double(i) * 60, y: 40, w: 55, h: 20))
            }
            ops.append(.setPageRecognition(pageId: page.id, recognition: Recognition(engine: "test-1", text: text, words: words,
                                                                                     basis: digest)))
        }
        _ = try vault.apply(ops, to: note, deviceState: TS.deviceStateURL(), app: "fixture/1")
        return note
    }

    /// c15: 900 matches over 300 pages: each step is quick, steps walk the matches in order and
    /// wrap around, and the page shown follows.
    @Test func c15SteppingThroughTheMatchesOfALargeNote() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let note = try Self.largeNote(in: vault)
        let (editor, _) = try await NoteEditorTests.open(vault, note: note, debounce: .seconds(60))
        editor.highlightSearch(query: "momentum", page: nil)
        let cursor = try #require(editor.searchCursor)
        #expect(cursor.count == 900)
        var worst = 0.0, total = 0.0
        for k in 1...400 {
            let start = DispatchTime.now().uptimeNanoseconds
            editor.stepSearchMatch(1)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            worst = max(worst, ms)
            total += ms
            #expect(editor.searchCursor?.index == k % 900)
            #expect(editor.currentPage?.id == editor.searchCursor?.current.pageId)
        }
        for _ in 0..<500 { editor.stepSearchMatch(1) }
        #expect(editor.searchCursor?.index == 0, "wraps around")
        editor.stepSearchMatch(-1)
        #expect(editor.searchCursor?.index == 899)
        print("PERF-REPORT c15 step on 900 matches / 300 pages: mean \(String(format: "%.2f", total / 400)) ms, worst \(String(format: "%.2f", worst)) ms")
        #expect(total / 400 < 20)
        await editor.close()
    }

    /// c15: typing a query one key at a time while Recognize All reads 120 notes and another device
    /// adds and renames notes: the results always settle on the current query over the current
    /// list, soon after the last key.
    @Test func c15TypingWhileRecognizeAllAndSyncRunKeepsResultsCurrent() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let state = TS.deviceStateURL()
        for k in 0..<120 {
            var ink = SyntheticInk(seed: UInt64(k))
            let page = Page(order: PageOrder.between(nil, nil))
            _ = try vault.apply([.setMeta(.title("\(Self.words[k % Self.words.count]) \(k)")), .addPage(page)]
                                + ink.strokes(8).map { .addStroke(page: page.id, stroke: $0) },
                                to: UUID(), deviceState: state, app: "fixture/1")
        }
        let gate = Gate()
        let recognizer = FakeRecognizer(gate: gate)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recognizer: recognizer)
        model.searchDebounce = .milliseconds(30)
        defer { model.close() }
        try await model.openVault(at: url, identities: [identity])
        #expect(await TS.waitUntil(timeout: .seconds(30)) { model.notes.count >= 121 })
        await gate.close()
        model.startRecognizingNotes()
        #expect(await TS.waitUntil { recognizer.calls.count >= 1 })

        let query = "momentum"
        var arrived: [UUID] = []
        for (i, c) in query.enumerated() {
            model.searchText += String(c)
            if i % 2 == 0 {
                // Another device: a new note matching the query, and a rename of an old one.
                let id = UUID()
                try TS.writeAsAnotherDevice([.setMeta(.title("Momentum arrived \(i)")), .addPage(Page(order: "a0"))],
                                            to: id, vault: url, key: key)
                arrived.append(id)
                try await model.refresh([id])
            }
            await gate.releaseOne()
            try await Task.sleep(for: .milliseconds(20))
        }
        let typed = ContinuousClock.now
        #expect(await TS.waitUntil(timeout: .seconds(10)) {
            !model.isSearching && model.searchResults == NoteSearch.search(query, in: model.searchCandidates)
        })
        let ms = (ContinuousClock.now - typed) / .milliseconds(1)
        print("PERF-REPORT c15 results current \(String(format: "%.0f", ms)) ms after the last key (Recognize All running)")
        #expect(ms < 5_000)
        let hits = Set(model.searchResults.map(\.note))
        #expect(hits.isSuperset(of: arrived), "notes that arrived while typing are found")
        #expect(hits.count >= 15 + arrived.count, "the 15 notes titled momentum and those that arrived")
        await gate.open()
        model.cancelRecognizingNotes()
    }
}

extension TranscriptSearchAppTests {
    /// c15: a vault of 600 transcribed recordings (one per note). A phrase in 75 of them is found
    /// in all 75, within a bound; changing the query while it runs leaves only the new query's hits.
    @Test func c15SearchingMoreThan500Transcripts() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let state = TS.deviceStateURL()
        var withPhrase = Set<UUID>()
        for k in 0..<600 {
            let note = UUID(), rec = UUID()
            let audio = try vault.writeBlob(note: note, Data("not really audio \(k)".utf8), type: "audio/mp4")
            let phrase = k % 8 == 3
            if phrase { withPhrase.insert(note) }
            let spans = (phrase ? ["the", "linear", "maps", "again", "\(k)"] : ["notes", "about", "harbors", "\(k)"])
                .enumerated().map { i, w in RecognizedSpan(text: w, start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3, confidence: 0.9) }
            let transcript = TranscriptBuilder.transcript(recording: rec, engine: "test-1", language: "en-US",
                                                          segments: TranscriptBuilder.segments(fromWords: spans))
            let content = try transcript.encoded()
            let ref = try vault.writeBlob(note: note, content, type: BlobRef.transcriptType)
            _ = try vault.apply([.setMeta(.title("Lecture \(k)")), .addPage(Page(order: "a0")),
                                 .addRecording(Recording(id: rec, blob: audio, started: Date(timeIntervalSince1970: 1_800_000_000),
                                                         duration: 2))], to: note, deviceState: state, app: "fixture/1")
            _ = try vault.apply(to: note, deviceState: state, app: "fixture/1") { s in
                try NoteOps.setTranscript(ref, content: content, for: rec, in: s)
            }
        }
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.searchDebounce = .milliseconds(10)
        defer { model.close() }
        try await model.openVault(at: url, identities: [identity])
        #expect(await TS.waitUntil(timeout: .seconds(60)) { model.notes.filter { !$0.transcribed.isEmpty }.count == 600 })
        model.setSearchTranscripts(true)
        defer { model.setSearchTranscripts(false) }

        // A query that the next one replaces while it runs.
        model.searchText = "harbors"
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        model.searchText = "linear maps"
        #expect(await TS.waitUntil(timeout: .seconds(120)) { !model.isSearching && model.transcriptHits.count == 75 })
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        print("PERF-REPORT c15 transcript search over 600 transcripts: \(String(format: "%.0f", ms)) ms")
        #expect(Set(model.transcriptHits.map(\.note)) == withPhrase)
        #expect(model.transcriptHits.allSatisfy { $0.snippet.lowercased().contains("linear maps") })
        #expect(model.transcriptSearchProblems == 0)
        #expect(ms < 60_000)
        // Again: the cache answers without reading every blob again.
        model.searchText = ""
        let again = ContinuousClock.now
        model.searchText = "linear maps"
        #expect(await TS.waitUntil(timeout: .seconds(60)) { !model.isSearching && model.transcriptHits.count == 75 })
        print("PERF-REPORT c15 transcript search again (cached): \(String(format: "%.0f", (ContinuousClock.now - again) / .milliseconds(1))) ms")
    }
}

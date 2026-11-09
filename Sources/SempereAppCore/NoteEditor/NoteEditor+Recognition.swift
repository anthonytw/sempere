import Foundation
import Sempere

// MARK: - Handwriting recognition

extension NoteEditorModel {
    /// The page's strokes as of now: the ledger's once the page was shown or
    /// edited, else the stored ones (no ledger is built just to read ids).
    func currentStrokes(of page: Page) -> [Stroke] {
        ledgers[page.id]?.live ?? page.strokes
    }

    /// `RecognitionBasis.digest` of `strokes`' ids, the strokes of page
    /// `pageID`: reused while the page's ids are the ones last digested
    /// (compared one by one, which costs far less than the digest), so a
    /// pass after a pen-up digests only the page that changed.
    public func strokeDigest(of pageID: UUID, _ strokes: [Stroke]) -> String {
        if let cached = strokeDigests[pageID], cached.ids.count == strokes.count,
           zip(cached.ids, strokes).allSatisfy({ $0 == $1.id }) {
            return cached.digest
        }
        let ids = strokes.map(\.id)
        let digest = RecognitionBasis.digest(of: ids)
        strokeDigests[pageID] = (ids, digest)
        return digest
    }

    /// Recognizes the pages that need it after `recognitionDelay` without
    /// further stroke changes (and once when the note opens).
    func scheduleRecognition() {
        guard recognizer != nil, !isReadOnly, !isClosed else { return }
        recognitionTimer?.cancel()
        let delay = recognitionDelay
        recognitionTimer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.recognizePending()
        }
    }

    /// Saves pending strokes, then reads every page whose recognition is
    /// missing or stale (`RecognitionPolicy`) and writes what it read as one
    /// delta of `setPageRecognition` ops (one per page) for the whole pass.
    /// Reading runs off the main actor; a page whose strokes changed
    /// meanwhile is dropped (the change schedules another pass). The pass
    /// stops, writing nothing, once the editor closes or recognition is
    /// switched off (`recognizer` set to nil).
    public func recognizePending() async {
        guard recognizer != nil, !isReadOnly else { return }
        if recognitionBusy { recognitionAgain = true; return }
        recognitionBusy = true
        defer { recognitionBusy = false }
        repeat {
            recognitionAgain = false
            await recognizeOnce()
        } while recognitionAgain && !isClosed
    }

    /// Whether a pass may go on: the editor is open and recognition still on.
    var recognitionWanted: Bool { !isClosed && recognizer != nil }

    func recognizeOnce() async {
        guard let recognizer, let writer, !isClosed else { return }
        await flush()
        guard saveFailure == nil, recognitionWanted else { return }   // never recognize strokes that are not on disk
        var read: [(pageID: UUID, digest: String, recognition: Recognition?)] = []
        var failed = false
        for page in pages {
            guard recognitionWanted else { return }
            let strokes = currentStrokes(of: page)
            let digest = strokeDigest(of: page.id, strokes)
            guard RecognitionPolicy.needsRecognition(page.recognition, hasStrokes: !strokes.isEmpty, digest: digest,
                                                     touched: touchedPages.contains(page.id)) else { continue }
            var result: Recognition?
            if !strokes.isEmpty {
                do {
                    var r = try await recognizer.recognize(strokes: strokes, language: meta.lang)
                    r.basis = digest
                    result = r
                } catch {
                    recognitionFailure = .read(describeError(error))
                    failed = true
                    continue
                }
            }
            read.append((page.id, digest, result))
        }
        guard recognitionWanted else { return }
        // Only pages whose strokes are still the ones that were read.
        let current = read.filter { r in
            guard let page = pages.first(where: { $0.id == r.pageID }) else { return false }
            return strokeDigest(of: page.id, currentStrokes(of: page)) == r.digest
        }
        guard !current.isEmpty else { return }
        let ops = current.map { Op.setPageRecognition(pageId: $0.pageID, recognition: $0.recognition) }
        writeEpoch &+= 1
        let hook = beforeWrite
        let write = Task {
            await hook?()
            return try await writer.write(ops)
        }
        recognitionWrite = Task { _ = try await write.value }
        do {
            // The drawing cache's key names every revision this editor wrote.
            let name = try await write.value.filename
            writtenNames.append(name)
            knownRevisionNames.insert(name)
        } catch {
            recognitionFailure = .save(describeError(error))
            return
        }
        for r in current {
            if let index = pages.firstIndex(where: { $0.id == r.pageID }) { pages[index].recognition = r.recognition }
            touchedPages.remove(r.pageID)
        }
        recognitionsWritten += current.count
        if !failed { recognitionFailure = nil }
        onRecognized?(noteID)
    }
}

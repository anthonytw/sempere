import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Counts the revision files a vault (and every copy of it) decrypted
/// (`Vault.revisionDecryptCount`). Files are decrypted by the vault identity
/// derived from the epoch key (format.md §15.2), not by the key the vault was
/// opened with, so wrapping that key no longer sees them.
struct DecryptCounter: Sendable {
    let vault: Vault
    var count: Int { vault.revisionDecryptCount }
}

/// What `NoteWriter` and Version History decrypt (perf audit P50, P53),
/// counted on the fixture note (4 deltas and 1 snapshot).
@MainActor
struct WriterReadCostTests {
    static let lecture = AppModelTests.lecture

    static func vault() throws -> (Vault, DecryptCounter) {
        let (url, key) = try AppModelTests.fixtureVault()
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))])
        return (vault, DecryptCounter(vault: vault))
    }

    static func clock() throws -> DeviceClock { try DeviceClock(url: TS.deviceStateURL()) }

    /// A plain append (browser ops, Save Version) decrypts each revision once
    /// (headers checked, no stroke geometry); its revision sorts after every
    /// listed name and takes the next free `seq`.
    @Test func appendReadsEachRevisionOnce() async throws {
        let (vault, counter) = try Self.vault()
        let names = try vault.revisionNames(of: Self.lecture)
        let clock = try Self.clock()
        let before = counter.count
        let written = try await NoteWriter.append([], to: Self.lecture, vault: vault, clock: clock,
                                                  checkpoint: Checkpoint(name: "v"))
        #expect(counter.count - before == names.count)
        #expect(names.allSatisfy { $0 < written })
        #expect(written.seq == 1)   // a new device
        let again = try await NoteWriter.append([.setMeta(.title("T"))], to: Self.lecture, vault: vault, clock: clock)
        #expect(again.seq == 2 && written < again)
        #expect(try vault.reconstruct(noteId: Self.lecture).meta.title == "T")
    }

    /// A planted file that does not authenticate, named an hour ahead, does
    /// not move the clock; its `seq` is still not reused.
    @Test func plantedFileDoesNotMoveTheClockButReservesSeq() async throws {
        let (vault, _) = try Self.vault()
        let clock = try Self.clock()
        let device = clock.device
        let names = try vault.revisionNames(of: Self.lecture)
        let ahead = HLC(millis: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000, counter: 5)!
        let planted = RevisionName(hlc: ahead, device: device, seq: 7, kind: .delta)
        let dir = vault.url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())")
        try Data("not a revision".utf8).write(to: dir.appendingPathComponent(planted.filename))
        #expect(try vault.loadNote(Self.lecture).failures.keys.contains(planted))
        let written = try await NoteWriter.append([.setMeta(.title("after"))], to: Self.lecture, vault: vault, clock: clock)
        #expect(written.seq == 8)
        #expect(written.hlc < ahead && names.allSatisfy { $0 < written })
    }

    /// A metadata edit reads the note without stroke points and writes what
    /// the full read would; a builder that returns content ops anyway is run
    /// again on the full note.
    @Test func metadataBuilderReadsWithoutPointsAndFallsBackForContentOps() async throws {
        let (vault, counter) = try Self.vault()
        let n = try vault.revisionNames(of: Self.lecture).count
        let clock = try Self.clock()
        var before = counter.count
        let tagged = try await NoteWriter.append(to: Self.lecture, vault: vault, clock: clock, detail: .withoutStrokePoints) {
            $0.flatMap { NoteOps.addTag("perf", to: $0) }.map { [$0] } ?? []
        }
        #expect(tagged != nil)
        #expect(counter.count - before == n)   // every revision once; seq from them, no second read
        #expect(try vault.reconstruct(noteId: Self.lecture).meta.tags.contains("perf"))

        let full = try vault.reconstruct(noteId: Self.lecture)
        let m = try vault.revisionNames(of: Self.lecture).count
        before = counter.count
        let page = try #require(full.pages.first { !$0.strokes.isEmpty })
        let stroke = try #require(page.strokes.first)
        let removed = try await NoteWriter.append(to: Self.lecture, vault: vault, clock: clock, detail: .withoutStrokePoints) { state in
            // Not a metadata op: must not be built from a state without points.
            guard let s = state?.pages.first(where: { $0.id == page.id })?.strokes.first(where: { $0.id == stroke.id }) else { return [] }
            #expect(s.points == stroke.points || s.points.isEmpty)
            return [.removeStroke(page: page.id, strokeId: s.id)]
        }
        #expect(removed != nil)
        #expect(counter.count - before == 2 * m)   // read without points, refused, read again in full
        #expect(!(try vault.reconstruct(noteId: Self.lecture).pages.flatMap(\.strokes).contains { $0.id == stroke.id }))
    }

    /// Opening Version History decrypts each revision once and gives the
    /// restore points (with their completeness) of a plain `loadNote`; a
    /// preview seen again is not rebuilt.
    @Test func historyReadsEachRevisionOnceAndKeepsPreviews() throws {
        let (vault, counter) = try Self.vault()
        let n = try vault.revisionNames(of: Self.lecture).count
        let before = counter.count
        let data = try AppModel.readHistory(Self.lecture, vault: vault, thisDevice: nil)
        #expect(counter.count - before == n)
        let plain = try vault.loadNote(Self.lecture)
        #expect(data.points == NoteHistory.restorePoints(plain.revisions, unreadable: Array(plain.failures.keys)))
        let point = try #require(data.points.last { $0.complete }).name
        let beforePreviews = counter.count
        let first = try data.state(at: point)
        let second = try data.state(at: point)
        #expect(first == second)
        #expect(data.previews.buildCount == 1)
        #expect(counter.count == beforePreviews)   // previews read nothing
    }
}

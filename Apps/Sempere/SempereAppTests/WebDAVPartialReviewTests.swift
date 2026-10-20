import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The fetcher's loop when a run leaves a note as it was (W2 review, #166):
/// such a note is parked, never fetched in a loop, and never holds back the
/// others, even when it is the one the user asked for.
@MainActor
struct WebDAVPartialReviewTests {
    let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A run that ends without an error but leaves its notes incomplete (as
    /// the library did for a quarantined revision) used to be repeated at
    /// once, about 1300 times a second while the vault was open.
    @Test func aNoteThatNeverCompletesIsNotFetchedInATightLoop() async throws {
        let s = try WebDAVAppTests.setup()
        let c = LocalCopy(directory: TestTemp.root.appendingPathComponent(UUID().uuidString),
                                folderName: "Notes.sempere")
        defer { try? c.remove() }
        #expect(try c.downloadMetadata(client: s.remote.folderClient()).errors.isEmpty)
        let recorded = ScopeLog()
        let fetcher = WebDAVFetcher(copy: c, serverName: "dav.example.org", fillsBlobs: false, fetch: { scope, _ in
            recorded.append(scope)
            var report = SyncReport()
            for id in scope.notes ?? [] {
                report.skipped.append(.init(path: "notes/\(id.uuidString.lowercased())/x.delta.age",
                                            message: "quarantined by an earlier run and unchanged on the server"))
            }
            return report   // nothing placed: the notes stay incomplete
        }, changed: { _, _, _ in })
        fetcher.start()
        try await Task.sleep(for: .seconds(1))
        fetcher.stop()
        #expect(recorded.scopes.count <= 3, "\(recorded.scopes.count) fetch runs in one second")
    }

    /// The note the user asked for never completes (its runs leave it as it
    /// was): the other notes are fetched all the same.
    @Test func aStuckNoteAskedForDoesNotStarveTheOthers() async throws {
        let s = try WebDAVAppTests.setup()
        let c = LocalCopy(directory: TestTemp.root.appendingPathComponent(UUID().uuidString),
                                folderName: "Notes.sempere")
        defer { try? c.remove() }
        #expect(try c.downloadMetadata(client: s.remote.folderClient()).errors.isEmpty)
        let recorded = ScopeLog()
        let remote = s.remote, stuck = first
        let fetcher = WebDAVFetcher(copy: c, serverName: "dav.example.org", fillsBlobs: false, fetch: { scope, vault in
            recorded.append(scope)
            var narrowed = scope
            narrowed.notes = scope.notes?.filter { $0 != stuck }   // the server never delivers this one
            return try remote.fetch(WebDAVEndpoint(url: URL(string: "https://dav.example.org/notes/")!),
                                    copy: c, vault: vault, scope: narrowed)
        }, changed: { _, _, _ in })
        fetcher.want(note: first)
        fetcher.start()
        let other = second.uuidString.lowercased()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { !PartialCopyState.incompleteNotes(c.folder).contains(other) })
        #expect(PartialCopyState.incompleteNotes(c.folder) == [first.uuidString.lowercased()])
        fetcher.stop()
        #expect(recorded.scopes.count <= 5, "\(recorded.scopes.count) fetch runs")
    }
}

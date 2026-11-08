import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Opening a WebDAV vault without downloading everything first (W2, P7a,
    /// docs/io.md "WebDAV vaults in the app", format.md §1.2): the root files and
    /// note list, then the notes on demand and through the two-way runs (`AppModel+Join`; moved from the app's
    /// `WebDAVPartialAppTests`).
    @MainActor
    struct WebDAVPartialTests {
        let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        func copy(_ s: WebDAVTests.Setup, _ id: UUID) throws -> LocalCopy {
            s.model.webdavLocations.copy(of: try #require(s.model.webdavLocations.location(id)))
        }

        @Test func opensFromTheNoteListAndFillsInTheBackground() async throws {
            let s = try await WebDAVTests.setup()
            defer { s.model.close() }
            s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
            let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            let c = try copy(s, id)
            #expect(c.isPartial && c.isUsable)
            #expect(s.remote.downloads == 1, "one metadata pull")
            #expect(Set(PartialCopyState.incompleteNotes(c.folder)) == [first.uuidString.lowercased(), second.uuidString.lowercased()])
            #expect(s.model.partialCopyRoot != nil)
            #expect(s.model.joinLocation?.host == "dav.example.org")

            try await s.model.unlock(identityText: s.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { s.model.pendingNoteIDs == [first, second] })
            #expect(await TS.waitUntil(timeout: .seconds(30)) { s.model.notes.count == 2 }, "pending rows")

            s.remote.openFetchGate()
            try await s.model.downloadNote(first)
            try await s.model.downloadNote(second)
            #expect(s.model.pendingNoteIDs.isEmpty)
            #expect(s.model.notes.allSatisfy { !$0.title.isEmpty || $0.problem == nil })
            s.model.close()
            #expect(s.model.joinLocation == nil)
        }

        @Test func rowsComeFromTheServersSummaries() async throws {
            let s = try await WebDAVTests.setup()
            defer { s.model.close() }
            // The server publishes its summaries (format.md §12), as `sync webdav --web-viewer` does.
            let identity = try IdentityFile.parse(s.key)
            let serverVault = try Vault.open(at: s.remote.server, identities: [identity])
            let entries = try serverVault.publishedSummaryEntries().entries
            try serverVault.sealPublishedSummaries(entries).write(to: s.remote.server.appendingPathComponent(PublishedSummaries.fileName))
            s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
            _ = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            try await s.model.unlock(identityText: s.key)
            let expected = Set(entries.values.map(\.title))
            #expect(await TS.waitUntil(timeout: .seconds(30)) { Set(s.model.notes.map(\.title)) == expected }, "titles before any revision arrived")
            #expect(s.model.placeholderNoteIDs.isEmpty)
            #expect(s.model.pendingNoteIDs == [first, second])
            s.remote.openFetchGate()
            try await s.model.downloadNote(first)
            try await s.model.downloadNote(second)
            #expect(s.model.pendingNoteIDs.isEmpty)
        }

        /// An attachment still a stand-in is fetched alone when a page needs it (`partialBlobFetcher`).
        @Test func attachmentsArriveOnDemand() async throws {
            let s = try await WebDAVTests.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            let c = try copy(s, id)
            try await s.model.unlock(identityText: s.key)
            try await s.model.downloadNote(first)
            try await s.model.downloadNote(second)
            #expect(PartialCopyState.incompleteNotes(c.folder).isEmpty)
            let pending = PartialCopyState.pendingBlobsByNote(c.folder)
            let (noteDir, names) = try #require(pending.first, "the fixture has an attachment")
            let note = try #require(UUID(uuidString: noteDir))
            let name = try #require(names.first)
            let fetchBlob = try #require(s.model.partialBlobFetcher())
            try await fetchBlob(note, name)
            #expect(FileManager.default.fileExists(atPath: c.folder.appendingPathComponent("notes/\(noteDir)/att/\(name)").path))
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !c.isPartial }, "the last blob completes the copy")
        }

        @Test func offlineFetchesReportTheServerAndRetry() async throws {
            let s = try await WebDAVTests.setup()
            defer { s.model.close() }
            s.remote.set { $0.fetchError = WebDAVError.offline("The Internet connection appears to be offline.") }
            let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            let c = try copy(s, id)
            try await s.model.unlock(identityText: s.key)
            // Opening a pending note offline names the server, and nothing is waited for.
            await #expect(throws: AppModel.ModelError.noteNotDownloadedFromServer("dav.example.org")) {
                try await s.model.downloadNote(first)
            }
            #expect(s.model.pendingNoteIDs.contains(first))
            s.remote.set { $0.fetchError = nil }
            try await s.model.downloadNote(first)
            #expect(!PartialCopyState.incompleteNotes(c.folder).contains(first.uuidString.lowercased()))
            #expect(!s.model.pendingNoteIDs.contains(first))
        }
    }
}

import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Counts the revision files a vault (and every copy of it) decrypted
    /// (`Vault.revisionDecryptCount`). Files are decrypted by the vault identity
    /// derived from the epoch key (format.md §15.2), not by the key the vault was
    /// opened with, so wrapping that key no longer sees them.
    struct DecryptCounter: Sendable {
        let vault: Vault
        var count: Int { vault.revisionDecryptCount }
    }

    /// What Version History decrypts (perf audit P50, P53; the writer's reads are pinned in the package's
    /// `RevisionWriterTests`), counted on the fixture note (4 deltas and 1 snapshot).
    @MainActor
    struct WriterReadCostTests {
        static let lecture = AppModelTests.lecture

        static func vault() throws -> (Vault, DecryptCounter) {
            let (url, key) = try AppModelTests.fixtureVault()
            let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))])
            return (vault, DecryptCounter(vault: vault))
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
}

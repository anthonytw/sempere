import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Performance round 3: a vault where every note changed at once (a mass
/// re-import seen from another device) is brought up to date without
/// quadratic work.
@MainActor
@Suite(.serialized)
struct MassChangeTests {
    /// The fixture vault plus `extra` one-revision notes.
    static func vault(extra: Int) throws -> (url: URL, key: URL, ids: [UUID]) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        for i in 0..<extra {
            _ = try vault.apply([.setMeta(.title("Note \(i)")), .addPage(Page(order: "a0"))], to: UUID(),
                                deviceState: TS.deviceStateURL(), app: "t")
        }
        return (url, key, try vault.noteIDs())
    }

    /// Many changed notes are read in bigger batches (fewer list updates and
    /// thread barriers), and the status says how many changed.
    @Test func manyChangedNotesAreReadInBiggerBatches() async throws {
        let (url, key, ids) = try Self.vault(extra: 60)
        let reads = Counter()
        let batches = Counter()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        for id in ids { try TS.writeAsAnotherDevice([.setMeta(.title("Changed"))], to: id, vault: url, key: key) }
        model.onSummaryRead = { reads.add($0); batches.add(1) }
        try await model.reconcile()
        #expect(reads.value == ids.count)
        #expect(batches.value <= 8 + 1)
        #expect(model.notes.allSatisfy { $0.title == "Changed" })
        model.close()
    }
}

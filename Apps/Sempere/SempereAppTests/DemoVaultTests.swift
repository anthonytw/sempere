#if DEBUG
import Age
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The synthetic vault behind the App Store screenshots (`DemoVault`).
struct DemoVaultTests {
    static func build() async throws -> (DemoVault.Built, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        return (try await DemoVault.build(in: dir), dir)
    }

    static func open(_ built: DemoVault.Built) throws -> Vault {
        try Vault.open(at: built.url, identities: [try IdentityFile.parse(built.identityText)])
    }

    @Test func buildsNotebooksTagsAndPapers() async throws {
        let (built, dir) = try await Self.build()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Self.open(built)
        let summaries = try vault.summaries()
        #expect(summaries.count == DemoVault.specs.count)
        #expect(summaries.allSatisfy { $0.problem == nil && !$0.deleted && $0.strokes > 0 })
        let notebooks = Set(summaries.compactMap { NotebookPath.canonical($0.notebook) })
        #expect(notebooks.count >= 6)
        #expect(Set(summaries.flatMap(\.tags).map(NoteOps.tagKey)).count >= 6)
        #expect(summaries.contains { $0.pages == 2 })
        // The two screenshot notes sit on different paper.
        let a = try vault.reconstruct(noteId: built.notes["respiration"]!)
        let b = try vault.reconstruct(noteId: built.notes["atlas"]!)
        #expect(a.meta.paper.kind == .marginRuled)
        #expect(b.meta.paper.kind == .dot)
        #expect(a.meta.paper.isValid && b.meta.paper.isValid)
    }

    /// `SEMPERE_DEMO_PASSPHRASE` (launch smoke tests): the key is stored in
    /// `keys/` under the passphrase, so the unlock sheet's passphrase field opens it.
    @Test func passphraseStoresTheKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let built = try await DemoVault.build(in: dir, specs: Array(DemoVault.specs.prefix(1)), passphrase: "smoke test")
        let vault = try Self.open(built)
        let identity = try IdentityFile.parse(built.identityText)
        #expect(try vault.identityFiles() == [identity.recipient])
        let read = try vault.readIdentityFile(recipient: identity.recipient, passphrase: "smoke test")
        #expect(read.recipient == identity.recipient)
        #expect(throws: VaultError.self) { try vault.readIdentityFile(recipient: identity.recipient, passphrase: "wrong") }
        // Without a passphrase no key file is written (the screenshots' vault).
        let plain = try await DemoVault.build(in: dir, specs: Array(DemoVault.specs.prefix(1)))
        #expect(try Self.open(plain).identityFiles().isEmpty)
    }

    @Test func datesAreFixed() async throws {
        let (built, dir) = try await Self.build()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summaries = try Self.open(built).summaries()
        let newest = try #require(summaries.compactMap(\.modified).max())
        #expect(abs(newest.timeIntervalSince(DemoVault.anchor) + 0.2 * 86_400) < 1)
        let oldest = try #require(summaries.compactMap(\.modified).min())
        #expect(oldest < DemoVault.anchor.addingTimeInterval(-20 * 86_400))
    }

    @Test func inkIsDeterministicAndOnThePage() throws {
        for spec in DemoVault.specs {
            let id = DemoVault.noteID(spec.key)
            let first = DemoVault.ops(for: spec, id: id), second = DemoVault.ops(for: spec, id: id)
            #expect(first == second, "\(spec.key) differs between runs")
            for case .addStroke(_, let stroke) in first {
                #expect(stroke.points.count >= 2 && stroke.points.count < 2_000)
                for p in stroke.points {
                    #expect(p.x.isFinite && p.y.isFinite && p.w > 0 && p.w < 16)
                    #expect(p.x > -5 && p.x < 617 && p.y > -5 && p.y < 797, "\(spec.key) strays off the page")
                }
            }
        }
        #expect(Set(DemoVault.specs.map(\.key)).count == DemoVault.specs.count)
        #expect(Set(DemoVault.specs.map { DemoVault.noteID($0.key) }).count == DemoVault.specs.count)
    }

    /// Pinned values: the generator and its mapping to doubles are this
    /// file's own, so the demo ink is the same on every toolchain.
    @Test func randomValuesArePinned() {
        var rng = DemoRandom(seed: 7)
        #expect(rng.next() == 0x63CB_E1E4_5932_0DD7)
        var values = DemoRandom(seed: 7)
        #expect(values.value(0...1) == 0.3898297483912715)
        #expect(values.value(10...20) == 10.167882945281562)
        #expect(values.value(-5...5) == 4.007606806068834)
    }

    /// The shots are light whatever the simulator's or the Mac's appearance.
    @MainActor @Test func demoForcesLightAppearance() {
        let windows = [UIWindow(frame: .zero), UIWindow(frame: .zero)]
        windows[0].overrideUserInterfaceStyle = .dark
        DemoLaunch.forceLight(windows)
        #expect(windows.allSatisfy { $0.overrideUserInterfaceStyle == .light })
    }

    @Test func randomIsSeeded() {
        var a = DemoRandom(seed: 7), b = DemoRandom(seed: 7), c = DemoRandom(seed: 8)
        #expect(a.next() == b.next())
        #expect(a.uuid() == b.uuid())
        #expect(a.next() != c.next())
    }
}
#endif
